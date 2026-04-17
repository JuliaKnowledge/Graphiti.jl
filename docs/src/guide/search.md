# Search & Retrieval

## SearchConfig

Control how searches are executed:

```julia
config = SearchConfig(
    search_methods      = [COSINE_SIMILARITY, BM25_SEARCH],
    reranker            = RRF,
    limit               = 10,
    sim_min_score       = 0.0,
    mmr_lambda          = 0.5,
    bfs_max_depth       = 2,
    include_nodes       = true,
    include_edges       = true,
    include_episodes    = false,
    include_communities = false,
)
```

### Search methods

| Method | Description |
|--------|-------------|
| `COSINE_SIMILARITY` | Embedding similarity (requires embedded nodes/edges) |
| `BM25_SEARCH` | Full-text keyword matching (BM25 approximation) |
| `BFS_SEARCH` | Breadth-first graph traversal from embedding seed nodes |

### Rerankers

| Reranker | Description |
|----------|-------------|
| `RRF` | Reciprocal Rank Fusion — robust multi-list combination |
| `MMR` | Maximal Marginal Relevance — promotes diversity |

## search

```julia
results = search(client, "Alice's current role"; group_id = "acme")
```

Returns a `SearchResults` with `edges`, `nodes`, `communities`, and their scores.

## build_context_string

Format results for injection into an LLM system prompt:

```julia
ctx = build_context_string(results)
# Returns:
# Facts:
# - Alice works at Acme Corp as an engineer [valid from 2024-03-01T...]
#
# Entities:
# - Alice: Software engineer
```

Communities appear in a `## Communities` section when `include_communities = true`.
