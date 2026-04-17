# Ingestion

## add_episode

The primary ingestion entry point:

```julia
result = add_episode(
    client, "my-episode", "Alice joined Acme Corp on 2024-03-01";
    source      = TEXT,
    group_id    = "acme",
    valid_at    = DateTime(2024, 3, 1),
)
```

`add_episode` runs the full pipeline:

1. Save the raw `EpisodicNode`.
2. Extract `EntityNode`s via LLM.
3. Embed entity names and deduplicate against existing nodes.
4. Extract `EntityEdge`s via LLM.
5. Embed facts and deduplicate edges.
6. Detect contradictions and set `invalid_at` on superseded edges.
7. Create `EpisodicEdge` links from the episode to its entities.

## add_episode_bulk

Ingest multiple episodes in sequence:

```julia
episodes = [
    (name="ep1", content="...", source=TEXT, group_id="g1", valid_at=now(UTC)),
    (name="ep2", content="...", source=TEXT, group_id="g1", valid_at=now(UTC)),
]
results = add_episode_bulk(client, episodes)
```

## add_triplet

Directly insert a subject–predicate–object fact without LLM extraction:

```julia
src, edge, tgt = add_triplet(client, "Alice", "WORKS_AT", "Acme", "Alice works at Acme";
    group_id = "acme")
```

## ingest_conversation!

Turn a chat transcript into a chain of episodes (one per message):

```julia
messages = [
    Dict("role" => "user",      "content" => "Tell me about the project."),
    Dict("role" => "assistant", "content" => "The project launched in Q1 2024."),
]
ingest_conversation!(client, messages; group_id = "chat1")
```

Empty content strings are silently skipped.
