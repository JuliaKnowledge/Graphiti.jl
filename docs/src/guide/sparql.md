# SPARQL & RDF Export

Graphiti.jl ships with an optional [`RDFLib.jl`](https://github.com/JuliaKnowledge/RDFLib.jl)
extension that lets you materialise a live `GraphitiClient` knowledge
graph as an RDF graph, query it with SPARQL, and serialise it to
Turtle / N-Triples / JSON-LD via RDFLib's standard formats.

The extension is enabled automatically when both packages are loaded:

```julia
using Graphiti
using RDFLib   # ← activates `GraphitiRDFLibExt`
```

## Mapping

| Graphiti element | RDF                                                                           |
|------------------|-------------------------------------------------------------------------------|
| `EntityNode`     | `<entity/UUID> a graphiti:Entity ; rdfs:label NAME ; graphiti:summary "…"`    |
| `EpisodicNode`   | `<episode/UUID> a graphiti:Episode ; prov:generatedAtTime "…"^^xsd:dateTime`  |
| `CommunityNode`  | `<community/UUID> a graphiti:Community ; rdfs:label NAME`                     |
| `EntityEdge`     | `<edge/UUID> a graphiti:Fact ; graphiti:source/target ; graphiti:validAt …`   |
| `EpisodicEdge`   | `<episode/E> graphiti:mentions <entity/V>`                                    |
| `CommunityEdge`  | `<community/C> graphiti:hasMember <entity/E>`                                 |

Bi-temporal facts are exported with explicit `graphiti:validAt` /
`graphiti:invalidAt` / `graphiti:expiredAt` properties (all `xsd:dateTime`),
plus `prov:generatedAtTime` for ingestion time. SPARQL `FILTER` clauses
can therefore answer point-in-time questions over the graph.

## API

```julia
to_rdf_graph(client; group_id="")  # → RDFLib.RDFGraph
sparql_kg(client, query;  group_id="")
kg_to_turtle(client;      group_id="")  # → String
```

`group_id=""` exports across every group; pass a specific id to scope
to a single tenant / saga / conversation.

## Example

```julia
using Graphiti, RDFLib

client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())

alice = EntityNode(name="Alice", labels=["Person"], group_id="g1")
bob   = EntityNode(name="Bob",   labels=["Person"], group_id="g1")
save_node!(client.driver, alice); save_node!(client.driver, bob)
save_edge!(client.driver, EntityEdge(
    source_node_uuid=alice.uuid, target_node_uuid=bob.uuid,
    name="REPORTS_TO", fact="Alice reports to Bob",
    valid_at=DateTime(2024,1,1), group_id="g1",
))

# 1. Materialise → query
rows = sparql_kg(client,
    "PREFIX graphiti: <https://graphiti.julia/ns#> " *
    "PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#> " *
    "SELECT ?n WHERE { ?e a graphiti:Entity ; rdfs:label ?n }";
    group_id="g1")

# 2. Materialise → Turtle (e.g. for downstream RDF tooling)
ttl = kg_to_turtle(client; group_id="g1")
write("kg.ttl", ttl)
```

## When to reach for this

- You need to **federate** the Graphiti KG with other RDF / SPARQL
  data (e.g. existing ontologies, public LOD endpoints, SHACL
  validators).
- You want to publish the KG as a **PROV-aware** Turtle dump for
  audit, replay, or regulatory review.
- You want to run **point-in-time** queries (`FILTER (?validAt <= "…"^^xsd:dateTime)`)
  that the native cosine / BM25 search isn't suited for.

For everyday in-process retrieval, prefer `Graphiti.search` — the
RDF path materialises the whole subgraph per call, so it's best for
analytical / ad-hoc work rather than per-turn agent prompts.
