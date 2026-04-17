# Graphiti.jl

**Graphiti.jl** is a Julia port of [Graphiti](https://github.com/getzep/graphiti),
a temporal knowledge graph engine designed for AI agents.

## What is Graphiti?

Graphiti maintains a **three-tier knowledge graph** that lets agents:

1. **Remember conversations** — episodes persist as first-class graph nodes.
2. **Extract structured knowledge** — entities and relationships are extracted via LLM.
3. **Reason over time** — every fact carries `valid_at` / `invalid_at` bi-temporal stamps.
4. **Cluster knowledge into communities** — related entities are grouped and summarised automatically.

## Quick-start

```julia
using Graphiti, Dates

# --- 1. Create a client (MemoryDriver = no external database needed) ---
driver   = MemoryDriver()
llm      = EchoLLMClient()          # replace with OpenAILLMClient in production
embedder = DeterministicEmbedder(64)
client   = GraphitiClient(driver, llm, embedder)

# --- 2. Ingest an episode ---
result = add_episode(client, "meeting-notes",
    "Alice joined the ML platform team at Acme Corp on 2024-03-01.";
    source = TEXT, group_id = "acme")

# result.nodes  → extracted EntityNodes
# result.edges  → extracted EntityEdges

# --- 3. Search ---
hits = search(client, "Alice's role"; group_id = "acme")
println(build_context_string(hits))

# --- 4. Build communities ---
communities = build_communities!(client; group_ids = ["acme"])
println("Found \$(length(communities)) communities")

# --- 5. Use ContextBuilder with any agent framework ---
builder = ContextBuilder(client = client, group_id = "acme")
ctx = build(builder, "What does Alice do?")
# Inject `ctx` into your agent's system prompt
```

## Architecture overview

```
            ┌──────────────────────────────────────────────┐
            │              GraphitiClient                  │
            │  driver :: AbstractGraphDriver               │
            │  llm    :: AbstractLLMClient                 │
            │  embedder:: AbstractEmbedder                 │
            │  config :: SearchConfig                      │
            │  usage  :: TokenUsage                        │
            └───────────────┬──────────────────────────────┘
                            │
          ┌─────────────────┼──────────────────────┐
          │                 │                       │
    ┌─────▼──────┐  ┌───────▼──────┐   ┌───────────▼──────┐
    │  Episodic  │  │  Entity      │   │  Community       │
    │  subgraph  │  │  subgraph    │   │  subgraph        │
    │ EpisodicNode│ │ EntityNode   │   │ CommunityNode    │
    │ EpisodicEdge│ │ EntityEdge   │   │ CommunityEdge    │
    └────────────┘  └─────────────┘   └──────────────────┘
```

See the [Guides](@ref) for detailed documentation on each subsystem.
