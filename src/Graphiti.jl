"""
    Graphiti

Julia port of [Graphiti](https://github.com/getzep/graphiti), a temporal
knowledge graph engine for AI agents.

Graphiti.jl builds and maintains a three-tier knowledge graph:

- **Episodic subgraph** — raw input data (messages, text, JSON)
- **Semantic entity subgraph** — entities with bi-temporal relationship edges
- **Community subgraph** — clusters of related entities with summaries

See the upstream repository and the `GRAPHITI_PORT_PLAN.md` in the parent
workspace for the full design.
"""
module Graphiti

using Base64
using Dates
using HTTP
using JSON3
using LinearAlgebra
using Logging
using Random
using SHA
using Statistics
using UUIDs
using Unicode

# ── Core types ───────────────────────────────────────────────────────────────
include("types.jl")
include("nodes.jl")
include("edges.jl")

# ── Backends ─────────────────────────────────────────────────────────────────
include("driver/driver.jl")
include("driver/memory.jl")
include("driver/neo4j.jl")

# ── LLM and embedding abstractions ───────────────────────────────────────────
include("llm/llm.jl")
include("embedder/embedder.jl")

# ── Prompt templates ─────────────────────────────────────────────────────────
include("prompts/prompts.jl")

# ── Search config/result types (needed by GraphitiClient) ────────────────────
include("search/search.jl")

# ── Utilities (GraphitiClient, TokenUsage, cosine_similarity) ────────────────
include("utils.jl")

# ── OpenAI / Azure OpenAI concrete LLM and embedder implementations ──────────
include("llm/openai.jl")
include("embedder/openai.jl")

# ── Extraction pipeline ──────────────────────────────────────────────────────
include("extract/nodes.jl")
include("extract/edges.jl")
include("extract/temporal.jl")

# ── Deduplication ────────────────────────────────────────────────────────────
include("dedupe/nodes.jl")
include("dedupe/edges.jl")

# ── Search implementations ───────────────────────────────────────────────────
include("search/cosine.jl")
include("search/fulltext.jl")
include("search/bfs.jl")
include("search/crossencoder.jl")
include("search/reranker.jl")

# ── Community detection + summarization ──────────────────────────────────────
include("community/summary.jl")
include("community/detection.jl")

# ── Saga (episode-group) management ──────────────────────────────────────────
include("saga.jl")

# ── Standalone context builder ────────────────────────────────────────────────
include("context_builder.jl")

# ── High-level operations ────────────────────────────────────────────────────
include("episode.jl")
include("triplet.jl")

# ── MCP (Model Context Protocol) server ──────────────────────────────────────
include("mcp.jl")

# ── Public API exports ───────────────────────────────────────────────────────
export Graphiti,
       # Enums
       EpisodeType, MESSAGE, TEXT, JSON_DATA,
       SearchMethod, COSINE_SIMILARITY, BM25_SEARCH, BFS_SEARCH,
       RerankerMethod, RRF, MMR, NODE_DISTANCE, EPISODE_MENTIONS, CROSS_ENCODER,
       # Nodes
       EntityNode, EpisodicNode, CommunityNode, SagaNode,
       # Edges
       EntityEdge, EpisodicEdge, CommunityEdge,
       # Drivers
       AbstractGraphDriver, MemoryDriver, Neo4jDriver,
       execute_query, save_node!, save_edge!, get_node, get_edge,
       delete_node!, delete_edge!, clear!,
       get_entity_nodes, get_entity_edges,
       get_episodic_nodes, get_latest_episodic_node,
       get_community_nodes, get_community_edges,
       get_saga_nodes,
       get_episodes_for_saga,
       # LLM / embedder
       AbstractLLMClient, AbstractEmbedder,
       EchoLLMClient, enqueue_response!, complete, complete_json,
       OpenAILLMClient, AzureOpenAILLMClient,
       RandomEmbedder, DeterministicEmbedder, embed,
       OpenAIEmbedder, AzureOpenAIEmbedder,
       # Prompts
       format_prompt,
       # Extraction / dedup
       extract_entities, extract_edges_from_episode, parse_temporal,
       dedupe_entities!, dedupe_edges!, invalidate_edges!,
       # Search
       SearchConfig, SearchResults, search, build_context_string,
       cosine_search_edges, cosine_search_nodes, cosine_search_communities,
       cosine_search_episodes,
       bm25_search_edges, bm25_search_nodes,
       bfs_search, rrf_rerank, mmr_rerank,
       AbstractCrossEncoder, DummyCrossEncoder, LLMCrossEncoder, rerank,
       # Community
       build_communities!, update_community!, summarize_community!,
       # Saga
       add_saga!, assign_episode_to_saga!, summarize_saga!,
       # Context builder
       ContextBuilder, build,
       # High-level
       GraphitiClient, AddEpisodeResults,
       add_episode, add_episode_bulk, add_triplet, ingest_conversation!,
       build_indices_and_constraints, clear_data,
       # Utility
       cosine_similarity,
       TokenUsage, reset!,
       # MCP
       mcp_serve

end # module Graphiti
