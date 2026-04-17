module GraphitiSemanticSpacetimeExt

using Graphiti
using SemanticSpacetime
using Dates

using Graphiti: GraphitiClient, EntityNode, EpisodicNode, CommunityNode,
                EntityEdge, EpisodicEdge, CommunityEdge,
                get_entity_nodes, get_entity_edges,
                get_episodic_nodes,
                get_community_nodes, get_community_edges

import Graphiti: to_sst, sst_query

# ── Default arrow vocabulary ─────────────────────────────────────────────────
# Maps a Graphiti relation name (case-insensitive) to one of the four SST
# type classes. Anything unmatched defaults to NEAR.

const _LEADSTO_ARROWS = Set([
    "CAUSES", "LEADS_TO", "LEADSTO", "TRIGGERS", "BEFORE", "AFTER",
    "PRECEDES", "FOLLOWS", "PREVENTS", "INHIBITS", "ENABLES",
    "INFLUENCES", "INCREASES", "DECREASES", "REDUCES", "PRODUCES",
    "RESULTS_IN", "DEPENDS_ON", "REQUIRES", "ACTIVATES", "BLOCKS",
])

const _CONTAINS_ARROWS = Set([
    "PART_OF", "CONTAINS", "INCLUDES", "MEMBER_OF", "BELONGS_TO",
    "HAS_MEMBER", "IN", "INSIDE", "WITHIN", "COMPOSED_OF", "HAS_PART",
    "PARENT_OF", "CHILD_OF", "OWNS", "OWNED_BY",
])

const _EXPRESS_ARROWS = Set([
    "HAS_ATTRIBUTE", "EXPRESSES", "HAS_PROPERTY", "IS", "IS_A",
    "TYPE_OF", "INSTANCE_OF", "HAS", "NAMED", "DESCRIBED_AS",
    "LABELED", "DEFINED_AS", "ROLE", "TITLE", "STATE",
])

const _NEAR_ARROWS = Set([
    "NEAR", "SIMILAR_TO", "RELATED_TO", "ASSOCIATED_WITH",
    "COOCCURS_WITH", "ALONGSIDE", "WITH", "INTERACTS_WITH",
    "CONNECTED_TO", "LINKED_TO",
])

_normalize(name::AbstractString) = uppercase(strip(replace(String(name), r"\s+" => "_")))

"""
    default_st_classifier(name) -> Symbol

Return one of `:LEADSTO`, `:CONTAINS`, `:EXPRESS`, `:NEAR` for a relation
name. Falls back to `:NEAR`.
"""
function default_st_classifier(name::AbstractString)
    n = _normalize(name)
    n in _LEADSTO_ARROWS  && return :LEADSTO
    n in _CONTAINS_ARROWS && return :CONTAINS
    n in _EXPRESS_ARROWS  && return :EXPRESS
    n in _NEAR_ARROWS     && return :NEAR
    return :NEAR
end

# Inverse names for arrow registration. Crude but consistent: prefix with
# "INV_" if we don't know a better inverse.
function _inverse_name(name::AbstractString)
    n = _normalize(name)
    n == "CAUSES"        && return "IS_CAUSED_BY"
    n == "LEADS_TO"      && return "FOLLOWS_FROM"
    n == "PREVENTS"      && return "PREVENTED_BY"
    n == "INHIBITS"      && return "INHIBITED_BY"
    n == "PART_OF"       && return "HAS_PART"
    n == "CONTAINS"      && return "PART_OF"
    n == "MEMBER_OF"     && return "HAS_MEMBER"
    n == "HAS_MEMBER"    && return "MEMBER_OF"
    n == "HAS_ATTRIBUTE" && return "ATTRIBUTE_OF"
    n == "IS_A"          && return "INSTANCE_OF"
    n == "INSTANCE_OF"   && return "TYPE_OF"
    n == "SIMILAR_TO"    && return "SIMILAR_TO"
    n == "NEAR"          && return "NEAR"
    return string("INV_", n)
end

# Per-store registry of arrows we've already inserted, keyed by canonical
# (uppercase) name. SST's insert_arrow! is global, but it's safe to call
# repeatedly; we still cache to avoid spam.
const _ARROW_CACHE = Set{String}()

function _ensure_arrow!(name::AbstractString, st_class::Symbol)
    canon = _normalize(name)
    isempty(canon) && return canon
    if !(canon in _ARROW_CACHE)
        SemanticSpacetime.insert_arrow!(string(st_class), lowercase(canon),
                                        canon, _inverse_name(canon))
        push!(_ARROW_CACHE, canon)
    end
    canon
end

# ── Node-name → Node cache for one materialisation pass ──────────────────────

mutable struct _Materialiser
    store::SemanticSpacetime.MemoryStore
    chap::String
    name_to_node::Dict{String, SemanticSpacetime.Node}
    classifier::Function
end

function _get_or_make_node!(m::_Materialiser, name::AbstractString)
    key = String(name)
    haskey(m.name_to_node, key) && return m.name_to_node[key]
    node = SemanticSpacetime.mem_vertex!(m.store, key, m.chap)
    m.name_to_node[key] = node
    return node
end

# ── to_sst ───────────────────────────────────────────────────────────────────

