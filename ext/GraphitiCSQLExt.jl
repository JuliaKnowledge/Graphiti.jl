module GraphitiCSQLExt

using Graphiti
using CSQL
using Dates

using Graphiti: GraphitiClient, EntityNode, EntityEdge,
                get_entity_nodes, get_entity_edges

import Graphiti: to_csql, causal_query

# ── Helpers ──────────────────────────────────────────────────────────────────

function _build_name_index(client::GraphitiClient, group_id::AbstractString)
    nodes = get_entity_nodes(client.driver, String(group_id))
    idx = Dict{String,String}()
    for n in nodes
        idx[n.uuid] = n.name
    end
    idx
end

_normalize_relation(s::AbstractString) = uppercase(strip(replace(String(s), r"\s+" => "_")))

# Extract a CSQL-style score in [0,1] from edge metadata. Priority:
#   1. attributes["score"] or ["confidence"] if numeric
#   2. default_score
function _edge_score(edge::EntityEdge, default_score::Real)
    for k in ("score", "confidence")
        if haskey(edge.attributes, k)
            v = edge.attributes[k]
            if v isa Real
                return clamp(Float64(v), 0.0, 1.0)
            end
        end
    end
    return Float64(default_score)
end

_edge_doc_id(edge::EntityEdge) =
    isempty(edge.episodes) ? edge.uuid : String(first(edge.episodes))

# ── to_csql ──────────────────────────────────────────────────────────────────

function Graphiti.to_csql(client::GraphitiClient;
                          group_id::AbstractString = "",
                          backend::Symbol = :sqlite,
                          path::AbstractString = "",
                          relation_map = identity,
                          relation_filter = _ -> true,
                          default_score::Real = 0.5)

    gid = String(group_id)
    name_of = _build_name_index(client, gid)
    edges = get_entity_edges(client.driver, gid)

    csql = CSQL.connect_csql(backend = backend, path = String(path))
    builder = CSQL.AtlasBuilder()

    for e in edges
        relation_filter(e.name) || continue
        src = get(name_of, e.source_node_uuid, "")
        tgt = get(name_of, e.target_node_uuid, "")
        (isempty(src) || isempty(tgt)) && continue

        rel = _normalize_relation(relation_map(e.name))
        isempty(rel) && continue

        score = _edge_score(e, default_score)
        doc_id = _edge_doc_id(e)

        CSQL.add_triple!(builder, src, rel, tgt;
                         doc_id = doc_id,
                         score = score,
                         confidence = score)
    end

    # CSQL's build! writes into the raw inner DB (not the wrapper).
    CSQL.build!(builder, csql.db)
    return csql
end

# ── causal_query ─────────────────────────────────────────────────────────────

const _QUERY_DISPATCH = Dict{Symbol,Function}(
    :causes        => (csql, args, kw) -> CSQL.causes_of(csql, args[1]; kw...),
    :effects       => (csql, args, kw) -> CSQL.effects_of(csql, args[1]; kw...),
    :paths         => (csql, args, kw) -> CSQL.causal_paths(csql; kw...),
    :backbone      => (csql, args, kw) -> CSQL.backbone(csql; kw...),
    :hubs          => (csql, args, kw) -> CSQL.causal_hubs(csql; kw...),
    :controversial => (csql, args, kw) -> CSQL.controversial_claims(csql; kw...),
    :loops         => (csql, args, kw) -> CSQL.feedback_loops(csql),
    :do_cut        => (csql, args, kw) -> CSQL.do_cut(csql, args[1]; kw...),
    :soft_do       => (csql, args, kw) -> CSQL.soft_do(csql, args[1]; kw...),
    :statistics    => (csql, args, kw) -> CSQL.statistics(csql),
)

# Keyword names understood by `to_csql`; the rest are passed to the query.
const _BUILD_KEYS = (:group_id, :backend, :path, :relation_map,
                     :relation_filter, :default_score)

function Graphiti.causal_query(client::GraphitiClient, q::Symbol, args...;
                               kwargs...)
    haskey(_QUERY_DISPATCH, q) ||
        throw(ArgumentError("Unknown causal_query symbol :$q. " *
                            "Valid: $(sort!(collect(keys(_QUERY_DISPATCH))))"))

    build_kw = Dict{Symbol,Any}()
    query_kw = Dict{Symbol,Any}()
    for (k, v) in kwargs
        if k in _BUILD_KEYS
            build_kw[k] = v
        else
            query_kw[k] = v
        end
    end

    csql = Graphiti.to_csql(client; build_kw...)
    return _QUERY_DISPATCH[q](csql, args, query_kw)
end

end # module
