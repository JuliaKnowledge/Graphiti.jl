module GraphitiACSetsExt

using Graphiti
using ACSets
using Dates

using Graphiti: GraphitiClient, EntityNode, EpisodicNode, CommunityNode,
                EntityEdge, EpisodicEdge, CommunityEdge,
                get_entity_nodes, get_entity_edges,
                get_episodic_nodes,
                get_community_nodes, get_community_edges

import Graphiti: to_acset, acset_query

# ── Schema ───────────────────────────────────────────────────────────────────
# Six "object" tables, three of which act as edges via foreign-key homs.
#
#   Entity, Episode, Community           — node tables
#   Fact     : src,target -> Entity      — temporal entity edge
#   Mentions : episode -> Episode,
#              entity  -> Entity         — episodic edge
#   HasMember: community -> Community,
#              entity    -> Entity       — community edge
#
# All tables carry a string `uuid`, `group_id`, plus type-specific attrs.
# Datetimes are stored as `String` so the schema stays portable to JSON.

const GraphitiSchema = BasicSchema(
    [:Entity, :Episode, :Community, :Fact, :Mentions, :HasMember],
    [
        (:fact_src,    :Fact,      :Entity),
        (:fact_tgt,    :Fact,      :Entity),
        (:ment_episode,:Mentions,  :Episode),
        (:ment_entity, :Mentions,  :Entity),
        (:hm_community,:HasMember, :Community),
        (:hm_entity,   :HasMember, :Entity),
    ],
    [:Str],
    [
        (:e_uuid,    :Entity,    :Str),
        (:e_name,    :Entity,    :Str),
        (:e_summary, :Entity,    :Str),
        (:e_group,   :Entity,    :Str),
        (:e_created, :Entity,    :Str),

        (:ep_uuid,   :Episode,   :Str),
        (:ep_name,   :Episode,   :Str),
        (:ep_content,:Episode,   :Str),
        (:ep_group,  :Episode,   :Str),
        (:ep_validat,:Episode,   :Str),

        (:c_uuid,    :Community, :Str),
        (:c_name,    :Community, :Str),
        (:c_summary, :Community, :Str),
        (:c_group,   :Community, :Str),

        (:f_uuid,    :Fact,      :Str),
        (:f_name,    :Fact,      :Str),
        (:f_fact,    :Fact,      :Str),
        (:f_group,   :Fact,      :Str),
        (:f_validat, :Fact,      :Str),
        (:f_invalid, :Fact,      :Str),
        (:f_expired, :Fact,      :Str),
        (:f_reftime, :Fact,      :Str),

        (:m_group,   :Mentions,  :Str),
        (:hm_group,  :HasMember, :Str),
    ],
)

@acset_type GraphitiKG(GraphitiSchema, index=[:fact_src, :fact_tgt,
                                              :ment_episode, :ment_entity,
                                              :hm_community, :hm_entity])

_dt(s) = s === nothing ? "" : string(s)

# ── Materialisation ──────────────────────────────────────────────────────────

"""
    to_acset(client::GraphitiClient; group_id="") -> GraphitiKG

Materialise the knowledge graph held by `client` as a typed ACSet
conforming to `GraphitiSchema`. Use `ACSets`' standard machinery
(`tables`, `nparts`, `subpart`, `incident`, …) for analysis, or the
`acset_query` helper for a few canned queries.
"""
function Graphiti.to_acset(client::GraphitiClient; group_id::AbstractString="")
    g = group_id == "" ? "" : String(group_id)
    drv = client.driver
    a = GraphitiKG{String}()

    # Index uuid → part_id for FK resolution.
    e_idx = Dict{String, Int}()
    ep_idx = Dict{String, Int}()
    c_idx  = Dict{String, Int}()

    for n in get_entity_nodes(drv, g)
        i = add_part!(a, :Entity;
            e_uuid=n.uuid, e_name=n.name, e_summary=n.summary,
            e_group=n.group_id, e_created=_dt(n.created_at))
        e_idx[n.uuid] = i
    end

    for ep in get_episodic_nodes(drv, g)
        i = add_part!(a, :Episode;
            ep_uuid=ep.uuid, ep_name=ep.name, ep_content=ep.content,
            ep_group=ep.group_id, ep_validat=_dt(ep.valid_at))
        ep_idx[ep.uuid] = i
    end

    for c in get_community_nodes(drv, g)
        i = add_part!(a, :Community;
            c_uuid=c.uuid, c_name=c.name, c_summary=c.summary,
            c_group=c.group_id)
        c_idx[c.uuid] = i
    end

    for e in get_entity_edges(drv, g)
        src = get(e_idx, e.source_node_uuid, 0)
        tgt = get(e_idx, e.target_node_uuid, 0)
        (src == 0 || tgt == 0) && continue
        add_part!(a, :Fact;
            fact_src=src, fact_tgt=tgt,
            f_uuid=e.uuid, f_name=e.name, f_fact=e.fact, f_group=e.group_id,
            f_validat=_dt(e.valid_at), f_invalid=_dt(e.invalid_at),
            f_expired=_dt(e.expired_at), f_reftime=_dt(e.reference_time))
    end

    if hasproperty(drv, :episodic_edges)
        for ee in values(getfield(drv, :episodic_edges))
            (g == "" || ee.group_id == g) || continue
            ep_id  = get(ep_idx, ee.source_node_uuid, 0)
            ent_id = get(e_idx,  ee.target_node_uuid, 0)
            (ep_id == 0 || ent_id == 0) && continue
            add_part!(a, :Mentions;
                ment_episode=ep_id, ment_entity=ent_id, m_group=ee.group_id)
        end
    end

    for ce in get_community_edges(drv, g)
        cid = get(c_idx, ce.source_node_uuid, 0)
        eid = get(e_idx, ce.target_node_uuid, 0)
        (cid == 0 || eid == 0) && continue
        add_part!(a, :HasMember;
            hm_community=cid, hm_entity=eid, hm_group=ce.group_id)
    end

    return a
