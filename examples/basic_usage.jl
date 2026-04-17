"""
basic_usage.jl — Graphiti.jl getting-started example.

Run with:
    julia --project=/path/to/Graphiti.jl examples/basic_usage.jl
"""

using Graphiti
using Dates

# ── 1. Create a client with in-memory storage ──────────────────────────────
driver   = MemoryDriver()
llm      = EchoLLMClient(fallback = Dict{String,Any}(
    "extracted_entities" => [
        Dict("name" => "Alice",    "summary" => "A software engineer"),
        Dict("name" => "Acme Corp","summary" => "A technology company"),
    ],
    "edges" => [
        Dict("source_entity_name" => "Alice",
             "target_entity_name" => "Acme Corp",
             "relation_type"      => "WORKS_AT",
             "fact"               => "Alice works at Acme Corp as an engineer",
             "valid_at"           => nothing,
             "invalid_at"         => nothing),
    ],
    "is_duplicate" => false,
    "contradicts"  => false,
))
embedder = DeterministicEmbedder(64)
client   = GraphitiClient(driver, llm, embedder)

# ── 2. Ingest an episode ───────────────────────────────────────────────────
result = add_episode(
    client,
    "ep-1",
    "Alice joined the ML platform team at Acme Corp on 2024-03-01.";
    source      = TEXT,
    group_id    = "demo",
    valid_at    = DateTime(2024, 3, 1),
)

println("Extracted $(length(result.nodes)) entities and $(length(result.edges)) relationships.")

# ── 3. Search ─────────────────────────────────────────────────────────────
hits = search(client, "Alice's role"; group_id = "demo")
println("\n=== Search results ===")
println(build_context_string(hits))

# ── 4. Build communities ───────────────────────────────────────────────────
communities = build_communities!(client; group_ids = ["demo"])
println("\n=== Communities ===")
for c in communities
    println("  • $(c.name): $(c.summary)")
end

println("\nToken usage: $(client.usage.total_tokens) tokens (approx.)")