function Graphiti.to_sst(client::GraphitiClient;
                         group_id::AbstractString = "",
                         store = nothing,
                         st_classifier = default_st_classifier,
                         include_episodic::Bool = true,
                         include_community::Bool = true)

    gid = String(group_id)
    sst_store = store === nothing ? SemanticSpacetime.MemoryStore() : store
    chapter = isempty(gid) ? "graphiti" : gid

    m = _Materialiser(sst_store, chapter, Dict{String, SemanticSpacetime.Node}(),
                      st_classifier)

    # ── Entities & entity edges ───────────────────────────────────────────
    entities = get_entity_nodes(client.driver, gid)
    uuid_to_name = Dict{String,String}()
    for e in entities
        uuid_to_name[e.uuid] = e.name
        _get_or_make_node!(m, e.name)
    end

    for edge in get_entity_edges(client.driver, gid)
        src_name = get(uuid_to_name, edge.source_node_uuid, "")
        tgt_name = get(uuid_to_name, edge.target_node_uuid, "")
        (isempty(src_name) || isempty(tgt_name)) && continue
        isempty(edge.name) && continue

        st_class = st_classifier(edge.name)
        arrow = _ensure_arrow!(edge.name, st_class)
        from = _get_or_make_node!(m, src_name)
        to   = _get_or_make_node!(m, tgt_name)

        ctx = isempty(edge.episodes) ? String[] : String[String(first(edge.episodes))]
        SemanticSpacetime.mem_edge!(sst_store, from, arrow, to, ctx)
    end

    # ── Episodic edges: episode CONTAINS entity ───────────────────────────
    if include_episodic
        episodes = get_episodic_nodes(client.driver, gid)
        ep_uuid_to_name = Dict{String,String}()
        for ep in episodes
            ep_uuid_to_name[ep.uuid] = ep.name
            _get_or_make_node!(m, ep.name)
        end
        ep_edges = if hasproperty(client.driver, :episodic_edges)
            collect(values(getfield(client.driver, :episodic_edges)))
        else
            EpisodicEdge[]
        end
        if !isempty(ep_edges)
            arrow = _ensure_arrow!("MENTIONS", :CONTAINS)
            for e in ep_edges
                e.group_id == gid || continue
                src = get(ep_uuid_to_name, e.source_node_uuid, "")
                tgt = get(uuid_to_name,    e.target_node_uuid, "")
                (isempty(src) || isempty(tgt)) && continue
                from = _get_or_make_node!(m, src)
                to   = _get_or_make_node!(m, tgt)
                SemanticSpacetime.mem_edge!(sst_store, from, arrow, to)
            end
        end
    end

    # ── Community edges: community CONTAINS entity ────────────────────────
    if include_community
        communities = get_community_nodes(client.driver, gid)
        co_uuid_to_name = Dict{String,String}()
        for c in communities
            co_uuid_to_name[c.uuid] = c.name
            _get_or_make_node!(m, c.name)
        end
        co_edges = get_community_edges(client.driver, gid)
        if !isempty(co_edges)
            arrow = _ensure_arrow!("HAS_MEMBER", :CONTAINS)
            for e in co_edges
                src = get(co_uuid_to_name, e.source_node_uuid, "")
                tgt = get(uuid_to_name,    e.target_node_uuid, "")
                (isempty(src) || isempty(tgt)) && continue
                from = _get_or_make_node!(m, src)
                to   = _get_or_make_node!(m, tgt)
                SemanticSpacetime.mem_edge!(sst_store, from, arrow, to)
            end
        end
    end

    return sst_store
end

# ── sst_query ────────────────────────────────────────────────────────────────

const _BUILD_KEYS = (:group_id, :store, :st_classifier,
                     :include_episodic, :include_community)

# Resolve a name to its (first) NodePtr in the store. Returns `nothing` if
# absent.
function _resolve_nptr(store::SemanticSpacetime.MemoryStore, name::AbstractString)
    nodes = SemanticSpacetime.mem_get_nodes_by_name(store, String(name))
    isempty(nodes) ? nothing : nodes[1].nptr
end

function Graphiti.sst_query(client::GraphitiClient, q::Symbol, args...;
                            kwargs...)
    build_kw = Dict{Symbol,Any}()
    query_kw = Dict{Symbol,Any}()
    for (k, v) in kwargs
        (k in _BUILD_KEYS ? build_kw : query_kw)[k] = v
    end

    store = Graphiti.to_sst(client; build_kw...)

    if q === :forward_cone
        length(args) == 1 || throw(ArgumentError("sst_query :forward_cone takes one node name"))
        nptr = _resolve_nptr(store, args[1])
        nptr === nothing && return nothing
        return SemanticSpacetime.forward_cone(store, nptr; query_kw...)
    elseif q === :backward_cone
        length(args) == 1 || throw(ArgumentError("sst_query :backward_cone takes one node name"))
        nptr = _resolve_nptr(store, args[1])
        nptr === nothing && return nothing
        return SemanticSpacetime.backward_cone(store, nptr; query_kw...)
    elseif q === :paths
        length(args) == 2 || throw(ArgumentError("sst_query :paths takes (from, to)"))
        from = _resolve_nptr(store, args[1])
        to   = _resolve_nptr(store, args[2])
        (from === nothing || to === nothing) && return nothing
        return SemanticSpacetime.find_paths(store, from, to; query_kw...)
    elseif q === :dijkstra
        length(args) == 2 || throw(ArgumentError("sst_query :dijkstra takes (from, to)"))
        from = _resolve_nptr(store, args[1])
        to   = _resolve_nptr(store, args[2])
        (from === nothing || to === nothing) && return nothing
        return SemanticSpacetime.dijkstra_path(store, from, to)
    elseif q === :summary
        return (nodes = SemanticSpacetime.node_count(store),
                links = SemanticSpacetime.link_count(store))
    else
        throw(ArgumentError("Unknown sst_query symbol :$q. " *
                            "Valid: :forward_cone, :backward_cone, :paths, :dijkstra, :summary"))
    end
end

end # module