end

# ── Canned queries ───────────────────────────────────────────────────────────

"""
    acset_query(client, query::Symbol; group_id="", kwargs...)

See `Graphiti.acset_query`. Concrete query handlers:

| Query                       | Required kwargs    | Returns                |
|-----------------------------|--------------------|------------------------|
| `:facts_between`            | `source`, `target` | `Vector{NamedTuple}`   |
| `:entities_in_community`    | `community`        | `Vector{String}`       |
| `:facts_valid_at`           | `at::DateTime`     | `Vector{NamedTuple}`   |

`source`, `target`, and `community` match by `e_name`/`c_name` (case-sensitive
exact match). `at` filters facts whose `valid_at <= at < invalid_at` (open
intervals when timestamps are missing).
"""
function Graphiti.acset_query(client::GraphitiClient, query::Symbol;
                              group_id::AbstractString="", kwargs...)
    a = to_acset(client; group_id=group_id)
    kw = Dict(kwargs)

    if query === :facts_between
        src_name = String(get(kw, :source, ""))
        tgt_name = String(get(kw, :target, ""))
        out = NamedTuple[]
        for f in 1:nparts(a, :Fact)
            si = subpart(a, f, :fact_src)
            ti = subpart(a, f, :fact_tgt)
            sn = subpart(a, si, :e_name)
            tn = subpart(a, ti, :e_name)
            (src_name == "" || sn == src_name) || continue
            (tgt_name == "" || tn == tgt_name) || continue
            push!(out, (source=sn, target=tn,
                        name=subpart(a, f, :f_name),
                        fact=subpart(a, f, :f_fact),
                        valid_at=subpart(a, f, :f_validat),
                        invalid_at=subpart(a, f, :f_invalid)))
        end
        return out

    elseif query === :entities_in_community
        cname = String(get(kw, :community, ""))
        out = String[]
        for c in 1:nparts(a, :Community)
            subpart(a, c, :c_name) == cname || continue
            for hm in incident(a, c, :hm_community)
                e = subpart(a, hm, :hm_entity)
                push!(out, subpart(a, e, :e_name))
            end
        end
        return out

    elseif query === :facts_valid_at
        at = get(kw, :at, nothing)
        at === nothing && error("acset_query(:facts_valid_at) requires `at::DateTime` kwarg")
        atstr = String(string(at))
        out = NamedTuple[]
        for f in 1:nparts(a, :Fact)
            v = subpart(a, f, :f_validat)
            i = subpart(a, f, :f_invalid)
            v == "" || (v <= atstr) || continue   # not yet valid
            i == "" || (atstr < i)  || continue   # already invalid
            si = subpart(a, f, :fact_src); ti = subpart(a, f, :fact_tgt)
            push!(out, (source=subpart(a, si, :e_name),
                        target=subpart(a, ti, :e_name),
                        name=subpart(a, f, :f_name),
                        fact=subpart(a, f, :f_fact),
                        valid_at=v, invalid_at=i))
        end
        return out
    else
        error("acset_query: unknown query `$query`. " *
              "Supported: :facts_between, :entities_in_community, :facts_valid_at")
    end
end

end # module
