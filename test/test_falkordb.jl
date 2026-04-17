using Test
using Graphiti
using JSON3

@testset "FalkorDBDriver" begin

    # ── RESP2 encode / decode ────────────────────────────────────────────
    @testset "RESP2 command encoding" begin
        cmd = Graphiti._resp2_encode_command(["GRAPH.QUERY", "g", "MATCH (n) RETURN n"])
        @test cmd == "*3\r\n\$11\r\nGRAPH.QUERY\r\n\$1\r\ng\r\n\$18\r\nMATCH (n) RETURN n\r\n"
    end

    @testset "RESP2 decode primitives" begin
        @test Graphiti._resp2_decode(IOBuffer("+OK\r\n")) == "OK"
        @test Graphiti._resp2_decode(IOBuffer(":42\r\n")) == 42
        @test Graphiti._resp2_decode(IOBuffer("\$5\r\nhello\r\n")) == "hello"
        @test Graphiti._resp2_decode(IOBuffer("\$-1\r\n")) === nothing
        @test Graphiti._resp2_decode(IOBuffer("*2\r\n+a\r\n+b\r\n")) == ["a", "b"]
        @test_throws Graphiti.GraphitiFalkorDBError Graphiti._resp2_decode(IOBuffer("-ERR boom\r\n"))
    end

    # ── Cypher parameter encoding ────────────────────────────────────────
    @testset "param prelude encoding" begin
        # Empty params → no prelude
        @test Graphiti._falkor_param_prelude(Dict()) == ""

        s = Graphiti._falkor_param_prelude(Dict("name" => "Alice"))
        @test s == "CYPHER name='Alice' "

        # Single-quote escaping
        s = Graphiti._falkor_param_prelude(Dict("name" => "O'Reilly"))
        @test occursin("name='O\\'Reilly'", s)

        # Numbers and booleans
        @test occursin("n=42", Graphiti._falkor_param_prelude(Dict("n" => 42)))
        @test occursin("b=true", Graphiti._falkor_param_prelude(Dict("b" => true)))
        @test occursin("z=null", Graphiti._falkor_param_prelude(Dict("z" => nothing)))
    end

    # ── execute_query parses GRAPH.QUERY result-set ──────────────────────
    @testset "GRAPH.QUERY reply parsing" begin
        # Mock reply: header [type=1, "n.name"], one row ["Alice"], stats
        mock_reply = [
            [[1, "n.name"], [1, "n.uuid"]],
            [["Alice", "abc-123"], ["Bob", "def-456"]],
            ["Cached execution: 0", "Query internal execution time: 0.123 ms"],
        ]
        rows = Graphiti._falkor_parse_reply(mock_reply)
        @test length(rows) == 2
        @test rows[1]["n.name"] == "Alice"
        @test rows[1]["n.uuid"] == "abc-123"
        @test rows[2]["n.name"] == "Bob"
    end

    @testset "GRAPH.QUERY reply with [type, value] cells" begin
        # Newer protocol: each cell is [scalar_type, value]
        mock_reply = [
            [[1, "name"]],
            [[[2, "Alice"]], [[2, "Bob"]]],
            ["stats"],
        ]
        rows = Graphiti._falkor_parse_reply(mock_reply)
        @test rows[1]["name"] == "Alice"
        @test rows[2]["name"] == "Bob"
    end

    @testset "_falkor_parse_reply on empty/no-result-set" begin
        @test Graphiti._falkor_parse_reply(nothing) == Dict{String,Any}[]
        @test Graphiti._falkor_parse_reply([["stats only"]]) == Dict{String,Any}[]
    end

    # ── Driver with stub _command_fn ─────────────────────────────────────
    @testset "FalkorDBDriver: injectable command function" begin
        captured = Dict{String,Any}[]
        stub_fn = (drv, args) -> begin
            push!(captured, Dict("graph" => args[2], "query" => args[3]))
            # Default empty success reply
            return [[], [], ["stats"]]
        end

        d = FalkorDBDriver(host="mock", port=1234, graph="kg", _command_fn=stub_fn)
        @test d.host == "mock"
        @test d.port == 1234
        @test d.graph == "kg"

        execute_query(d, "MATCH (n) RETURN n")
        @test length(captured) == 1
        @test captured[1]["graph"] == "kg"
        @test captured[1]["query"] == "MATCH (n) RETURN n"
    end

    @testset "FalkorDBDriver: param prelude is prepended" begin
        captured = Ref("")
        stub_fn = (drv, args) -> begin
            captured[] = args[3]
            return [[], [], []]
        end
        d = FalkorDBDriver(_command_fn=stub_fn)
        execute_query(d, "MATCH (n {name: \$name}) RETURN n";
                      params = Dict("name" => "Alice"))
        @test occursin("CYPHER name='Alice'", captured[])
        @test occursin("MATCH (n {name: \$name}) RETURN n", captured[])
    end

    @testset "FalkorDBDriver: save_node! / save_edge! issue Cypher" begin
        queries = String[]
        stub_fn = (drv, args) -> begin
            push!(queries, args[3])
            return [[], [], []]
        end
        d = FalkorDBDriver(_command_fn=stub_fn)

        n1 = EntityNode(name="Alice", summary="Engineer", group_id="g1")
        n2 = EntityNode(name="Bob",   summary="Manager",  group_id="g1")
        save_node!(d, n1)
        save_node!(d, n2)
        save_edge!(d, EntityEdge(
            source_node_uuid=n1.uuid, target_node_uuid=n2.uuid,
            name="REPORTS_TO", fact="Alice reports to Bob", group_id="g1"))

        @test length(queries) == 3
        @test occursin("MERGE (n:Entity", queries[1])
        @test occursin("MERGE (a)-[r:RELATES_TO", queries[3])
        @test occursin("name='Alice'", queries[1])

        # episodic node + edge
        ep = EpisodicNode(name="ep1", content="Alice met Bob", group_id="g1")
        save_node!(d, ep)
        save_edge!(d, EpisodicEdge(source_node_uuid=ep.uuid,
                                   target_node_uuid=n1.uuid, group_id="g1"))
        @test occursin("MERGE (n:Episodic", queries[end-1])
        @test occursin("MERGE (a)-[r:MENTIONS", queries[end])

        # community + saga
        c = CommunityNode(name="Eng", group_id="g1")
        s = Graphiti.SagaNode(name="Onboarding", group_id="g1")
        save_node!(d, c)
        save_node!(d, s)
        @test occursin("MERGE (n:Community", queries[end-1])
        @test occursin("MERGE (n:Saga", queries[end])
    end

    @testset "FalkorDBDriver: clear! issues GRAPH.DELETE" begin
        captured_args = Vector{Vector{String}}()
        stub_fn = (drv, args) -> begin
            push!(captured_args, [String(a) for a in args])
            return "OK"
        end
        d = FalkorDBDriver(graph="my-kg", _command_fn=stub_fn)
        clear!(d)
        @test length(captured_args) == 1
        @test captured_args[1] == ["GRAPH.DELETE", "my-kg"]
    end

    @testset "FalkorDBDriver: clear! swallows missing-graph error" begin
        stub_fn = (drv, args) -> throw(Graphiti.GraphitiFalkorDBError("graph not found"))
        d = FalkorDBDriver(_command_fn=stub_fn)
        @test clear!(d) === nothing
    end

    @testset "FalkorDBDriver: get_community_nodes parses rows" begin
        stub_fn = (drv, args) -> [
            [[1, "uuid"], [1, "name"], [1, "summary"], [1, "group_id"]],
            [["c1", "Eng team", "Engineers", "g1"],
             ["c2", "Ops team", "Operators", "g1"]],
            ["stats"],
        ]
        d = FalkorDBDriver(_command_fn=stub_fn)
        cs = get_community_nodes(d, "g1")
        @test length(cs) == 2
        @test cs[1].uuid == "c1"
        @test cs[1].name == "Eng team"
        @test cs[2].name == "Ops team"
    end

    @testset "FalkorDBDriver: get_entity_* return empty (parity with Neo4j)" begin
        d = FalkorDBDriver(_command_fn=(_, _) -> nothing)
        @test isempty(get_entity_nodes(d, "g1"))
        @test isempty(get_entity_edges(d, "g1"))
        @test isempty(get_episodic_nodes(d, "g1"))
        @test get_latest_episodic_node(d, "g1") === nothing
    end

    @testset "FalkorDBDriver: env-variable construction" begin
        withenv("FALKORDB_HOST"=>"db.example.com",
                "FALKORDB_PORT"=>"6380",
                "FALKORDB_GRAPH"=>"prod") do
            d = FalkorDBDriver(_command_fn=(_, _) -> nothing)
            @test d.host == "db.example.com"
            @test d.port == 6380
            @test d.graph == "prod"
        end
    end

    @testset "GraphitiFalkorDBError messages" begin
        e = Graphiti.GraphitiFalkorDBError("oops")
        io = IOBuffer()
        showerror(io, e)
        @test occursin("GraphitiFalkorDBError: oops", String(take!(io)))
    end
end
