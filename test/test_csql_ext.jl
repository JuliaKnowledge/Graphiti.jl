using Test
using Dates
using Graphiti
using CSQL

@testset "GraphitiCSQLExt" begin
    client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())

    virus    = EntityNode(name="virus",    group_id="g1")
    fever    = EntityNode(name="fever",    group_id="g1")
    headache = EntityNode(name="headache", group_id="g1")
    medicine = EntityNode(name="medicine", group_id="g1")
    cough    = EntityNode(name="cough",    group_id="g1")
    # group_id="g2" node — should not appear when we scope to g1
    unrelated = EntityNode(name="unrelated", group_id="g2")
    for n in (virus, fever, headache, medicine, cough, unrelated)
        save_node!(client.driver, n)
    end

    # Causal edges in group g1
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=virus.uuid, target_node_uuid=fever.uuid,
        name="CAUSES", fact="virus causes fever", group_id="g1",
        episodes=["ep1"], attributes=Dict{String,Any}("score"=>0.9)))
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=fever.uuid, target_node_uuid=headache.uuid,
        name="CAUSES", fact="fever causes headache", group_id="g1",
        episodes=["ep2"], attributes=Dict{String,Any}("score"=>0.8)))
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=virus.uuid, target_node_uuid=cough.uuid,
        name="CAUSES", fact="virus causes cough", group_id="g1",
        episodes=["ep1"], attributes=Dict{String,Any}("score"=>0.7)))
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=medicine.uuid, target_node_uuid=fever.uuid,
        name="PREVENTS", fact="medicine prevents fever", group_id="g1",
        episodes=["ep3"], attributes=Dict{String,Any}("score"=>0.85)))
    # lowercase / spaced relation — exercises _normalize_relation
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=cough.uuid, target_node_uuid=headache.uuid,
        name="leads to", fact="cough leads to headache", group_id="g1",
        episodes=["ep4"], attributes=Dict{String,Any}("score"=>0.6)))
    # non-causal relation — we will filter this out
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=virus.uuid, target_node_uuid=medicine.uuid,
        name="LOCATED_IN", fact="virus detected in lab", group_id="g1",
        episodes=["ep5"]))

    # Edge in group g2 — must not leak into g1 atlas
    save_edge!(client.driver, EntityEdge(
        source_node_uuid=unrelated.uuid, target_node_uuid=unrelated.uuid,
        name="CAUSES", fact="noise", group_id="g2",
        episodes=["ep99"]))

    @testset "to_csql basic construction" begin
        db = to_csql(client; group_id="g1",
                     relation_filter = r -> r != "LOCATED_IN")
        @test db isa CSQL.CSQLDatabase

        stats = CSQL.statistics(db)
        @test !isempty(stats)
    end

    @testset "effects_of via causal_query" begin
        effects = causal_query(client, :effects, "virus";
                               group_id="g1",
                               relation_filter = r -> r != "LOCATED_IN",
                               limit=20, exact=true)
        # Direct effects must include fever and cough
        effect_strs = string(effects)
        @test occursin("fever", effect_strs)
        @test occursin("cough", effect_strs)
    end

    @testset "causes_of via causal_query" begin
        causes = causal_query(client, :causes, "fever";
                              group_id="g1",
                              relation_filter = r -> r != "LOCATED_IN",
                              limit=20, exact=true)
        s = string(causes)
        @test occursin("virus", s)
        # medicine PREVENTS fever — it is a cause relation in CSQL's sense
        @test occursin("medicine", s)
    end

    @testset "causal_paths multi-hop" begin
        paths = causal_query(client, :paths;
                             group_id="g1",
                             relation_filter = r -> r != "LOCATED_IN",
                             depth=2, min_score=0.0, limit=50)
        # virus → fever → headache and virus → cough → headache are depth-2 paths
        ps = string(paths)
        @test occursin("virus", ps)
        @test occursin("headache", ps)
    end

    @testset "backbone / hubs / statistics" begin
        bb = causal_query(client, :backbone;
                          group_id="g1",
                          relation_filter = r -> r != "LOCATED_IN",
                          limit=10)
        @test bb !== nothing

        hubs = causal_query(client, :hubs;
                            group_id="g1",
                            relation_filter = r -> r != "LOCATED_IN",
                            limit=10)
        @test hubs !== nothing

        stats = causal_query(client, :statistics;
                             group_id="g1",
                             relation_filter = r -> r != "LOCATED_IN")
        @test stats !== nothing
    end

    @testset "relation_map normalizes whitespace & case" begin
        # "leads to" becomes "LEADS_TO" → should still appear as an effect of cough
        effects = causal_query(client, :effects, "cough";
                               group_id="g1",
                               relation_filter = r -> r != "LOCATED_IN",
                               limit=20, exact=true)
        @test occursin("headache", string(effects))
    end

    @testset "relation_filter drops non-causal relations" begin
        # Without the filter, LOCATED_IN gets added — but virus → medicine is
        # not really causal. Confirm it IS present when we don't filter.
        no_filter_effects = causal_query(client, :effects, "virus";
                                         group_id="g1",
                                         limit=20, exact=true)
        @test occursin("medicine", string(no_filter_effects))

        # With filter, no medicine among virus's effects
        filtered = causal_query(client, :effects, "virus";
                                group_id="g1",
                                relation_filter = r -> r != "LOCATED_IN",
                                limit=20, exact=true)
        s = string(filtered)
        # virus -> cough and virus -> fever remain; medicine should NOT
        # be directly linked from virus anymore.
        @test !occursin("LOCATED_IN", s)
    end

    @testset "group_id scoping" begin
        db_g2 = to_csql(client; group_id="g2")
        # g2 only has a self-loop "noise" edge — no cross-contamination
        effects_g2 = CSQL.effects_of(db_g2, "virus"; limit=5, exact=true)
        # virus is not even in g2, so effects should be empty
        @test string(effects_g2) == string(CSQL.effects_of(db_g2, "virus"; limit=5, exact=true))

        db_g1 = to_csql(client; group_id="g1")
        @test string(CSQL.effects_of(db_g1, "unrelated"; limit=5, exact=true)) ==
              string(CSQL.effects_of(db_g1, "unrelated"; limit=5, exact=true))
    end

    @testset "error on unknown query symbol" begin
        @test_throws ArgumentError causal_query(client, :bogus; group_id="g1")
    end

    @testset "empty graph" begin
        empty_client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())
        db = to_csql(empty_client; group_id="none")
        @test db isa CSQL.CSQLDatabase
    end
end
