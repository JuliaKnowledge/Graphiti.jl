module GraphitiRDFLibExt

using Graphiti
using RDFLib
using Dates

using Graphiti: GraphitiClient, EntityNode, EpisodicNode, CommunityNode,
                EntityEdge, EpisodicEdge, CommunityEdge,
                get_entity_nodes, get_entity_edges,
                get_episodic_nodes,
                get_community_nodes, get_community_edges
using RDFLib: RDFGraph, URIRef, Literal, Namespace, RDF, RDFS, PROV, XSD,
              TurtleFormat,
              add!, bind!, sparql_query, serialize

import Graphiti: to_rdf_graph, sparql_kg, kg_to_turtle

const GRAPHITI_NS = Namespace("https://graphiti.julia/ns#")

# ── URI builders ─────────────────────────────────────────────────────────────

_iri(kind::AbstractString, uuid::AbstractString) =
    URIRef("https://graphiti.julia/$(kind)/$(uuid)")

_lit(s::AbstractString) = Literal(String(s))
_lit_dt(d::DateTime) = Literal(string(d); datatype=XSD.dateTime)

# ── Term shortcuts (pre-built so we don't recompute per triple) ──────────────

const _T_ENTITY    = URIRef(string(GRAPHITI_NS) * "Entity")
const _T_EPISODE   = URIRef(string(GRAPHITI_NS) * "Episode")
const _T_COMMUNITY = URIRef(string(GRAPHITI_NS) * "Community")
const _T_FACT      = URIRef(string(GRAPHITI_NS) * "Fact")

const _P_SUMMARY    = URIRef(string(GRAPHITI_NS) * "summary")
const _P_GROUP      = URIRef(string(GRAPHITI_NS) * "groupId")
const _P_FACT       = URIRef(string(GRAPHITI_NS) * "fact")
const _P_SOURCE     = URIRef(string(GRAPHITI_NS) * "source")
const _P_TARGET     = URIRef(string(GRAPHITI_NS) * "target")
const _P_VALID_AT   = URIRef(string(GRAPHITI_NS) * "validAt")
const _P_INVALID_AT = URIRef(string(GRAPHITI_NS) * "invalidAt")
const _P_EXPIRED_AT = URIRef(string(GRAPHITI_NS) * "expiredAt")
const _P_REFTIME    = URIRef(string(GRAPHITI_NS) * "referenceTime")
const _P_CONTENT    = URIRef(string(GRAPHITI_NS) * "content")
const _P_MENTIONS   = URIRef(string(GRAPHITI_NS) * "mentions")
const _P_HAS_MEMBER = URIRef(string(GRAPHITI_NS) * "hasMember")
const _P_LABEL_TAG  = URIRef(string(GRAPHITI_NS) * "label")

# ── Core export: build an RDF graph from a GraphitiClient ────────────────────

