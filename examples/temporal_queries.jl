"""
temporal_queries.jl — Demonstrate bi-temporal fact tracking in Graphiti.jl.

Shows how `valid_at` / `invalid_at` allow an agent to ask
"what was true on date X?" even when facts have since been superseded.

Run with:
    julia --project=/path/to/Graphiti.jl examples/temporal_queries.jl
"""

using Graphiti
using Dates

# ── Setup ──────────────────────────────────────────────────────────────────
driver   = MemoryDriver()
llm      = EchoLLMClient(fallback = Dict{String,Any}(
    "extracted_entities" => [],
    "edges"              => [],
    "contradicts"        => true,   # always flag contradiction for demo
    "reason"             => "Superseded by newer fact",
))
embedder = DeterministicEmbedder(8)
client   = GraphitiClient(driver, llm, embedder)

# ── Fact 1: Alice works at Acme (2023-01) ─────────────────────────────────
alice = EntityNode(name="Alice", group_id="demo")
acme  = EntityNode(name="Acme Corp", group_id="demo")
for n in [alice, acme]
    n.name_embedding = embed(embedder, n.name)
    save_node!(driver, n)
end

old_fact = EntityEdge(
    source_node_uuid = alice.uuid,
    target_node_uuid = acme.uuid,
    name             = "WORKS_AT",
    fact             = "Alice works at Acme Corp",
    group_id         = "demo",
    valid_at         = DateTime(2023, 1, 1),
)
old_fact.fact_embedding = embed(embedder, old_fact.fact)
save_edge!(driver, old_fact)

# ── Fact 2: Alice now works at Beta Inc (2024-06) — contradicts Fact 1 ────
beta = EntityNode(name="Beta Inc", group_id="demo")
beta.name_embedding = embed(embedder, beta.name)
save_node!(driver, beta)

new_fact = EntityEdge(
    source_node_uuid = alice.uuid,
    target_node_uuid = beta.uuid,
    name             = "WORKS_AT",
    fact             = "Alice works at Beta Inc",
    group_id         = "demo",
    valid_at         = DateTime(2024, 6, 1),
)
new_fact.fact_embedding = embed(embedder, new_fact.fact)
save_edge!(driver, new_fact)

ref_time = DateTime(2024, 6, 1)
invalidate_edges!(driver, llm, [new_fact], "demo", ref_time)

# ── Query: what's true now? ────────────────────────────────────────────────
println("=== All edges (including superseded) ===")
for e in get_entity_edges(driver, "demo")
    status = e.invalid_at !== nothing ? "[superseded at $(e.invalid_at)]" : "[current]"
    println("  • $(e.fact)  $status")
end

println("\n=== Active facts only ===")
active = filter(e -> e.invalid_at === nothing, get_entity_edges(driver, "demo"))
for e in active
    println("  • $(e.fact)  [valid from $(e.valid_at)]")
end
