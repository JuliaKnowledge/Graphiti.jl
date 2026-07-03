normalize_vec(v) = v ./ sqrt(sum(v .^ 2))

function make_search_fixture()
    d = MemoryDriver()

    alice = EntityNode(name="Alice", summary="Software engineer", group_id="g1")
    alice.name_embedding = normalize_vec([1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    bob = EntityNode(name="Bob", summary="Data scientist", group_id="g1")
    bob.name_embedding = normalize_vec([0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    acme = EntityNode(name="Acme Corp", summary="Technology company", group_id="g1")
    acme.name_embedding = normalize_vec([0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    for n in [alice, bob, acme]; save_node!(d, n); end

    e1 = EntityEdge(source_node_uuid=alice.uuid, target_node_uuid=acme.uuid,
                     name="WORKS_AT", fact="Alice works at Acme Corp as an engineer",
                     group_id="g1")
    e1.fact_embedding = normalize_vec([1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    e2 = EntityEdge(source_node_uuid=bob.uuid, target_node_uuid=acme.uuid,
                     name="CONSULTING_FOR", fact="Bob is consulting for Acme on data projects",
                     group_id="g1")
    e2.fact_embedding = normalize_vec([0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    e3 = EntityEdge(source_node_uuid=alice.uuid, target_node_uuid=bob.uuid,
                     name="KNOWS", fact="Alice and Bob are colleagues",
                     group_id="g1")
    e3.fact_embedding = normalize_vec([0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

    for e in [e1, e2, e3]; save_edge!(d, e); end

    return d, alice, bob, acme, e1, e2, e3
end

@testset "Phase 3: Search & Retrieval" begin
    @testset "Cosine similarity search edges" begin
        d, alice, bob, acme, e1, e2, e3 = make_search_fixture()
        query_emb = normalize_vec([1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        edges, scores = cosine_search_edges(d, query_emb, 3; group_id="g1")
        @test !isempty(edges)
        @test edges[1].uuid == e1.uuid
        @test scores[1] > 0.9
    end

    @testset "Cosine similarity search nodes" begin
        d, alice, bob, acme, e1, e2, e3 = make_search_fixture()
        query_emb = normalize_vec([0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        nodes, scores = cosine_search_nodes(d, query_emb, 3; group_id="g1")
        @test !isempty(nodes)
        @test nodes[1].uuid == bob.uuid
    end

    @testset "BM25 full-text search" begin
        d, alice, bob, acme, e1, e2, e3 = make_search_fixture()
        edges, scores = bm25_search_edges(d, "Alice engineer Acme", 5; group_id="g1")
        @test !isempty(edges)
        @test edges[1].uuid == e1.uuid
    end

    @testset "BM25 uses corpus document frequency" begin
        docs = [Graphiti.tokenize("rare common"), Graphiti.tokenize("common common"), Graphiti.tokenize("common")]
        dfs = Graphiti._bm25_document_frequencies(docs)
        @test dfs["rare"] == 1
        @test dfs["common"] == 3
        @test Graphiti._bm25_idf(length(docs), dfs["rare"]) > Graphiti._bm25_idf(length(docs), dfs["common"])

        d = MemoryDriver()
        rare = EntityEdge(source_node_uuid = "a", target_node_uuid = "b", name = "REL", fact = "rare common", group_id = "g1")
        common = EntityEdge(source_node_uuid = "c", target_node_uuid = "d", name = "REL", fact = "common common common", group_id = "g1")
        save_edge!(d, rare)
        save_edge!(d, common)
        edges, scores = bm25_search_edges(d, "rare common", 2; group_id = "g1")
        @test edges[1].uuid == rare.uuid
        @test scores[1] > scores[2]
    end

    @testset "BFS traversal" begin
        d, alice, bob, acme, e1, e2, e3 = make_search_fixture()
        nodes, edges = bfs_search(d, [alice.uuid], 2; group_id="g1")
        uuids = [n.uuid for n in nodes]
        @test alice.uuid in uuids
        @test acme.uuid in uuids || bob.uuid in uuids
    end

    @testset "RRF reranker" begin
        list1 = ["a", "b", "c"]
        list2 = ["c", "a", "d"]
        scores1 = [1.0, 0.8, 0.6]
        scores2 = [1.0, 0.7, 0.5]

        result, rscores = rrf_rerank([list1, list2], [scores1, scores2])
        @test length(result) >= 3
        @test "a" in result[1:2]
    end

    @testset "MMR reranker" begin
        query = normalize_vec([1.0, 0.0, 0.0, 0.0])
        items = ["alice", "alice2", "bob"]
        embs = [
            normalize_vec([1.0, 0.0, 0.0, 0.0]),
            normalize_vec([0.99, 0.01, 0.0, 0.0]),
            normalize_vec([0.0, 1.0, 0.0, 0.0]),
        ]

        result, scores = mmr_rerank(query, items, embs; lambda=0.5, limit=3)
        @test length(result) <= 3
        @test "alice" in result
    end

    @testset "End-to-end search with GraphitiClient" begin
        d, alice, bob, acme, e1, e2, e3 = make_search_fixture()
        embedder = DeterministicEmbedder(8)
        embedder.embeddings["alice works"] = normalize_vec([1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        llm = EchoLLMClient()
        client = GraphitiClient(d, llm, embedder; config=SearchConfig(limit=5, include_communities=false))

        results = search(client, "alice works"; group_id="g1")
        @test !isempty(results.edges) || !isempty(results.nodes)
    end

    @testset "Search applies MMR reranking to nodes" begin
        d = MemoryDriver()
        llm = EchoLLMClient()
        embedder = DeterministicEmbedder(4)
        embedder.embeddings["node query"] = normalize_vec([1.0, 0.0, 0.0, 0.0])

        n1 = EntityNode(name = "alice", group_id = "g1")
        n1.name_embedding = normalize_vec([1.0, 0.0, 0.0, 0.0])
        n2 = EntityNode(name = "alice clone", group_id = "g1")
        n2.name_embedding = normalize_vec([0.99, 0.01, 0.0, 0.0])
        n3 = EntityNode(name = "bob", group_id = "g1")
        n3.name_embedding = normalize_vec([0.0, 1.0, 0.0, 0.0])
        save_node!(d, n1); save_node!(d, n2); save_node!(d, n3)

        client = GraphitiClient(d, llm, embedder;
            config = SearchConfig(
                search_methods = [COSINE_SIMILARITY],
                reranker = MMR,
                include_nodes = true,
                include_edges = false,
                limit = 3,
                mmr_lambda = 0.2,
            ))

        results = search(client, "node query"; group_id = "g1")
        @test length(results.nodes) == 3
        @test n1.uuid == results.nodes[1].uuid
        @test n3.uuid in [n.uuid for n in results.nodes[1:2]]
    end

    @testset "build_context_string" begin
        d, alice, bob, acme, e1, e2, e3 = make_search_fixture()
        results = SearchResults(
            edges=[e1],
            edge_scores=[0.95],
            nodes=[alice],
            node_scores=[0.9],
        )
        ctx = build_context_string(results)
        @test !isempty(ctx)
        @test occursin("Alice", ctx)
        @test occursin("Acme", ctx) || occursin("Facts", ctx)
    end
end