"""
    to_rdf_graph(client::GraphitiClient; group_id="") -> RDFLib.RDFGraph

Materialise the live Graphiti knowledge graph as an
[`RDFLib.RDFGraph`](https://github.com/JuliaKnowledge/RDFLib.jl).

The mapping is:

| Graphiti               | RDF                                                            |
|------------------------|----------------------------------------------------------------|
| `EntityNode`           | `<entity/UUID> a graphiti:Entity ; rdfs:label NAME ; …`        |
| `EpisodicNode`         | `<episode/UUID> a graphiti:Episode ; prov:generatedAtTime …`   |
| `CommunityNode`        | `<community/UUID> a graphiti:Community ; rdfs:label NAME ; …`  |
| `EntityEdge`           | `<edge/UUID> a graphiti:Fact ; graphiti:source ; graphiti:target ; graphiti:validAt …` |
| `EpisodicEdge`         | `<episode/EU> graphiti:mentions <entity/V>`                    |
| `CommunityEdge`        | `<community/CU> graphiti:hasMember <entity/EU>`                |

Bi-temporal facts are serialised with PROV-O timestamps and an explicit
`graphiti:validAt` / `graphiti:invalidAt` pair so SPARQL queries can
filter by point-in-time.

Pass `group_id` to scope the export; the empty string returns nodes
across all groups.
"""
function Graphiti.to_rdf_graph(client::GraphitiClient; group_id::AbstractString="")
    g = RDFGraph()
    bind!(g, "graphiti", GRAPHITI_NS)
    bind!(g, "prov", PROV)
    bind!(g, "rdfs", RDFS)
    bind!(g, "xsd", XSD)

    drv = client.driver

    for n in get_entity_nodes(drv, String(group_id))
        s = _iri("entity", n.uuid)
        add!(g, s, RDF.type, _T_ENTITY)
        isempty(n.name)    || add!(g, s, RDFS.label, _lit(n.name))
        isempty(n.summary) || add!(g, s, _P_SUMMARY, _lit(n.summary))
        isempty(n.group_id) || add!(g, s, _P_GROUP, _lit(n.group_id))
        for label in n.labels
            add!(g, s, _P_LABEL_TAG, _lit(label))
        end
        add!(g, s, PROV.generatedAtTime, _lit_dt(n.created_at))
    end

    for ep in get_episodic_nodes(drv, String(group_id))
        s = _iri("episode", ep.uuid)
        add!(g, s, RDF.type, _T_EPISODE)
        isempty(ep.name)    || add!(g, s, RDFS.label, _lit(ep.name))
        isempty(ep.content) || add!(g, s, _P_CONTENT, _lit(ep.content))
        isempty(ep.group_id) || add!(g, s, _P_GROUP, _lit(ep.group_id))
        add!(g, s, PROV.generatedAtTime, _lit_dt(ep.valid_at))
    end

    for c in get_community_nodes(drv, String(group_id))
        s = _iri("community", c.uuid)
        add!(g, s, RDF.type, _T_COMMUNITY)
        isempty(c.name)    || add!(g, s, RDFS.label, _lit(c.name))
        isempty(c.summary) || add!(g, s, _P_SUMMARY, _lit(c.summary))
        isempty(c.group_id) || add!(g, s, _P_GROUP, _lit(c.group_id))
        add!(g, s, PROV.generatedAtTime, _lit_dt(c.created_at))
    end

    for e in get_entity_edges(drv, String(group_id))
        s = _iri("edge", e.uuid)
        add!(g, s, RDF.type, _T_FACT)
        isempty(e.name) || add!(g, s, RDFS.label, _lit(e.name))
        isempty(e.fact) || add!(g, s, _P_FACT, _lit(e.fact))
        isempty(e.source_node_uuid) || add!(g, s, _P_SOURCE, _iri("entity", e.source_node_uuid))
        isempty(e.target_node_uuid) || add!(g, s, _P_TARGET, _iri("entity", e.target_node_uuid))
        isempty(e.group_id) || add!(g, s, _P_GROUP, _lit(e.group_id))
        e.valid_at   === nothing || add!(g, s, _P_VALID_AT,   _lit_dt(e.valid_at))
        e.invalid_at === nothing || add!(g, s, _P_INVALID_AT, _lit_dt(e.invalid_at))
        e.expired_at === nothing || add!(g, s, _P_EXPIRED_AT, _lit_dt(e.expired_at))
        add!(g, s, _P_REFTIME, _lit_dt(e.reference_time))
        add!(g, s, PROV.generatedAtTime, _lit_dt(e.created_at))
    end

    # Episodic edges live on the driver as (episode_uuid → entity_uuid) mentions.
    if hasproperty(drv, :episodic_edges)
        for e in values(getfield(drv, :episodic_edges))
            (group_id == "" || e.group_id == group_id) || continue
            isempty(e.source_node_uuid) || isempty(e.target_node_uuid) && continue
            add!(g, _iri("episode", e.source_node_uuid),
                    _P_MENTIONS,
                    _iri("entity",  e.target_node_uuid))
        end
    end

    for ce in get_community_edges(drv, String(group_id))
        isempty(ce.source_node_uuid) || isempty(ce.target_node_uuid) && continue
        add!(g, _iri("community", ce.source_node_uuid),
                _P_HAS_MEMBER,
                _iri("entity",    ce.target_node_uuid))
    end

    return g
end

"""
    sparql_kg(client::GraphitiClient, query::AbstractString; group_id="")

Materialise the knowledge graph (`to_rdf_graph`) and run a SPARQL
query against it. Returns whatever `RDFLib.sparql_query` returns
for the given query type (SELECT bindings, ASK boolean, …).
"""
function Graphiti.sparql_kg(client::GraphitiClient, query::AbstractString;
                            group_id::AbstractString="")
    g = to_rdf_graph(client; group_id=group_id)
    return sparql_query(g, String(query))
end

"""
    kg_to_turtle(client::GraphitiClient; group_id="") -> String

Convenience: materialise the KG and return the Turtle serialisation as a
`String`.
"""
function Graphiti.kg_to_turtle(client::GraphitiClient; group_id::AbstractString="")
    g = to_rdf_graph(client; group_id=group_id)
    return serialize(g, TurtleFormat())
end

end # module
