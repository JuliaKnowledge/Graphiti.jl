# API Reference

## Nodes

```@autodocs
Modules = [Graphiti]
Filter  = t -> t isa DataType && supertype(t) == Any &&
               t ∉ (Graphiti.SearchConfig, Graphiti.SearchResults,
                    Graphiti.AddEpisodeResults, Graphiti.ContextBuilder,
                    Graphiti.TokenUsage)
```

## Edges

```@docs
EntityEdge
EpisodicEdge
CommunityEdge
```

## Client & Configuration

```@docs
GraphitiClient
SearchConfig
SearchResults
TokenUsage
ContextBuilder
```

## Drivers

```@docs
MemoryDriver
Neo4jDriver
```

## LLM & Embedders

```@docs
EchoLLMClient
DeterministicEmbedder
RandomEmbedder
```

## Ingestion

```@docs
add_episode
add_episode_bulk
add_triplet
ingest_conversation!
```

## Search

```@docs
search
build_context_string
cosine_search_edges
cosine_search_nodes
cosine_search_communities
bm25_search_edges
bm25_search_nodes
bfs_search
rrf_rerank
mmr_rerank
```

## Communities

```@docs
build_communities!
update_community!
summarize_community!
```

## Sagas

```@docs
add_saga!
assign_episode_to_saga!
summarize_saga!
```

## Utilities

```@docs
cosine_similarity
format_prompt
reset!
```
