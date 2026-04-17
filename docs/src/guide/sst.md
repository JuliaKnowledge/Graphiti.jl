# Semantic Spacetime — SST extension

Graphiti.jl ships with an optional
[`SemanticSpacetime.jl`](https://github.com/JuliaKnowledge/SemanticSpacetime.jl)
extension that materialises the Graphiti knowledge graph as an SST
`MemoryStore` — a typed, weighted graph in which every relation belongs
to one of **four** semantic spacetime classes:

| Class      | Meaning                              | Examples                                          |
|------------|--------------------------------------|---------------------------------------------------|
| `LEADSTO`  | Causation, succession, time-ordering | `CAUSES`, `LEADS_TO`, `BEFORE`, `PREVENTS`        |
| `CONTAINS` | Composition, membership              | `PART_OF`, `MEMBER_OF`, `HAS_PART`                |
| `EXPRESS`  | Property, role, identity             | `HAS_ATTRIBUTE`, `IS_A`, `HAS_PROPERTY`           |
| `NEAR`     | Proximity, similarity, association   | `SIMILAR_TO`, `RELATED_TO`, `COOCCURS_WITH`       |

The extension activates automatically when both packages are loaded:

```julia
using Graphiti
using SemanticSpacetime   # ← activates `GraphitiSemanticSpacetimeExt`
```

## Mapping

| Graphiti                            | SST                                                       |
|-------------------------------------|-----------------------------------------------------------|
| `EntityNode.name` (in `group_id`)   | `mem_vertex!(store, name, group_id)`                      |
| `EntityEdge`                        | `mem_edge!` with arrow classified by `st_classifier`      |
| `EpisodicEdge` (mention)            | `episode CONTAINS entity` (CONTAINS class)                |
| `CommunityEdge`                     | `community CONTAINS entity` (CONTAINS class)              |

The `group_id` becomes the SST **chapter**.

## Building a store

```julia
store = to_sst(client;
               group_id          = "project-1",
               st_classifier     = nothing,            # use the default
               include_episodic  = true,
               include_community = true,
               store             = MemoryStore())      # optional: reuse one
```

`st_classifier(name) -> Symbol` returns one of `:LEADSTO`, `:CONTAINS`,
`:EXPRESS`, `:NEAR`. The default vocabulary (in
`GraphitiSemanticSpacetimeExt.default_st_classifier`) covers ~50 common
relation names — anything unknown defaults to `:NEAR`. Override it to
project a custom ontology onto the four SST classes.

## Querying via `sst_query`

```julia
# Forward / backward causal cone from a single concept
sst_query(client, :forward_cone,  "rain"; group_id="g1", depth=3, limit=20)
sst_query(client, :backward_cone, "river"; group_id="g1", depth=3, limit=20)

# All paths between two concepts
sst_query(client, :paths, "rain", "river"; group_id="g1", max_depth=4)

# Shortest weighted path
sst_query(client, :dijkstra, "rain", "river"; group_id="g1")

# Quick stats
sst_query(client, :summary; group_id="g1")  # → (nodes=…, links=…)
```

Build-time keyword arguments (`group_id`, `store`, `st_classifier`,
`include_episodic`, `include_community`) are accepted by `sst_query`
and forwarded during store construction; any other keyword is forwarded
to the underlying SST function.

## End-to-end example

```julia
using Graphiti, SemanticSpacetime

client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())

add_triplet(client, "rain",  "CAUSES",        "flood";  group_id="weather")
add_triplet(client, "flood", "LEADS_TO",      "river";  group_id="weather")
add_triplet(client, "river", "PART_OF",       "water";  group_id="weather")
add_triplet(client, "water", "HAS_ATTRIBUTE", "blue";   group_id="weather")
add_triplet(client, "river", "SIMILAR_TO",    "pond";   group_id="weather")

cone = sst_query(client, :forward_cone, "rain";
                 group_id="weather", depth=4, limit=20)

paths = sst_query(client, :paths, "rain", "water"; group_id="weather", max_depth=5)
```

For the full SST query surface (cone search variants, fractional
intentionality, betweenness, eigenvector centrality, RDF round-trip,
N4L compilation, …) call `SemanticSpacetime` directly on the
`MemoryStore` returned by `to_sst`. See the
[SemanticSpacetime.jl docs](https://juliaknowledge.github.io/SemanticSpacetime.jl/).
