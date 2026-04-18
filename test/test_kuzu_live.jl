# Live integration test for KuzuDriver via the libkuzu FFI shim.
#
# Requires libkuzu.dylib (Mac) / libkuzu.so (Linux). Download from:
#   https://github.com/kuzudb/kuzu/releases
# Then set:
#   KUZU_LIVE=1
#   KUZU_LIB=/path/to/libkuzu.dylib   (or .so)
#
# The whole FFI surface lives in `Graphiti.KuzuFFI` — this test exercises
# it end-to-end against a real database.

using Test
using Graphiti

if get(ENV, "KUZU_LIVE", "") != "1"
    @info "Skipping live Kùzu tests (set KUZU_LIVE=1 and KUZU_LIB=/path/to/libkuzu.{so,dylib})"
else
    libpath = get(ENV, "KUZU_LIB", "")
    isempty(libpath) && error("KUZU_LIB must point to libkuzu.{so,dylib}")

    db_path = joinpath(mktempdir(), "kuzu_live_db")
    d, conn = Graphiti.KuzuFFI.open_driver(libpath; db_path = db_path,
                                           auto_init_schema = true)

    try
        @testset "KuzuDriver — live (libkuzu FFI via Graphiti.KuzuFFI)" begin
            @test d.schema_initialized == true

            # Sanity: simple RETURN
            rows = execute_query(d, "RETURN 1 AS x")
            @test length(rows) == 1
            @test get(rows[1], "x", nothing) == 1

            # Mutations
            save_node!(d, EntityNode(uuid="a", name="Alice", summary="person", group_id="g1"))
            save_node!(d, EntityNode(uuid="b", name="Bob",   summary="person", group_id="g1"))
            save_edge!(d, EntityEdge(uuid="r1", source_node_uuid="a",
                                     target_node_uuid="b", name="knows",
                                     fact="Alice knows Bob", group_id="g1"))

            rows = execute_query(d,
                "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity) " *
                "WHERE a.uuid = \$u " *
                "RETURN r.fact AS fact, b.name AS name";
                params = Dict("u" => "a"),
            )
            @test length(rows) == 1
            @test rows[1]["fact"] == "Alice knows Bob"
            @test rows[1]["name"] == "Bob"

            # String-escape via inliner against a real engine
            save_node!(d, EntityNode(uuid="o", name="O'Reilly",
                                     summary="publisher", group_id="g1"))
            rows = execute_query(d,
                "MATCH (n:Entity) WHERE n.uuid = \$u RETURN n.name AS name";
                params = Dict("u" => "o"),
            )
            @test rows[1]["name"] == "O'Reilly"

            # Communities + reads
            save_node!(d, CommunityNode(uuid="c1", name="Friends",
                                         summary="", group_id="g1"))
            save_edge!(d, CommunityEdge(uuid="h1", source_node_uuid="c1",
                                         target_node_uuid="a",  group_id="g1"))
            comms = get_community_nodes(d, "g1")
            @test length(comms) == 1
            @test comms[1].name == "Friends"
            cedges = get_community_edges(d, "c1")
            @test length(cedges) == 1
            @test cedges[1].target_node_uuid == "a"

            # Saga + episode
            save_node!(d, SagaNode(uuid="s1", name="Sprint", summary="",
                                    group_id="g1"))
            sagas = get_saga_nodes(d, "g1")
            @test length(sagas) == 1
            @test sagas[1].name == "Sprint"

            # Deletion
            delete_edge!(d, "r1")
            rows = execute_query(d,
                "MATCH ()-[r:RELATES_TO]->() WHERE r.uuid = \$u RETURN count(r) AS c";
                params = Dict("u" => "r1"),
            )
            @test rows[1]["c"] == 0

            delete_node!(d, "b")
            rows = execute_query(d,
                "MATCH (n:Entity) WHERE n.uuid = \$u RETURN count(n) AS c";
                params = Dict("u" => "b"),
            )
            @test rows[1]["c"] == 0

            # clear! drops everything and recreates schema
            clear!(d)
            rows = execute_query(d, "MATCH (n:Entity) RETURN count(n) AS c")
            @test rows[1]["c"] == 0
            @test d.schema_initialized == true
        end
    finally
        Graphiti.KuzuFFI.close!(conn)
    end
end
