# Graphiti.jl

![Julia 1.10+](https://img.shields.io/badge/julia-1.10%2B-blue)
![Tests](https://img.shields.io/badge/tests-201%20passing-brightgreen)
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
| 6 | MCP server, production Neo4j queries, OpenAI/Azure providers, cross-encoder rerank, episode search | ✅ |

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
# Graphiti.jl   |  200       1    201  ...
```

All tests are offline — no Neo4j or external LLM required.  The 1 broken test
is the AgentFramework.jl integration test, which is skipped when that package
is not installed.

## Production providers

Graphiti.jl ships with concrete LLM and embedder clients for both OpenAI and
Azure OpenAI.  Both accept an injectable `_request_fn` for offline tests and
track token usage from the provider's `usage` field.

```julia
llm      = OpenAILLMClient(model = "gpt-4o-mini")             # reads OPENAI_API_KEY
embedder = OpenAIEmbedder(model = "text-embedding-3-small")
client   = GraphitiClient(MemoryDriver(), llm, embedder)

# Azure variant
llm_az = AzureOpenAILLMClient(
    endpoint = "https://my-aoai.openai.azure.com",
    deployment = "gpt-4o-mini",
    api_version = "2024-06-01",
)
```

See [`examples/openai_usage.jl`](examples/openai_usage.jl) for a full example.

Token usage is tracked across *every* LLM call made through a `GraphitiClient`
(entity extraction, edge extraction, temporal invalidation, dedup, community
summarization, cross-encoder rerank):

```julia
add_episode(client, "ep", "Alice met Bob"; group_id = "demo")
println(client.usage.total_tokens)
```

## Cross-encoder reranking

`SearchConfig(cross_encoder = DummyCrossEncoder())` (or `LLMCrossEncoder(llm)`)
applies a final rerank step on the top-k edges/nodes after RRF/MMR.

## Episode search

`SearchConfig(include_episodes = true)` enables cosine search over episode
`content_embedding`s.  `add_episode` automatically populates this embedding so
episodes become first-class search targets alongside entities and facts.

## MCP server

Graphiti.jl exposes its main operations as an MCP (Model Context Protocol)
server over JSON-RPC 2.0 / stdio — four tools: `search`, `add_episode`,
`get_entity`, `get_edge`.  Launch from any Julia entry script:

```julia
using Graphiti
client = GraphitiClient(MemoryDriver(), OpenAILLMClient(), OpenAIEmbedder())
mcp_serve(client)
```

Point any MCP-capable client (Claude Desktop, GitHub Copilot, …) at the
resulting stdio pipe.

## Examples

- [`examples/basic_usage.jl`](examples/basic_usage.jl) — ingest, extract, search
- [`examples/temporal_queries.jl`](examples/temporal_queries.jl) — fact supersession
- [`examples/agent_memory.jl`](examples/agent_memory.jl) — ContextBuilder agent loop
- [`examples/openai_usage.jl`](examples/openai_usage.jl) — OpenAI / Azure OpenAI providers

## Documentation

```bash
cd docs
julia --project=. make.jl
# output in docs/build/
```

## Contributing

See [`GRAPHITI_PORT_PLAN.md`](../GRAPHITI_PORT_PLAN.md) for the full roadmap.
Phase 6 is complete — remaining work tracked in the top-level plan.
