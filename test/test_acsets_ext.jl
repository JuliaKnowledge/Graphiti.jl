using Test
using Dates
using Graphiti
using ACSets

@testset "GraphitiACSetsExt" begin
    client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())

    alice = EntityNode(name="Alice", summary="Engineer", group_id="g1")
    bob   = EntityNode(name="Bob",   summary="Manager",  group_id="g1")
    carol = EntityNode(name="Carol", group_id="g1")
    save_node!(client.driver, alice); save_node!(client.driver, bob); save_node!(client.driver, carol)

    # Two REPORTS_TO facts: Alice→Bob (valid 2024 - expired 2025), Alice→Carol (valid from 2025)
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=alice.uuid, target_node_uuid=bob.uuid,
        name="REPORTS_TO", fact="Alice reports to Bob", group_id="g1",
        valid_at=DateTime(2024,1,1), invalid_at=DateTime(2025,1,1)))
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=alice.uuid, target_node_uuid=carol.uuid,
        name="REPORTS_TO", fact="Alice reports to Carol", group_id="g1",
        valid_at=DateTime(2025,1,1)))

    ep = EpisodicNode(name="onboarding", content="Alice joined", group_id="g1",
                      valid_at=DateTime(2024,1,1))
    save_node!(client.driver, ep)
    save_edge!(client.driver, EpisodicEdge(source_node_uuid=ep.uuid,
                                           target_node_uuid=alice.uuid, group_id="g1"))

    comm = CommunityNode(name="Eng team", group_id="g1")
    save_node!(client.driver, comm)
    save_edge!(client.driver, CommunityEdge(source_node_uuid=comm.uuid,
                                            target_node_uuid=alice.uuid, group_id="g1"))
    save_edge!(client.driver, CommunityEdge(source_node_uuid=comm.uuid,
                                            target_node_uuid=bob.uuid,   group_id="g1"))

    @testset "to_acset shape and counts" begin
        a = to_acset(client; group_id="g1")
        @test nparts(a, :Entity)    == 3
        @test nparts(a, :Episode)   == 1
        @test nparts(a, :Community) == 1
        @test nparts(a, :Fact)      == 2
        @test nparts(a, :Mentions)  == 1
        @test nparts(a, :HasMember) == 2

        # FK integrity: every Fact source/target points at a real Entity row.
        for f in 1:nparts(a, :Fact)
            @test 1 <= subpart(a, f, :fact_src) <= nparts(a, :Entity)
            @test 1 <= subpart(a, f, :fact_tgt) <= nparts(a, :Entity)
        end
    end

    @testset "facts_between query" begin
        rs = acset_query(client, :facts_between;
                         group_id="g1", source="Alice", target="Bob")
        @test length(rs) == 1
        @test rs[1].fact == "Alice reports to Bob"
    end

    @testset "entities_in_community query" begin
        members = acset_query(client, :entities_in_community;
                              group_id="g1", community="Eng team")
        @test sort(members) == ["Alice", "Bob"]
    end

    @testset "facts_valid_at temporal slice" begin
        # Mid-2024: only Alice→Bob is valid.
        mid24 = acset_query(client, :facts_valid_at;
                            group_id="g1", at=DateTime(2024,6,1))
        @test length(mid24) == 1
        @test mid24[1].target == "Bob"

        # Mid-2025: only Alice→Carol is valid (Bob expired Jan 2025).
        mid25 = acset_query(client, :facts_valid_at;
                            group_id="g1", at=DateTime(2025,6,1))
        @test length(mid25) == 1
        @test mid25[1].target == "Carol"
    end

    @testset "group_id scoping" begin
        # Carol-in-other-group should not bleed in.
        dave = EntityNode(name="Dave", group_id="other")
        save_node!(client.driver, dave)
        a = to_acset(client; group_id="g1")
        names_g1 = [subpart(a, i, :e_name) for i in 1:nparts(a, :Entity)]
        @test "Dave" ∉ names_g1
        a2 = to_acset(client; group_id="other")
        @test nparts(a2, :Entity) == 1
        @test subpart(a2, 1, :e_name) == "Dave"
    end

    @testset "unknown query errors" begin
        @test_throws ErrorException acset_query(client, :no_such; group_id="g1")
    end
end
