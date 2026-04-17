@testset "Phase 1: Types, Drivers, Extraction" begin
    @testset "Node construction" begin
        n = EntityNode(name="Alice")
        @test n.name == "Alice"
        @test !isempty(n.uuid)
        @test n.name_embedding === nothing
        @test n.group_id == ""

        ep = EpisodicNode(name="ep1", content="Alice works at Acme", source=TEXT)
        @test ep.content == "Alice works at Acme"
        @test ep.source == TEXT

        cn = CommunityNode(name="Tech Companies")
        @test cn.name == "Tech Companies"
    end

    @testset "Edge construction" begin
        e = EntityEdge(source_node_uuid="s", target_node_uuid="t", name="WORKS_AT", fact="Alice works at Acme")
        @test e.name == "WORKS_AT"
        @test e.invalid_at === nothing
        @test e.valid_at === nothing

        ee = EpisodicEdge(source_node_uuid="ep1", target_node_uuid="e1")
        @test !isempty(ee.uuid)
    end

    @testset "MemoryDriver CRUD" begin
        d = MemoryDriver()

        n = EntityNode(name="Bob")
        save_node!(d, n)
        @test get_node(d, n.uuid) === n
        @test length(get_entity_nodes(d, "")) == 1

        edge = EntityEdge(source_node_uuid=n.uuid, target_node_uuid="other",
                          name="KNOWS", fact="Bob knows someone")
        save_edge!(d, edge)
        @test get_edge(d, edge.uuid) === edge

        delete_node!(d, n.uuid)
        @test get_node(d, n.uuid) === nothing

        clear!(d)
        @test isempty(d.entity_edges)
    end

    @testset "MemoryDriver episodic" begin
        d = MemoryDriver()
        ep = EpisodicNode(name="ep1", content="test", source=TEXT, group_id="g1")
        save_node!(d, ep)
        nodes = get_episodic_nodes(d, "g1")
        @test length(nodes) == 1
        latest = get_latest_episodic_node(d, "g1")
        @test latest !== nothing && latest.uuid == ep.uuid
    end

    @testset "Neo4j query serialization" begin
        body = Graphiti._neo4j_build_body(
            "MATCH (n) WHERE n.name = \$name RETURN n",
            Dict("name" => "Alice")
        )
        parsed = JSON3.read(body, Dict)
        @test length(parsed["statements"]) == 1
        @test parsed["statements"][1]["statement"] == "MATCH (n) WHERE n.name = \$name RETURN n"
        @test parsed["statements"][1]["parameters"]["name"] == "Alice"
    end

    @testset "Neo4j response parsing" begin
        mock_response = JSON3.write(Dict(
            "results" => [Dict(
                "columns" => ["n.name", "n.uuid"],
                "data" => [Dict("row" => ["Alice", "abc-123"])]
            )],
            "errors" => []
        ))
        rows = Graphiti._neo4j_parse_response(mock_response)
        @test length(rows) == 1
        @test rows[1]["n.name"] == "Alice"
        @test rows[1]["n.uuid"] == "abc-123"
    end

    @testset "Neo4j injectable request" begin
        mock_called = Ref(false)
        mock_fn = (url, headers, body) -> begin
            mock_called[] = true
            return 200, JSON3.write(Dict("results" => [Dict("columns" => [], "data" => [])], "errors" => []))
        end
        d = Neo4jDriver(url="http://mock:7474", _request_fn=mock_fn)
        execute_query(d, "MATCH (n) RETURN n")
        @test mock_called[]
    end

    @testset "Prompt formatting" begin
        tmpl = "Hello {name}, you are {age} years old."
        result = format_prompt(tmpl; name="Alice", age=30)
        @test result == "Hello Alice, you are 30 years old."
    end

    @testset "EchoLLMClient" begin
        client = EchoLLMClient(fallback=Dict{String,Any}("answer" => 42))
        resp = complete_json(client, [Dict("role"=>"user","content"=>"hi")])
        @test resp["answer"] == 42

        enqueue_response!(client, Dict{String,Any}("first" => true))
        enqueue_response!(client, Dict{String,Any}("second" => true))
        r1 = complete_json(client, [Dict("role"=>"user","content"=>"1")])
        r2 = complete_json(client, [Dict("role"=>"user","content"=>"2")])
        r3 = complete_json(client, [Dict("role"=>"user","content"=>"3")])
        @test r1["first"] == true
        @test r2["second"] == true
        @test r3["answer"] == 42
    end

    @testset "Entity extraction pipeline" begin
        llm = EchoLLMClient(fallback=Dict{String,Any}(
            "extracted_entities" => [
                Dict("name" => "Alice", "summary" => "A person"),
                Dict("name" => "Acme Corp", "summary" => "A company"),
            ]
        ))
        ep = EpisodicNode(name="ep1", content="Alice works at Acme Corp", source=TEXT, group_id="test")
        entities = extract_entities(llm, ep)
        @test length(entities) == 2
        @test entities[1].name == "Alice"
        @test entities[2].name == "Acme Corp"
        @test entities[1].group_id == "test"
    end

    @testset "Edge extraction pipeline" begin
        llm = EchoLLMClient(fallback=Dict{String,Any}(
            "edges" => [Dict(
                "source_entity_name" => "Alice",
                "target_entity_name" => "Acme Corp",
                "relation_type" => "WORKS_AT",
                "fact" => "Alice works at Acme Corp",
                "valid_at" => nothing,
                "invalid_at" => nothing,
            )]
        ))
        ep = EpisodicNode(name="ep1", content="Alice works at Acme Corp", source=TEXT, group_id="test")
        alice = EntityNode(name="Alice", uuid="uuid-alice", group_id="test")
        acme = EntityNode(name="Acme Corp", uuid="uuid-acme", group_id="test")

        edges = extract_edges_from_episode(llm, ep, [alice, acme])
        @test length(edges) == 1
        @test edges[1].name == "WORKS_AT"
        @test edges[1].fact == "Alice works at Acme Corp"
        @test edges[1].source_node_uuid == "uuid-alice"
        @test edges[1].target_node_uuid == "uuid-acme"
    end
end
