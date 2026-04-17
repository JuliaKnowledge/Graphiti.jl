using Test
using Graphiti

@testset "KuzuDriver" begin

    # ── value encoding ──────────────────────────────────────────────────────
    @testset "value encoding" begin
        @test Graphiti._kuzu_encode_value(nothing) == "NULL"
        @test Graphiti._kuzu_encode_value(true) == "true"
        @test Graphiti._kuzu_encode_value(false) == "false"
        @test Graphiti._kuzu_encode_value(42) == "42"
        @test Graphiti._kuzu_encode_value(3.14) == "3.14"
        @test Graphiti._kuzu_encode_value("Alice") == "'Alice'"
        @test Graphiti._kuzu_encode_value("O'Reilly") == "'O\\'Reilly'"
        @test Graphiti._kuzu_encode_value("a\\b") == "'a\\\\b'"
        @test Graphiti._kuzu_encode_value([1, 2, 3]) == "[1, 2, 3]"
        @test Graphiti._kuzu_encode_value(["a", "b"]) == "['a', 'b']"
    end

    @testset "param inlining" begin
        q = "MATCH (n {uuid: \$uuid}) RETURN n"
        out = Graphiti._kuzu_inline_params(q, Dict("uuid" => "abc"))
        @test out == "MATCH (n {uuid: 'abc'}) RETURN n"

        # Longest-name-first prevents \$ab matching inside \$abc
        q2 = "WHERE x = \$ab AND y = \$abc"
        out2 = Graphiti._kuzu_inline_params(q2, Dict("ab" => 1, "abc" => 2))
        @test out2 == "WHERE x = 1 AND y = 2"

        # Empty params is a no-op
        @test Graphiti._kuzu_inline_params("MATCH (n)", Dict()) == "MATCH (n)"

        # Multiple types
        q3 = "SET n.flag = \$f, n.n = \$n, n.s = \$s"
        out3 = Graphiti._kuzu_inline_params(q3, Dict("f" => true, "n" => 5, "s" => "hi"))
        @test occursin("n.flag = true", out3)
        @test occursin("n.n = 5", out3)
        @test occursin("n.s = 'hi'", out3)
    end

    # ── default backend raises ──────────────────────────────────────────────
    @testset "default backend raises informative error" begin
        d = KuzuDriver(db_path = "/tmp/nonexistent")
        @test_throws Graphiti.GraphitiKuzuError execute_query(d, "RETURN 1")
    end

    # ── driver construction ────────────────────────────────────────────────
    @testset "construction & env-vars" begin
        captured = Ref{Vector{Tuple{String,Dict}}}(Tuple{String,Dict}[])
        stub = (drv, q, p) -> begin
            push!(captured[], (q, p))
            return Dict{String,Any}[]
        end

        withenv("KUZU_DB_PATH" => "/var/data/kdb") do
            d = KuzuDriver(_query_fn = stub)
            @test d.db_path == "/var/data/kdb"
            @test d.schema_initialized == false
        end

        d2 = KuzuDriver(db_path = "/tmp/x", _query_fn = stub, auto_init_schema = true)
        @test d2.schema_initialized == true
        # auto_init_schema should have issued one CREATE per node + rel table
        n_create = count(t -> startswith(t[1], "CREATE NODE TABLE") || startswith(t[1], "CREATE REL TABLE"), captured[])
        @test n_create == length(Graphiti.KUZU_NODE_TABLES) + length(Graphiti.KUZU_REL_TABLES)
    end

    # ── init_schema! ────────────────────────────────────────────────────────
    @testset "init_schema!" begin
        issued = String[]
        stub = (drv, q, p) -> (push!(issued, q); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        init_schema!(d)
        @test d.schema_initialized == true
        @test any(occursin("CREATE NODE TABLE IF NOT EXISTS Entity", q) for q in issued)
        @test any(occursin("CREATE NODE TABLE IF NOT EXISTS Episodic", q) for q in issued)
        @test any(occursin("CREATE NODE TABLE IF NOT EXISTS Community", q) for q in issued)
        @test any(occursin("CREATE NODE TABLE IF NOT EXISTS Saga", q) for q in issued)
        @test any(occursin("CREATE REL TABLE IF NOT EXISTS RELATES_TO", q) for q in issued)
        @test any(occursin("CREATE REL TABLE IF NOT EXISTS MENTIONS", q) for q in issued)
        @test any(occursin("CREATE REL TABLE IF NOT EXISTS HAS_MEMBER", q) for q in issued)
    end

    # ── mutations ───────────────────────────────────────────────────────────
    @testset "save_node! EntityNode" begin
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        n = EntityNode(uuid = "u1", name = "Alice", summary = "hi", group_id = "g")
        save_node!(d, n)
        q, p = captured[]
        @test occursin("MERGE (n:Entity {uuid: \$uuid})", q)
        @test occursin("ON CREATE SET", q)
        @test occursin("ON MATCH", q)
        @test p["uuid"] == "u1"
        @test p["name"] == "Alice"
        @test p["group_id"] == "g"
    end

    @testset "save_node! EpisodicNode" begin
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        n = EpisodicNode(uuid = "e1", name = "ep", content = "text", group_id = "g")
        save_node!(d, n)
        q, p = captured[]
        @test occursin(":Episodic", q)
        @test p["content"] == "text"
    end

    @testset "save_node! CommunityNode" begin
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        n = CommunityNode(uuid = "c1", name = "comm", summary = "s", group_id = "g")
        save_node!(d, n)
        q, p = captured[]
        @test occursin(":Community", q)
        @test p["name"] == "comm"
    end

    @testset "save_node! SagaNode" begin
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        n = SagaNode(uuid = "s1", name = "saga", summary = "s", group_id = "g")
        save_node!(d, n)
        q, p = captured[]
        @test occursin(":Saga", q)
    end

    @testset "save_edge! EntityEdge (RELATES_TO)" begin
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        e = EntityEdge(uuid = "r1", source_node_uuid = "a", target_node_uuid = "b",
                       name = "knows", fact = "Alice knows Bob", group_id = "g")
        save_edge!(d, e)
        q, p = captured[]
        @test occursin("MATCH (a:Entity", q)
        @test occursin("(b:Entity", q)
        @test occursin(":RELATES_TO", q)
        @test p["src"] == "a" && p["tgt"] == "b"
        @test p["fact"] == "Alice knows Bob"
    end

    @testset "save_edge! EpisodicEdge (MENTIONS)" begin
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        e = EpisodicEdge(uuid = "m1", source_node_uuid = "ep", target_node_uuid = "ent",
                         group_id = "g")
        save_edge!(d, e)
        q, p = captured[]
        @test occursin(":Episodic", q)
        @test occursin(":Entity", q)
        @test occursin(":MENTIONS", q)
    end

    @testset "save_edge! CommunityEdge (HAS_MEMBER)" begin
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        e = CommunityEdge(uuid = "h1", source_node_uuid = "c", target_node_uuid = "ent",
                          group_id = "g")
        save_edge!(d, e)
        q, p = captured[]
        @test occursin(":Community", q)
        @test occursin(":HAS_MEMBER", q)
    end

    @testset "delete_node!/delete_edge!" begin
        issued = String[]
        stub = (drv, q, p) -> (push!(issued, q); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        delete_node!(d, "u1")
        delete_edge!(d, "r1")
        @test any(occursin("DETACH DELETE n", q) for q in issued)
        @test any(occursin("DELETE r", q) for q in issued)
    end

    @testset "clear! drops + recreates schema" begin
        issued = String[]
        stub = (drv, q, p) -> (push!(issued, q); Dict{String,Any}[])
        d = KuzuDriver(_query_fn = stub)
        clear!(d)
        @test any(occursin("DROP TABLE RELATES_TO", q) for q in issued)
        @test any(occursin("DROP TABLE Entity", q) for q in issued)
        @test any(occursin("CREATE NODE TABLE IF NOT EXISTS Entity", q) for q in issued)
        @test d.schema_initialized == true
    end

    @testset "clear! tolerates DROP errors on missing tables" begin
        # First DROP throws GraphitiKuzuError, subsequent CREATE IF NOT EXISTS succeed
        call_count = Ref(0)
        stub = (drv, q, p) -> begin
            call_count[] += 1
            if startswith(q, "DROP TABLE")
                throw(Graphiti.GraphitiKuzuError("table does not exist"))
            end
            return Dict{String,Any}[]
        end
        d = KuzuDriver(_query_fn = stub)
        @test_nowarn clear!(d)
        @test d.schema_initialized == true
    end

    @testset "non-Kuzu errors propagate from clear!" begin
        stub = (drv, q, p) -> begin
            startswith(q, "DROP TABLE") && throw(ArgumentError("network down"))
            return Dict{String,Any}[]
        end
        d = KuzuDriver(_query_fn = stub)
        @test_throws ArgumentError clear!(d)
    end

    # ── reads ───────────────────────────────────────────────────────────────
    @testset "get_community_nodes" begin
        rows = [Dict{String,Any}("uuid" => "c1", "name" => "C1", "summary" => "s1", "group_id" => "g")]
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); rows)
        d = KuzuDriver(_query_fn = stub)
        out = get_community_nodes(d, "g")
        @test length(out) == 1
        @test out[1].uuid == "c1"
        @test out[1].name == "C1"
        q, p = captured[]
        @test occursin("WHERE n.group_id = \$group_id", q)
        @test p["group_id"] == "g"

        # Empty group_id branch
        out2 = get_community_nodes(d, "")
        q2, _ = captured[]
        @test !occursin("WHERE", q2)
    end

    @testset "get_community_edges" begin
        rows = [Dict{String,Any}("uuid" => "h1", "src" => "c", "tgt" => "e", "group_id" => "g")]
        stub = (drv, q, p) -> rows
        d = KuzuDriver(_query_fn = stub)
        out = get_community_edges(d, "c")
        @test length(out) == 1
        @test out[1].source_node_uuid == "c"
        @test out[1].target_node_uuid == "e"
    end

    @testset "get_saga_nodes" begin
        rows = [Dict{String,Any}("uuid" => "s1", "name" => "Saga1", "summary" => "x", "group_id" => "g")]
        stub = (drv, q, p) -> rows
        d = KuzuDriver(_query_fn = stub)
        out = get_saga_nodes(d, "g")
        @test length(out) == 1
        @test out[1].name == "Saga1"
    end

    @testset "get_episodes_for_saga" begin
        rows = [Dict{String,Any}("uuid" => "e1", "name" => "ep", "content" => "c", "group_id" => "g")]
        captured = Ref{Tuple{String,Dict}}(("", Dict()))
        stub = (drv, q, p) -> (captured[] = (q, p); rows)
        d = KuzuDriver(_query_fn = stub)
        out = get_episodes_for_saga(d, "saga1")
        @test length(out) == 1
        @test out[1].uuid == "e1"
        _, p = captured[]
        @test p["saga_uuid"] == "saga1"
    end

    @testset "get_entity_*/get_episodic_* return empty (parity)" begin
        d = KuzuDriver(_query_fn = (drv, q, p) -> Dict{String,Any}[])
        @test get_entity_nodes(d, "g") == EntityNode[]
        @test get_entity_edges(d, "g") == EntityEdge[]
        @test get_episodic_nodes(d, "g") == EpisodicNode[]
        @test get_latest_episodic_node(d, "g") === nothing
        @test get_node(d, "any") === nothing
        @test get_edge(d, "any") === nothing
    end

    # ── error display ───────────────────────────────────────────────────────
    @testset "error message" begin
        e = Graphiti.GraphitiKuzuError("boom")
        io = IOBuffer()
        showerror(io, e)
        @test occursin("GraphitiKuzuError: boom", String(take!(io)))
    end
end
