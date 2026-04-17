# Causal SQL — CSQL extension

Graphiti.jl ships with an optional
[`CSQL.jl`](https://github.com/JuliaKnowledge/CSQL.jl) extension that
projects the temporal entity graph into a **causal SQL atlas** — a
SQLite- or DuckDB-backed database of `(subject, relation, object)`
triples plus aggregate support statistics — and exposes CSQL's causal
query surface (direct cause/effect lookup, multi-hop chains, backbone
extraction, hub detection, interventional cuts).

The extension activates automatically when both packages are loaded:

```julia
using Graphiti
using CSQL   # ← activates `GraphitiCSQLExt`
```

## Mapping: Graphiti → CSQL

Every `EntityEdge` becomes a CSQL triple:

| Graphiti `EntityEdge`      | CSQL column            |
|----------------------------|------------------------|
| `source_node` entity name  | `subject`              |
| `name` (normalized)        | `relation`             |
| `target_node` entity name  | `object`               |
| first value of `episodes`  | `doc_id`               |
| `attributes["score"]`      | `score`, `confidence`  |

Relation names are normalized to upper case with underscores
(`"leads to"` → `"LEADS_TO"`). CSQL recognises a fixed vocabulary of
relation types (`CAUSES`, `PREVENTS`, `INHIBITS`, `INCREASES`,
`REDUCES`, `TREATS`, `MODULATES`, …) plus `UNKNOWN_REL` for anything
else.

## Building the atlas

```julia
db = to_csql(client;
             group_id = "project-1",
             backend  = :sqlite,         # or :duckdb, :memory
             relation_filter = r -> r != "LOCATED_IN",
             relation_map    = identity,
             default_score   = 0.5)
```

- `relation_filter(name)` — return `false` to drop an edge (e.g. non-causal
  relations like `LOCATED_IN`, `EMPLOYED_BY`).
- `relation_map(name)` — rewrite a relation name before normalization
  (e.g. collapse synonyms).
- `default_score` — used when no `score` / `confidence` attribute is on
  the edge.

`to_csql` returns a `CSQL.CSQLDatabase` that can be queried directly
with any function from the CSQL API.

## The `causal_query` dispatcher

For convenience the extension provides a single entry point that
builds the atlas and runs a named query in one call:

```julia
# Direct effects of a concept
causal_query(client, :effects, "virus";
             group_id="project-1", limit=20, exact=true)

# Multi-hop chains (depth = number of edges in the path)
causal_query(client, :paths;
             group_id="project-1", depth=2, min_score=0.5, limit=50)

# Backbone of the causal graph
causal_query(client, :backbone; group_id="project-1", limit=10)

# Most connected concepts
causal_query(client, :hubs; group_id="project-1", limit=10)

# Interventional cut — effects downstream of `concept` with the edge removed
causal_query(client, :do_cut, "medicine"; group_id="project-1", limit=20)

# Soft intervention — attenuate a concept's influence
causal_query(client, :soft_do, "medicine";
             group_id="project-1", attenuation=0.3, limit=20)
```

Supported query symbols: `:causes`, `:effects`, `:paths`, `:backbone`,
`:hubs`, `:controversial`, `:loops`, `:do_cut`, `:soft_do`,
`:statistics`.

All `to_csql` build-keyword arguments (`group_id`, `backend`, `path`,
`relation_filter`, `relation_map`, `default_score`) may be passed to
`causal_query`; any other keyword is forwarded to the underlying CSQL
function.

## End-to-end example

```julia
using Graphiti, CSQL

client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())

# Ingest some causal claims (e.g. from a paper or conversation).
add_triplet(client, "virus",    "CAUSES",   "fever";    group_id="med")
add_triplet(client, "fever",    "CAUSES",   "headache"; group_id="med")
add_triplet(client, "medicine", "PREVENTS", "fever";    group_id="med")

# Query the causal structure.
effects  = causal_query(client, :effects,  "virus";    group_id="med", limit=10, exact=true)
causes   = causal_query(client, :causes,   "headache"; group_id="med", limit=10, exact=true)
paths    = causal_query(client, :paths;               group_id="med", depth=2, min_score=0.0, limit=20)
backbone = causal_query(client, :backbone;            group_id="med", limit=5)
```

See the [CSQL.jl documentation](https://juliaknowledge.github.io/CSQL.jl/)
for the full set of available queries and the schema of the returned
`CausalResult` tables.
