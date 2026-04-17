"""
agent_memory.jl — Wiring Graphiti.jl into an agent via ContextBuilder.

This example shows the pattern without requiring AgentFramework.jl.
If AgentFramework.jl is available, a thin integration wrapper is shown.

Run with:
    julia --project=/path/to/Graphiti.jl examples/agent_memory.jl
"""

using Graphiti
using Dates

# ── Build a long-lived client (shared across agent sessions) ───────────────
driver   = MemoryDriver()
llm      = EchoLLMClient(fallback = Dict{String,Any}(
    "extracted_entities" => [],
    "edges"              => [],
    "contradicts"        => false,
    "name"               => "Demo Community",
    "summary"            => "A cluster of entities from demo conversations.",
))
embedder = DeterministicEmbedder(32)
client   = GraphitiClient(driver, llm, embedder;
    config = SearchConfig(include_communities = true))

# ── ContextBuilder wraps the client ───────────────────────────────────────
builder = ContextBuilder(
    client   = client,
    config   = client.config,
    group_id = "agent-demo",
)

# ── Simulate an agent loop ─────────────────────────────────────────────────
function run_agent_turn(user_message::String; group_id::String = "agent-demo")
    # 1. Retrieve relevant context from the knowledge graph
    ctx = build(builder, user_message)

    # 2. (In production) inject ctx into your LLM system prompt
    if !isempty(ctx)
        println("[Context injected into prompt]\n$ctx\n")
    else
        println("[No relevant context found]")
    end

    # 3. (Placeholder) call your LLM and get a response
    response = "I have processed your message about: $user_message"
    println("[Agent response]: $response\n")

    # 4. Persist the conversation turn into the knowledge graph
    ingest_conversation!(client,
        [
            Dict("role" => "user",      "content" => user_message),
            Dict("role" => "assistant", "content" => response),
        ];
        group_id = group_id,
    )

    return response
end

run_agent_turn("Who is Alice and where does she work?")
run_agent_turn("Tell me about the Python ecosystem.")

println("Episodes stored: $(length(get_episodic_nodes(driver, \"agent-demo\")))")
println("Entities stored: $(length(get_entity_nodes(driver, \"agent-demo\")))")
println("Token usage (approx): $(client.usage.total_tokens)")

# ── Optional AgentFramework.jl integration ────────────────────────────────
@isdefined(AgentFramework) || begin
    println("""
    ─────────────────────────────────────────────────────
    To integrate with AgentFramework.jl add:

        struct GraphitiContextProvider <: AgentFramework.BaseContextProvider
            builder::Graphiti.ContextBuilder
        end

        function AgentFramework.before_run!(p::GraphitiContextProvider, agent, session, ctx, state)
            user_msg = last_user_message(ctx)
            graph_ctx = Graphiti.build(p.builder, user_msg)
            isempty(graph_ctx) || push_system_message!(ctx, graph_ctx)
        end

    Then add GraphitiContextProvider(builder) to your Agent's context_providers.
    ─────────────────────────────────────────────────────
    """)
end
