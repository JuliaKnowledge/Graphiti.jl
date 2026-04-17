# Graphiti.jl

![Julia 1.10+](https://img.shields.io/badge/julia-1.10%2B-blue)
![Tests](https://img.shields.io/badge/tests-135%20passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)

A Julia port of [Graphiti](https://github.com/getzep/graphiti), a **temporal
knowledge graph engine** for AI agents.  Graphiti.jl ingests episodic data
(messages, documents, JSON), extracts entities and bi-temporal relationship
facts via an LLM, deduplicates them against an evolving graph, groups related
entities into **communities**, and supports hybrid (vector + BM25 + BFS)
retrieval with reranking (RRF / MMR).

## Architecture

```
            User
             │
             ▼
    ┌─────────────────────────────────┐
    │        GraphitiClient           │
    │  driver / llm / embedder        │
    │  config :: SearchConfig         │
    │  usage  :: TokenUsage           │
    └───────────┬─────────────────────┘
                │
   ┌────────────┼──────────────┐
   │            │              │
   ▼            ▼              ▼
Episodic    Entity        Community
subgraph    subgraph      subgraph
(raw data)  (facts +      (clusters +
            bi-temporal   LLM summaries)
            edges)
```

## Status

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | Types, MemoryDriver, Neo4jDriver, EchoLLMClient, extraction | ✅ |
| 2 | Dedup, temporal invalidation, `add_episode` / `add_triplet` | ✅ |
| 3 | Cosine / BM25 / BFS search, RRF & MMR, `build_context_string` | ✅ |
| 4 | Community detection, summarisation, sagas, community search | ✅ |
| 5 | `ContextBuilder`, `ingest_conversation!`, token tracking, docs | ✅ |
| 6 | MCP server, production Neo4j queries, streaming, OpenAI provider | 🚧 |

## Install

```julia
using Pkg
Pkg.develop(path="/path/to/Graphiti.jl")
```

## Quickstart

```julia
using Graphiti, Dates

# 1. Create a client
client = GraphitiClient(
    MemoryDriver(),
    EchoLLMClient(fallback = Dict{String,Any}(
        "extracted_entities" => [Dict("name"=>"Alice","summary"=>"engineer")],
        "edges" => [],
        "contradicts" => false,
        "name" => "Tech Group", "summary" => "A technology cluster.",
    )),
    DeterministicEmbedder(64),
)

# 2. Ingest an episode
add_episode(client, "ep-1",
    "Alice joined Acme Corp as an ML engineer on 2024-03-01";
    source   = TEXT,
    group_id = "demo",
    valid_at = DateTime(2024, 3, 1),
)

# 3. Search and build a system-prompt context string
results = search(client, "Alice's role"; group_id = "demo")
println(build_context_string(results))

# 4. Detect communities
communities = build_communities!(client; group_ids = ["demo"])
println("$(length(communities)) communities found.")

# 5. ContextBuilder — works with any agent framework
builder = ContextBuilder(client = client, group_id = "demo")
ctx = build(builder, "What does Alice do?")
# inject `ctx` into your system prompt

# 6. Ingest a chat transcript
ingest_conversation!(client, [
    Dict("role" => "user",      "content" => "Tell me about Alice."),
    Dict("role" => "assistant", "content" => "Alice is an ML engineer at Acme."),
]; group_id = "demo")

# 7. Track token usage
println("LLM tokens used (approx): $(client.usage.total_tokens)")
```

## Testing

```bash
cd Graphiti.jl
julia --project=. -e 'using Pkg; Pkg.test()'
# Test Summary: | Pass  Broken  Total   Time
# Graphiti.jl   |  134       1    135  ...
```

All tests are offline — no Neo4j or external LLM required.  The 1 broken test
is the AgentFramework.jl integration test, which is skipped when that package
is not installed.

## Examples

- [`examples/basic_usage.jl`](examples/basic_usage.jl) — ingest, extract, search
- [`examples/temporal_queries.jl`](examples/temporal_queries.jl) — fact supersession
- [`examples/agent_memory.jl`](examples/agent_memory.jl) — ContextBuilder agent loop

## Documentation

```bash
cd docs
julia --project=. make.jl
# output in docs/build/
```

## Contributing

See [`GRAPHITI_PORT_PLAN.md`](../GRAPHITI_PORT_PLAN.md) for the full roadmap.
Phase 6 work (MCP server, production Neo4j queries, OpenAI/Azure providers) is
the next milestone.
