# Graphiti.jl

A Julia port of [Graphiti](https://github.com/getzep/graphiti), a **temporal
knowledge graph engine** for AI agents. Graphiti.jl ingests episodic data
(messages, documents, JSON), extracts entities and bi-temporal relationship
facts via an LLM, deduplicates them against an evolving graph, and supports
hybrid (vector + BM25 + BFS) retrieval with reranking (RRF / MMR).

## Status

- ✅ **Phase 1** — core types, `MemoryDriver`, injectable `Neo4jDriver`,
  offline `EchoLLMClient` + `RandomEmbedder`/`DeterministicEmbedder`, prompt
  templates, entity & edge extraction.
- ✅ **Phase 2** — entity/edge deduplication, LLM-backed temporal invalidation,
  `add_episode` / `add_episode_bulk` / `add_triplet` pipelines.
- ✅ **Phase 3** — cosine / BM25 / BFS search, RRF & MMR rerankers, top-level
  `search(client, query)` returning `SearchResults`, `build_context_string`.
- 🚧 Phases 4–6 (community detection, provider integrations, MCP server,
  full-production persistence) are future work — see `GRAPHITI_PORT_PLAN.md`.

## Install

```julia
using Pkg
Pkg.develop(path="/path/to/Graphiti.jl")
```

## Quickstart

```julia
using Graphiti

client = GraphitiClient(
    MemoryDriver(),
    EchoLLMClient(fallback = Dict{String,Any}(
        "extracted_entities" => [Dict("name"=>"Alice","summary"=>"engineer")],
        "edges"              => Dict[],
    )),
    RandomEmbedder(128),
)

add_triplet(client, "Alice", "WORKS_AT", "Acme Corp",
    "Alice works at Acme Corp"; group_id="demo")

results = search(client, "who works at Acme?"; group_id="demo")
println(build_context_string(results))
```

## Testing

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

All tests are offline — no Neo4j or external LLM required.
