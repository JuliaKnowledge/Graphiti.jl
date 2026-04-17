using Test
using Dates
using Graphiti
using SemanticSpacetime

@testset "GraphitiSemanticSpacetimeExt" begin
    client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())

    # Build a small four-class graph for group g1
    rain  = EntityNode(name="rain",      group_id="g1")
    flood = EntityNode(name="flood",     group_id="g1")
    river = EntityNode(name="river",     group_id="g1")
    water = EntityNode(name="water",     group_id="g1")
    color = EntityNode(name="blue",      group_id="g1")
    pond  = EntityNode(name="pond",      group_id="g1")
    # foreign group entity
    other = EntityNode(name="elsewhere", group_id="g2")
    for n in (rain, flood, river, water, color, pond, other)
        save_node!(client.driver, n)
    end

    # LEADSTO: rain -> flood (CAUSES), flood -> river (LEADS_TO)
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=rain.uuid,  target_node_uuid=flood.uuid,
        name="CAUSES",   fact="rain causes flood", group_id="g1",
        episodes=["ep1"]))
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=flood.uuid, target_node_uuid=river.uuid,
        name="LEADS_TO", fact="flood leads to river overflow", group_id="g1",
        episodes=["ep1"]))
    # CONTAINS: river PART_OF water-system, pond CONTAINS water
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=river.uuid, target_node_uuid=water.uuid,
        name="PART_OF", fact="river is part of water cycle", group_id="g1"))
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=pond.uuid,  target_node_uuid=water.uuid,
        name="CONTAINS", fact="pond contains water", group_id="g1"))
    # EXPRESS: water HAS_ATTRIBUTE blue
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=water.uuid, target_node_uuid=color.uuid,
        name="HAS_ATTRIBUTE", fact="water is blue", group_id="g1"))
    # NEAR: river SIMILAR_TO pond
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=river.uuid, target_node_uuid=pond.uuid,
        name="SIMILAR_TO", fact="river resembles pond", group_id="g1"))
    # whitespace + lowercase relation — exercises normalisation
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=rain.uuid, target_node_uuid=pond.uuid,
        name="leads to", fact="rain leads to pond formation", group_id="g1"))

    # Episodic node + edge
    ep = EpisodicNode(name="storm-report", content="A storm hit the valley",
                      group_id="g1")
    save_node!(client.driver, ep)
    save_edge!(client.driver, EpisodicEdge(source_node_uuid=ep.uuid,
                                           target_node_uuid=rain.uuid,
                                           group_id="g1"))

    # Community node + edge
    comm = CommunityNode(name="hydrology-team", group_id="g1")
    save_node!(client.driver, comm)
    save_edge!(client.driver, CommunityEdge(source_node_uuid=comm.uuid,
                                            target_node_uuid=river.uuid,
                                            group_id="g1"))
    save_edge!(client.driver, CommunityEdge(source_node_uuid=comm.uuid,
                                            target_node_uuid=pond.uuid,
                                            group_id="g1"))

    # Foreign-group edge — must not appear in g1's store
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=other.uuid, target_node_uuid=other.uuid,
        name="CAUSES", fact="noise", group_id="g2"))

    @testset "to_sst basic shape" begin
        store = to_sst(client; group_id="g1")
        @test store isa SemanticSpacetime.MemoryStore
        # 6 entity nodes + 1 episode + 1 community = 8 in g1
        @test SemanticSpacetime.node_count(store) == 8
        # 7 entity edges + 1 mention + 2 community memberships = 10 links
        @test SemanticSpacetime.link_count(store) == 10
        # No foreign-group leakage
        @test SemanticSpacetime.mem_get_nodes_by_name(store, "elsewhere") |> isempty
    end

    @testset "to_sst respects include_episodic / include_community" begin
        s2 = to_sst(client; group_id="g1",
                    include_episodic=false, include_community=false)
        @test SemanticSpacetime.node_count(s2) == 6
        @test SemanticSpacetime.link_count(s2) == 7  # only entity edges
    end

    @testset "default_st_classifier mappings" begin
        ext = Base.get_extension(Graphiti, :GraphitiSemanticSpacetimeExt)
        @test ext.default_st_classifier("CAUSES")        === :LEADSTO
        @test ext.default_st_classifier("leads to")      === :LEADSTO
        @test ext.default_st_classifier("PART_OF")       === :CONTAINS
        @test ext.default_st_classifier("HAS_ATTRIBUTE") === :EXPRESS
        @test ext.default_st_classifier("SIMILAR_TO")    === :NEAR
        @test ext.default_st_classifier("BOGUS_REL_42")  === :NEAR  # default
    end

    @testset "custom st_classifier" begin
        always_leadsto(_) = :LEADSTO
        store = to_sst(client; group_id="g1", st_classifier=always_leadsto,
                       include_episodic=false, include_community=false)
        @test SemanticSpacetime.node_count(store) == 6
        @test SemanticSpacetime.link_count(store) == 7
    end

    @testset "sst_query :forward_cone" begin
        cone = sst_query(client, :forward_cone, "rain";
                         group_id="g1", depth=3, limit=20)
        @test cone !== nothing
        # rain -> flood, rain -> pond at depth 1
        @test !isempty(cone.paths)
    end

    @testset "sst_query :backward_cone" begin
        cone = sst_query(client, :backward_cone, "river";
                         group_id="g1", depth=3, limit=20)
        @test cone !== nothing
    end

    @testset "sst_query :paths between two nodes" begin
        paths = sst_query(client, :paths, "rain", "river";
                          group_id="g1", max_depth=4)
        @test paths !== nothing
    end

    @testset "sst_query :summary" begin
        s = sst_query(client, :summary; group_id="g1")
        @test s.nodes == 8
        @test s.links == 10
    end

    @testset "sst_query: missing node returns nothing" begin
        @test sst_query(client, :forward_cone, "no-such-thing"; group_id="g1") === nothing
        @test sst_query(client, :paths, "rain", "no-such-thing"; group_id="g1") === nothing
    end

    @testset "sst_query: unknown symbol throws" begin
        @test_throws ArgumentError sst_query(client, :bogus; group_id="g1")
    end

    @testset "to_sst supplied store is reused" begin
        my_store = SemanticSpacetime.MemoryStore()
        out = to_sst(client; group_id="g1", store=my_store)
        @test out === my_store
    end

    @testset "empty graph" begin
        empty_client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())
        s = to_sst(empty_client; group_id="none")
        @test SemanticSpacetime.node_count(s) == 0
        @test SemanticSpacetime.link_count(s) == 0
    end
end
