@testset "Phase 5: Integration, TokenUsage, ContextBuilder" begin

    @testset "TokenUsage struct" begin
        u = TokenUsage()
        @test u.prompt_tokens == 0
        @test u.completion_tokens == 0
        @test u.total_tokens == 0

        u.prompt_tokens += 10
        u.completion_tokens += 5
        u.total_tokens += 15
        reset!(u)
        @test u.prompt_tokens == 0
    end

    @testset "GraphitiClient carries TokenUsage" begin
        d      = MemoryDriver()
        em     = DeterministicEmbedder(4)
        llm    = EchoLLMClient(fallback = Dict{String,Any}("x" => 1))
        client = GraphitiClient(d, llm, em)
        @test client.usage isa TokenUsage
        @test client.usage.total_tokens == 0
    end

    @testset "_complete_json! increments usage" begin
        d      = MemoryDriver()
        em     = DeterministicEmbedder(4)
        llm    = EchoLLMClient(fallback = Dict{String,Any}("answer" => "hello world"))
        client = GraphitiClient(d, llm, em)

        msgs = [Dict("role" => "user", "content" => "What is the capital of France?")]
        Graphiti._complete_json!(client, msgs)

        @test client.usage.prompt_tokens > 0
        @test client.usage.completion_tokens > 0
        @test client.usage.total_tokens > 0
    end

    @testset "ContextBuilder — build returns context string" begin
        d  = MemoryDriver()
        em = DeterministicEmbedder(4)
        llm = EchoLLMClient()
        client = GraphitiClient(d, llm, em;
            config = SearchConfig(include_nodes = true, include_edges = true))

        # Populate a node with a known embedding so search can find it
        n = EntityNode(name = "Paris", summary = "Capital of France", group_id = "")
        n.name_embedding = [1.0, 0.0, 0.0, 0.0]
        save_node!(d, n)

        em.embeddings["capital of france"] = [1.0, 0.0, 0.0, 0.0]

        builder = ContextBuilder(client = client, group_id = "")
        ctx = build(builder, "capital of france")

        @test ctx isa String
        @test occursin("Paris", ctx)
    end

    @testset "ingest_conversation! creates episodes per message" begin
        d   = MemoryDriver()
        em  = DeterministicEmbedder(4)
        llm = EchoLLMClient(fallback = Dict{String,Any}(
            "extracted_entities" => [],
            "edges" => [],
        ))
        client = GraphitiClient(d, llm, em)

        messages = [
            Dict("role" => "user",      "content" => "Tell me about Julia."),
            Dict("role" => "assistant", "content" => "Julia is a fast scientific language."),
            Dict("role" => "user",      "content" => ""),    # empty — should be skipped
        ]

        results = ingest_conversation!(client, messages; group_id="chat1")
        @test length(results) == 2   # empty message is skipped
        eps = get_episodic_nodes(d, "chat1")
        @test length(eps) == 2
        roles = Set{String}(ep.source_description for ep in eps)
        @test "user" in roles
        @test "assistant" in roles
    end

    # ── AgentFramework conditional tests ─────────────────────────────────────
    HAS_AF = false
    try
        @eval using AgentFramework
        HAS_AF = true
    catch
    end

    if HAS_AF
        @testset "GraphitiContextProvider (AgentFramework available)" begin
            @test isdefined(AgentFramework, :BaseContextProvider)
        end
    else
        @info "AgentFramework not available — skipping AgentFramework integration tests"
        @test_skip "AgentFramework not loadable"
    end
end
