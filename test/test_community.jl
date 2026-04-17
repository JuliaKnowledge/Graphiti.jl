@testset "Phase 4: Communities" begin

    # ── helpers ──────────────────────────────────────────────────────────────
    function make_two_cluster_graph()
        d  = MemoryDriver()
        em = DeterministicEmbedder(8)
        llm = EchoLLMClient(fallback = Dict{String,Any}(
            "name"    => "Test Community",
            "summary" => "A cluster of related entities.",
        ))
        client = GraphitiClient(d, llm, em)

        # Python cluster: star topology (Python is centre)
        python  = EntityNode(name="Python",  summary="Programming language",  group_id="g1")
        numpy   = EntityNode(name="NumPy",   summary="Numerical computing",   group_id="g1")
        scipy   = EntityNode(name="SciPy",   summary="Scientific computing",  group_id="g1")
        for n in [python, numpy, scipy]
            n.name_embedding = embed(em, n.name)
            save_node!(d, n)
        end
        save_edge!(d, EntityEdge(source_node_uuid=python.uuid, target_node_uuid=numpy.uuid,
            name="RELATED", fact="Python is used with NumPy", group_id="g1"))
        save_edge!(d, EntityEdge(source_node_uuid=python.uuid, target_node_uuid=scipy.uuid,
            name="RELATED", fact="Python is used with SciPy", group_id="g1"))

        # Cooking cluster: star topology (Cooking is centre)
        cooking  = EntityNode(name="Cooking",  summary="Food preparation",   group_id="g1")
        baking   = EntityNode(name="Baking",   summary="Oven cooking",       group_id="g1")
        grilling = EntityNode(name="Grilling", summary="Barbecue cooking",   group_id="g1")
        for n in [cooking, baking, grilling]
            n.name_embedding = embed(em, n.name)
            save_node!(d, n)
        end
        save_edge!(d, EntityEdge(source_node_uuid=cooking.uuid, target_node_uuid=baking.uuid,
            name="INCLUDES", fact="Cooking includes baking", group_id="g1"))
        save_edge!(d, EntityEdge(source_node_uuid=cooking.uuid, target_node_uuid=grilling.uuid,
            name="INCLUDES", fact="Cooking includes grilling", group_id="g1"))

        return client, d, [python, numpy, scipy], [cooking, baking, grilling]
    end

    @testset "Label propagation — two disconnected clusters" begin
        client, d, py_nodes, ck_nodes = make_two_cluster_graph()

        communities = build_communities!(client; group_ids=["g1"])

        # Two disconnected components → exactly 2 communities
        @test length(communities) == 2

        # All communities have names (set by summarize_community!)
        @test all(!isempty(c.name) for c in communities)

        # All communities have embeddings
        @test all(c.name_embedding !== nothing for c in communities)

        # CommunityEdge records were created
        cedges = get_community_edges(d, "g1")
        @test length(cedges) == 6   # 3 members × 2 communities

        # Each Python node appears in exactly one community
        py_uuids = Set{String}(n.uuid for n in py_nodes)
        ck_uuids = Set{String}(n.uuid for n in ck_nodes)
        py_comm  = filter(ce -> ce.target_node_uuid in py_uuids, cedges)
        ck_comm  = filter(ce -> ce.target_node_uuid in ck_uuids, cedges)
        @test length(py_comm) == 3
        @test length(ck_comm) == 3

        # The two clusters belong to different communities
        py_comm_uuid = py_comm[1].source_node_uuid
        ck_comm_uuid = ck_comm[1].source_node_uuid
        @test py_comm_uuid != ck_comm_uuid
    end

    @testset "build_communities! clear_existing" begin
        client, d, _, _ = make_two_cluster_graph()
        build_communities!(client; group_ids=["g1"])
        first_ids = Set{String}(c.uuid for c in get_community_nodes(d, "g1"))

        # Rebuild — old nodes should be gone and replaced
        build_communities!(client; group_ids=["g1"], clear_existing=true)
        second_ids = Set{String}(c.uuid for c in get_community_nodes(d, "g1"))
        @test isempty(intersect(first_ids, second_ids))
        @test length(get_community_nodes(d, "g1")) == 2
    end

    @testset "summarize_community! stores name and embedding" begin
        d   = MemoryDriver()
        em  = DeterministicEmbedder(4)
        llm = EchoLLMClient(fallback = Dict{String,Any}(
            "name"    => "Scripting Languages",
            "summary" => "A group of scripting languages.",
        ))
        client = GraphitiClient(d, llm, em)

        cn = CommunityNode(group_id="g1")
        save_node!(d, cn)
        members = [
            EntityNode(name="Python", summary="A language", group_id="g1"),
            EntityNode(name="Ruby",   summary="A language", group_id="g1"),
        ]

        summarize_community!(client, cn, members)

        @test cn.name == "Scripting Languages"
        @test cn.summary == "A group of scripting languages."
        @test cn.name_embedding !== nothing
    end

    @testset "update_community! assigns to neighbour community" begin
        client, d, py_nodes, _ = make_two_cluster_graph()
        build_communities!(client; group_ids=["g1"])

        # Add a new Python-adjacent node with an edge to an existing Python node
        julia_node = EntityNode(name="Julia", summary="Scientific language", group_id="g1")
        julia_node.name_embedding = embed(client.embedder, julia_node.name)
        save_node!(d, julia_node)

        # Connect Julia to Python
        save_edge!(d, EntityEdge(
            source_node_uuid = julia_node.uuid,
            target_node_uuid = py_nodes[1].uuid,  # Python
            name = "SIMILAR_TO",
            fact = "Julia is similar to Python",
            group_id = "g1",
        ))

        cn = update_community!(client, julia_node; group_id="g1")
        @test cn !== nothing
        @test cn isa CommunityNode
    end

    @testset "Community cosine search" begin
        d  = MemoryDriver()
        em = DeterministicEmbedder(4)
        llm = EchoLLMClient(fallback = Dict{String,Any}(
            "name" => "Test", "summary" => "Test community"))
        client = GraphitiClient(d, llm, em;
            config = SearchConfig(include_communities = true))

        cn1 = CommunityNode(name="Python Tools", group_id="g1")
        cn1.name_embedding = [1.0, 0.0, 0.0, 0.0]
        save_node!(d, cn1)

        cn2 = CommunityNode(name="Cooking Methods", group_id="g1")
        cn2.name_embedding = [0.0, 1.0, 0.0, 0.0]
        save_node!(d, cn2)

        em.embeddings["python tools query"] = [1.0, 0.0, 0.0, 0.0]

        comms, scores = cosine_search_communities(d, [1.0, 0.0, 0.0, 0.0], 2; group_id="g1")
        @test !isempty(comms)
        @test comms[1].uuid == cn1.uuid

        # search() with include_communities populates results.communities
        results = search(client, "python tools query"; group_id="g1")
        @test !isempty(results.communities)
        @test results.communities[1].uuid == cn1.uuid
    end

    @testset "build_context_string includes Communities section" begin
        cn = CommunityNode(name="AI Tools", summary="Tools for AI development")
        results = SearchResults(
            communities = [cn],
            community_scores = [0.9],
        )
        ctx = build_context_string(results)
        @test occursin("Communities", ctx)
        @test occursin("AI Tools", ctx)
    end

    @testset "TokenUsage tracking via summarize_community!" begin
        d  = MemoryDriver()
        em = DeterministicEmbedder(4)
        llm = EchoLLMClient(fallback = Dict{String,Any}(
            "name" => "Group", "summary" => "A group."))
        client = GraphitiClient(d, llm, em)

        @test client.usage.total_tokens == 0

        cn = CommunityNode(group_id="")
        save_node!(d, cn)
        members = [EntityNode(name="Alpha"), EntityNode(name="Beta")]
        summarize_community!(client, cn, members)

        @test client.usage.prompt_tokens > 0
        @test client.usage.completion_tokens > 0
        @test client.usage.total_tokens == client.usage.prompt_tokens + client.usage.completion_tokens
    end
end
