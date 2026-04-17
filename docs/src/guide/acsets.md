# ACSets — Categorical Knowledge Graph

Graphiti.jl ships with an optional [`ACSets.jl`](https://github.com/AlgebraicJulia/ACSets.jl)
extension that materialises the live `GraphitiClient` knowledge graph
as a typed, schema-validated **attributed C-set** (a categorical
combinatorial structure from the AlgebraicJulia ecosystem).

The extension activates automatically when both packages are loaded:

```julia
using Graphiti
using ACSets   # ← activates `GraphitiACSetsExt`
```

> **Note** — `ACSets` cannot share a Julia environment with the
> `RDFLib` extension because of a transitive `DataStructures` version
> conflict. Use a dedicated environment when working with this
> extension.

## Schema

The extension defines `GraphitiSchema` over six tables:

| Table       | Role                | Key attributes                                           |
|-------------|---------------------|----------------------------------------------------------|
| `Entity`    | Node                | `e_uuid`, `e_name`, `e_summary`, `e_group`, `e_created`  |
| `Episode`   | Node                | `ep_uuid`, `ep_name`, `ep_content`, `ep_validat`         |
| `Community` | Node                | `c_uuid`, `c_name`, `c_summary`                          |
| `Fact`      | Edge: Entity→Entity | bi-temporal `f_validat`, `f_invalid`, `f_expired`        |
| `Mentions`  | Edge: Episode→Entity| —                                                        |
| `HasMember` | Edge: Community→Entity | —                                                     |

All edges are foreign-key homomorphisms (e.g. `fact_src : Fact → Entity`),
so ACSets enforces referential integrity at construction time.

## Materialisation

```julia
using Graphiti, ACSets

client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())
# … populate via add_episode, save_node!, save_edge! …

a = to_acset(client; group_id="g1")    # → GraphitiKG{String}
nparts(a, :Entity)                     # number of entity rows
subpart(a, 1, :e_name)                 # first entity's name
incident(a, 3, :hm_community)          # rows of HasMember pointing to community 3
tables(a)                              # NamedTuple of all six tables
```

You can use any of `ACSets`' APIs (`@acset_type` queries, `copy_parts!`,
`acset_schema`, `tojsonschema`, …) on the returned ACSet.

## Canned queries

```julia
acset_query(client, :facts_between;
            group_id="g1", source="Alice", target="Bob")

acset_query(client, :entities_in_community;
            group_id="g1", community="Eng team")

acset_query(client, :facts_valid_at;
            group_id="g1", at=DateTime(2024, 6, 1))
```

| Query                        | Required kwargs       | Returns               |
|------------------------------|-----------------------|-----------------------|
| `:facts_between`             | `source`, `target`    | `Vector{NamedTuple}`  |
| `:entities_in_community`     | `community`           | `Vector{String}`      |
| `:facts_valid_at`            | `at::DateTime`        | `Vector{NamedTuple}`  |

`:facts_valid_at` filters facts whose `[valid_at, invalid_at)` interval
contains `at`. Open intervals (missing endpoints) are treated as
unbounded.

## When to reach for this

- You want **schema-validated** in-memory snapshots that other
  AlgebraicJulia tooling (`Catlab.jl`, `AlgebraicRewriting.jl`) can
  consume.
- You need to **migrate / rewrite** the KG along a categorical morphism.
- You want **canonical isomorphism checks** (`call_nauty`) on KG
  fragments — useful for deduplication or graph-diff tooling.
- You want to round-trip the KG through ACSets' JSON / Excel
  serialisers for offline analysis.
