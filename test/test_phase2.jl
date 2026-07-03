using Dates

@testset "Phase 2: Dedup, Temporal, Episode operations" begin
    @testset "Temporal parsing" begin
        ref = DateTime(2024, 6, 15, 12, 0, 0)

        @test parse_temporal(nothing, ref) === nothing
        @test parse_temporal("", ref) === nothing
        @test parse_temporal("2024-01-01", ref) == DateTime(2024, 1, 1)
        @test parse_temporal("today", ref) == ref
        @test parse_temporal("yesterday", ref) == ref - Day(1)
        @test parse_temporal("last week", ref) == ref - Week(1)
        @test parse_temporal("known issue", ref) === nothing
    end

    @testset "Entity dedup - exact match" begin
        d = MemoryDriver()
        embedder = RandomEmbedder(4)
        llm = EchoLLMClient()

        alice1 = EntityNode(name="Alice", group_id="g1")
        alice1.name_embedding = [1.0, 0.0, 0.0, 0.0]
        save_node!(d, alice1)

        alice2 = EntityNode(name="alice", group_id="g1")
        result = dedupe_entities!(d, embedder, llm, [alice2], "g1")

        @test length(result) == 1
        @test result[1].uuid == alice1.uuid
        @test length(get_entity_nodes(d, "g1")) == 1
    end

    @testset "Entity dedup - embedding similarity" begin
        d = MemoryDriver()
        embedder = DeterministicEmbedder(4)
        llm = EchoLLMClient()

        emb1 = [1.0, 0.0, 0.0, 0.0]
        emb2 = [0.999, 0.001, 0.0, 0.0]
        n2 = emb2 ./ sqrt(sum(emb2 .^ 2))

        alice = EntityNode(name="Alice Smith", group_id="g1")
        alice.name_embedding = emb1
        save_node!(d, alice)

        alice2 = EntityNode(name="Alice J. Smith", group_id="g1")
        alice2.name_embedding = n2

        result = dedupe_entities!(d, embedder, llm, [alice2], "g1"; sim_threshold=0.9)
        @test length(result) == 1
        @test result[1].uuid == alice.uuid
        @test length(get_entity_nodes(d, "g1")) == 1
    end

    @testset "Edge invalidation" begin
        d = MemoryDriver()
        embedder = RandomEmbedder(8)
        llm = EchoLLMClient(fallback=Dict{String,Any}("contradicts" => true, "reason" => "superseded"))

        old_edge = EntityEdge(
            source_node_uuid="alice", target_node_uuid="acme",
            name="WORKS_AT", fact="Alice works at Acme",
            group_id="g1",
        )
        old_edge.fact_embedding = embed(embedder, old_edge.fact)
        save_edge!(d, old_edge)

        new_edge = EntityEdge(
            source_node_uuid="alice", target_node_uuid="google",
            name="WORKS_AT", fact="Alice works at Google",
            group_id="g1",
        )
        new_edge.fact_embedding = embed(embedder, new_edge.fact)
        save_edge!(d, new_edge)

        ref_time = now(UTC)
        invalidate_edges!(d, llm, [new_edge], "g1", ref_time)

        updated = get_edge(d, old_edge.uuid)::EntityEdge
        @test updated.invalid_at !== nothing
    end

    @testset "add_triplet" begin
        d = MemoryDriver()
        llm = EchoLLMClient()
        embedder = RandomEmbedder(8)
        client = GraphitiClient(d, llm, embedder)

        src, edge, tgt = add_triplet(client, "Alice", "KNOWS", "Bob", "Alice knows Bob"; group_id="g1")
        @test src.name == "Alice"
        @test tgt.name == "Bob"
        @test edge.name == "KNOWS"
        @test edge.fact == "Alice knows Bob"
        @test !isempty(d.entity_nodes)
        @test !isempty(d.entity_edges)
    end

    @testset "add_episode_bulk" begin
        d = MemoryDriver()
        llm = EchoLLMClient(fallback=Dict{String,Any}(
            "extracted_entities" => [],
            "edges" => []
        ))
        embedder = RandomEmbedder(8)
        client = GraphitiClient(d, llm, embedder)

        episodes = [
            (name="ep1", content="Alice works at Acme", source=TEXT,
             source_description="", group_id="g1", valid_at=now(UTC)),
            (name="ep2", content="Bob lives in NYC", source=TEXT,
             source_description="", group_id="g1", valid_at=now(UTC)),
        ]
        results = add_episode_bulk(client, episodes; group_id="g1")
        @test length(results) == 2
        @test length(get_episodic_nodes(d, "g1")) == 2
    end

    @testset "add_episode invalidates using fact valid_at" begin
        d = MemoryDriver()
        llm = EchoLLMClient()
        embedder = DeterministicEmbedder(8)
        client = GraphitiClient(d, llm, embedder)

        alice = EntityNode(name = "Alice", group_id = "g1")
        alice.name_embedding = embed(embedder, "Alice")
        acme = EntityNode(name = "Acme", group_id = "g1")
        acme.name_embedding = embed(embedder, "Acme")
        save_node!(d, alice)
        save_node!(d, acme)

        old_edge = EntityEdge(
            source_node_uuid = alice.uuid,
            target_node_uuid = acme.uuid,
            name = "WORKS_AT",
            fact = "Alice works at Acme",
            group_id = "g1",
        )
        old_edge.fact_embedding = embed(embedder, old_edge.fact)
        save_edge!(d, old_edge)

        enqueue_response!(llm, Dict{String, Any}(
            "extracted_entities" => [
                Dict("name" => "Alice", "summary" => "person"),
                Dict("name" => "Google", "summary" => "company"),
            ],
        ))
        enqueue_response!(llm, Dict{String, Any}(
            "edges" => [
                Dict(
                    "source_entity_name" => "Alice",
                    "target_entity_name" => "Google",
                    "relation_type" => "WORKS_AT",
                    "fact" => "Alice works at Google",
                    "valid_at" => "2024-01-10",
                    "invalid_at" => nothing,
                ),
            ],
        ))
        enqueue_response!(llm, Dict{String, Any}("contradicts" => true))

        valid_at = DateTime(2024, 1, 10)
        ingestion_time = DateTime(2024, 6, 1, 9, 0, 0)
        add_episode(client, "backfill", "Alice works at Google";
            group_id = "g1", valid_at = valid_at, reference_time = ingestion_time)

        updated = get_edge(d, old_edge.uuid)::EntityEdge
        @test updated.invalid_at == valid_at
    end

    @testset "add_episode_bulk forwards custom reference_time" begin
        d = MemoryDriver()
        llm = EchoLLMClient()
        embedder = DeterministicEmbedder(8)
        client = GraphitiClient(d, llm, embedder)

        alice = EntityNode(name = "Alice", group_id = "g1")
        alice.name_embedding = embed(embedder, "Alice")
        acme = EntityNode(name = "Acme", group_id = "g1")
        acme.name_embedding = embed(embedder, "Acme")
        save_node!(d, alice)
        save_node!(d, acme)

        old_edge = EntityEdge(
            source_node_uuid = alice.uuid,
            target_node_uuid = acme.uuid,
            name = "WORKS_AT",
            fact = "Alice works at Acme",
            group_id = "g1",
        )
        old_edge.fact_embedding = embed(embedder, old_edge.fact)
        save_edge!(d, old_edge)

        enqueue_response!(llm, Dict{String, Any}(
            "extracted_entities" => [
                Dict("name" => "Alice", "summary" => "person"),
                Dict("name" => "Google", "summary" => "company"),
            ],
        ))
        enqueue_response!(llm, Dict{String, Any}(
            "edges" => [
                Dict(
                    "source_entity_name" => "Alice",
                    "target_entity_name" => "Google",
                    "relation_type" => "WORKS_AT",
                    "fact" => "Alice works at Google",
                    "valid_at" => nothing,
                    "invalid_at" => nothing,
                ),
            ],
        ))
        enqueue_response!(llm, Dict{String, Any}("contradicts" => true))

        fallback_reference_time = DateTime(2024, 2, 20, 15, 0, 0)
        add_episode_bulk(client, [
            (
                name = "bulk-backfill",
                content = "Alice works at Google",
                source = TEXT,
                source_description = "",
                group_id = "g1",
                valid_at = DateTime(2024, 1, 10),
                reference_time = fallback_reference_time,
            ),
        ]; group_id = "g1")

        updated = get_edge(d, old_edge.uuid)::EntityEdge
        @test updated.invalid_at == fallback_reference_time
    end
end
