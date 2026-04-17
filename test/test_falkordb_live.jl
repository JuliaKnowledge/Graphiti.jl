# Live integration test for FalkorDBDriver.
#
# Requires a running FalkorDB instance. Start one with:
#
#     docker run -d --rm --name graphiti-falkor -p 6379:6379 falkordb/falkordb:latest
#
# Configure the host/port via env vars (defaults: 127.0.0.1:6379):
#
#     FALKORDB_HOST, FALKORDB_PORT, FALKORDB_PASSWORD, FALKORDB_GRAPH
#
# The test is gated on FALKORDB_LIVE=1 so the regular suite stays offline.

using Test
using Graphiti

if get(ENV, "FALKORDB_LIVE", "") != "1"
    @info "Skipping live FalkorDB tests (set FALKORDB_LIVE=1 to enable)"
else
    @testset "FalkorDBDriver — live" begin
        graph = "graphiti_live_$(rand(UInt32))"
        d = FalkorDBDriver(graph = graph)

        # Sanity: server reachable
        rows = execute_query(d, "RETURN 1 AS x")
        @test length(rows) == 1
        @test get(rows[1], "x", nothing) == 1

        try
            # Schema-free mutation surface
            ent_a = EntityNode(uuid = "a", name = "Alice",   summary = "person", group_id = "g1")
            ent_b = EntityNode(uuid = "b", name = "Bob",     summary = "person", group_id = "g1")
            save_node!(d, ent_a)
            save_node!(d, ent_b)

            edge = EntityEdge(uuid = "r1", source_node_uuid = "a",
                              target_node_uuid = "b", name = "knows",
                              fact = "Alice knows Bob", group_id = "g1")
            save_edge!(d, edge)

            # Round-trip via Cypher (read methods on FalkorDBDriver are
            # intentionally minimal; query directly to verify state)
            rows = execute_query(d, "MATCH (n:Entity) RETURN count(n) AS c")
            @test get(rows[1], "c", 0) == 2

            rows = execute_query(d,
                "MATCH (a:Entity {uuid: \$u})-[r:RELATES_TO]->(b) " *
                "RETURN r.fact AS fact, b.name AS to_name";
                params = Dict("u" => "a"),
            )
            @test length(rows) == 1
            @test rows[1]["fact"] == "Alice knows Bob"
            @test rows[1]["to_name"] == "Bob"

            # Param-prelude string-escape against a real server
            ent_o = EntityNode(uuid = "o", name = "O'Reilly",
                               summary = "publisher", group_id = "g1")
            save_node!(d, ent_o)
            rows = execute_query(d,
                "MATCH (n:Entity {uuid: \$u}) RETURN n.name AS name";
                params = Dict("u" => "o"),
            )
            @test rows[1]["name"] == "O'Reilly"

            # Community + saga shapes
            comm = CommunityNode(uuid = "c1", name = "Friends", summary = "",
                                 group_id = "g1")
            save_node!(d, comm)
            save_edge!(d, CommunityEdge(uuid = "h1", source_node_uuid = "c1",
                                         target_node_uuid = "a",  group_id = "g1"))
            communities = get_community_nodes(d, "g1")
            @test length(communities) == 1
            @test communities[1].name == "Friends"
            edges = get_community_edges(d, "c1")
            @test length(edges) == 1
            @test edges[1].target_node_uuid == "a"

            # Deletions
            delete_edge!(d, "r1")
            rows = execute_query(d,
                "MATCH ()-[r:RELATES_TO {uuid: \$u}]->() RETURN count(r) AS c";
                params = Dict("u" => "r1"),
            )
            @test get(rows[1], "c", -1) == 0

            delete_node!(d, "b")
            rows = execute_query(d,
                "MATCH (n:Entity {uuid: \$u}) RETURN count(n) AS c";
                params = Dict("u" => "b"),
            )
            @test get(rows[1], "c", -1) == 0
        finally
            # Clean up — clear! is idempotent against missing graphs
            clear!(d)
        end
    end
end
