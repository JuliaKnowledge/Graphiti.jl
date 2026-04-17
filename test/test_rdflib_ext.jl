using Test
using Dates
using Graphiti
using RDFLib

@testset "GraphitiRDFLibExt" begin
    client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())

    # Two entities + a fact between them, with bi-temporal valid_at.
    alice = EntityNode(name="Alice", summary="Engineer", group_id="g1",
                       labels=["Person"])
    bob   = EntityNode(name="Bob",   summary="Manager",  group_id="g1",
                       labels=["Person"])
    save_node!(client.driver, alice)
    save_node!(client.driver, bob)

    fact = EntityEdge(source_node_uuid=alice.uuid, target_node_uuid=bob.uuid,
                      name="REPORTS_TO", fact="Alice reports to Bob",
                      group_id="g1",
                      valid_at=DateTime(2024, 1, 1),
                      reference_time=DateTime(2024, 6, 1))
    save_edge!(client.driver, fact)

    # An episode that mentions Alice.
    ep = EpisodicNode(name="onboarding", content="Alice joined the team",
                      group_id="g1", valid_at=DateTime(2024, 1, 1))
    save_node!(client.driver, ep)
    ee = EpisodicEdge(source_node_uuid=ep.uuid, target_node_uuid=alice.uuid,
                      group_id="g1")
    save_edge!(client.driver, ee)

    # A community grouping Alice and Bob.
    comm = CommunityNode(name="Eng team", summary="Engineering reports",
                         group_id="g1")
    save_node!(client.driver, comm)
    save_edge!(client.driver, CommunityEdge(source_node_uuid=comm.uuid,
                                            target_node_uuid=alice.uuid,
                                            group_id="g1"))
    save_edge!(client.driver, CommunityEdge(source_node_uuid=comm.uuid,
                                            target_node_uuid=bob.uuid,
                                            group_id="g1"))

    @testset "to_rdf_graph populates the graph" begin
        g = to_rdf_graph(client; group_id="g1")
        @test isa(g, RDFLib.RDFGraph)

        ttl = serialize(g, RDFLib.TurtleFormat())
        @test occursin("graphiti:Entity", ttl) || occursin("/Entity", ttl)
        @test occursin("Alice", ttl)
        @test occursin("Bob", ttl)
        @test occursin("REPORTS_TO", ttl) || occursin("Alice reports to Bob", ttl)
        @test occursin("Eng team", ttl)
        @test occursin("onboarding", ttl) || occursin("Alice joined the team", ttl)
        # Bi-temporal datestamp should appear.
        @test occursin("2024", ttl)
    end

    @testset "kg_to_turtle convenience" begin
        s = kg_to_turtle(client; group_id="g1")
        @test isa(s, AbstractString)
        @test !isempty(s)
        @test occursin("Alice", s)
    end

    @testset "sparql_kg returns entities by label" begin
        # Use rdfs:label to retrieve entity names.
        rows = sparql_kg(client,
            "PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#> " *
            "PREFIX graphiti: <https://graphiti.julia/ns#> " *
            "SELECT ?label WHERE { ?e a graphiti:Entity ; rdfs:label ?label }";
            group_id="g1")
        labels = String[]
        for row in rows
            for v in (row isa NamedTuple ? values(row) : row)
                push!(labels, string(v))
            end
        end
        @test any(occursin("Alice", l) for l in labels)
        @test any(occursin("Bob",   l) for l in labels)
    end

    @testset "group_id scoping" begin
        # Entity in a different group — must NOT appear when scoped to g1.
        carol = EntityNode(name="Carol", group_id="other")
        save_node!(client.driver, carol)
        ttl_g1 = kg_to_turtle(client; group_id="g1")
        @test !occursin("Carol", ttl_g1)
        ttl_other = kg_to_turtle(client; group_id="other")
        @test occursin("Carol", ttl_other)
    end
end
