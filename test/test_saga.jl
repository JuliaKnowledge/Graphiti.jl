@testset "Phase 4: Sagas" begin

    function make_saga_client()
        d   = MemoryDriver()
        em  = DeterministicEmbedder(4)
        llm = EchoLLMClient(fallback = Dict{String,Any}(
            "summary" => "A series of events about the project.",
        ))
        GraphitiClient(d, llm, em)
    end

    @testset "add_saga! creates and persists a SagaNode" begin
        client = make_saga_client()

        saga = add_saga!(client, "Q1 Project Log"; group_id="proj")
        @test saga isa SagaNode
        @test saga.name == "Q1 Project Log"
        @test saga.group_id == "proj"
        @test get_node(client.driver, saga.uuid) !== nothing
    end

    @testset "assign_episode_to_saga! links episodes" begin
        client = make_saga_client()
        saga   = add_saga!(client, "Sprint 1")

        ep = EpisodicNode(name="ep1", content="Team kicked off sprint 1.", source=TEXT)
        save_node!(client.driver, ep)

        assign_episode_to_saga!(client.driver, ep, saga.uuid)
        @test ep.saga_uuid == saga.uuid

        # Persisted version should also have the saga_uuid
        fetched = get_node(client.driver, ep.uuid)
        @test fetched isa EpisodicNode
        @test fetched.saga_uuid == saga.uuid
    end

    @testset "summarize_saga! produces summary from episodes" begin
        client = make_saga_client()
        saga   = add_saga!(client, "Product Release")

        for (i, content) in enumerate([
            "Design meeting held.",
            "Development started.",
            "Testing completed.",
        ])
            ep = EpisodicNode(
                name    = "ep$(i)",
                content = content,
                source  = TEXT,
                group_id = "",
            )
            save_node!(client.driver, ep)
            assign_episode_to_saga!(client.driver, ep, saga.uuid)
        end

        updated = summarize_saga!(client, saga.uuid)
        @test updated !== nothing
        @test !isempty(updated.summary)
        @test updated.summary == "A series of events about the project."
    end

    @testset "summarize_saga! returns nothing for unknown uuid" begin
        client = make_saga_client()
        result = summarize_saga!(client, "non-existent-uuid")
        @test result === nothing
    end

    @testset "summarize_saga! returns saga when no episodes" begin
        client = make_saga_client()
        saga   = add_saga!(client, "Empty Saga")
        result = summarize_saga!(client, saga.uuid)
        @test result !== nothing
        @test result.uuid == saga.uuid
        @test isempty(result.summary)   # no episodes → empty summary
    end

    @testset "get_saga_nodes filters by group_id" begin
        client = make_saga_client()
        add_saga!(client, "Saga A"; group_id="g1")
        add_saga!(client, "Saga B"; group_id="g1")
        add_saga!(client, "Saga C"; group_id="g2")

        g1 = get_saga_nodes(client.driver, "g1")
        g2 = get_saga_nodes(client.driver, "g2")
        all = get_saga_nodes(client.driver, "")

        @test length(g1) == 2
        @test length(g2) == 1
        @test length(all) == 3
    end

    @testset "TokenUsage tracking via summarize_saga!" begin
        client = make_saga_client()
        saga   = add_saga!(client, "Tracked Saga")

        ep = EpisodicNode(name="e1", content="Event one.", source=TEXT)
        save_node!(client.driver, ep)
        assign_episode_to_saga!(client.driver, ep, saga.uuid)

        before_total = client.usage.total_tokens
        summarize_saga!(client, saga.uuid)
        @test client.usage.total_tokens > before_total
    end
end
