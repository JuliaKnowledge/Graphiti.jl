# Core Concepts

## The Three-Tier Graph

Graphiti organises knowledge into three complementary subgraphs:

| Tier | Node type | Edge type | Purpose |
|------|-----------|-----------|---------|
| Episodic | `EpisodicNode` | `EpisodicEdge` | Raw inputs: messages, documents, events |
| Semantic | `EntityNode` | `EntityEdge` | Extracted facts with bi-temporal metadata |
| Community | `CommunityNode` | `CommunityEdge` | Clusters of related entities with summaries |

## Bi-temporal Model

Every `EntityEdge` carries two temporal dimensions:

* **valid_at** — when the fact became true in the world.
* **invalid_at** — when the fact stopped being true (set by contradiction detection).
* **created_at** / **expired_at** — when the record was stored/removed in the graph.

This allows point-in-time queries and graceful handling of contradictions without
data loss.

## Episode Types

```julia
@enum EpisodeType MESSAGE TEXT JSON_DATA
```

* `TEXT` — a plain text document or note.
* `MESSAGE` — a conversational utterance (use with `ingest_conversation!`).
* `JSON_DATA` — a structured JSON payload (entity/relationship hints).

## Sagas

A `SagaNode` groups related `EpisodicNode`s into a named narrative thread.
Assign episodes to a saga with `assign_episode_to_saga!`, then call
`summarize_saga!` to produce a high-level summary via LLM.

```julia
saga = add_saga!(client, "Product Launch Q1"; group_id = "proj")
assign_episode_to_saga!(client.driver, episode, saga.uuid)
summarize_saga!(client, saga.uuid)
```
