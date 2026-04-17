"""Label-propagation community detection for the entity subgraph."""

# ── Internal helpers ──────────────────────────────────────────────────────────

"""Return neighbour UUIDs of `entity_uuid` that are present in `node_set`."""
function _entity_neighbors(
    entity_uuid::String,
    edges::Vector{EntityEdge},
    node_set::Set{String},
)::Vector{String}
    nbrs = String[]
    for e in edges
        if e.source_node_uuid == entity_uuid && e.target_node_uuid in node_set
            push!(nbrs, e.target_node_uuid)
        elseif e.target_node_uuid == entity_uuid && e.source_node_uuid in node_set
            push!(nbrs, e.source_node_uuid)
        end
    end
    return nbrs
end

"""
Async label propagation over `nodes` connected by `edges`.

Each node starts with its own UUID as its community label.  On each pass we
iterate nodes in shuffled order (for randomness), immediately applying updates
so later nodes in the same pass see the freshest labels — this avoids the
oscillation that pure sync update can exhibit on small graphs.
"""
function _run_label_propagation(
    nodes::Vector{EntityNode},
    edges::Vector{EntityEdge};
    max_iterations::Int = 10,
    rng::AbstractRNG = Random.MersenneTwister(42),
)::Dict{String, String}
    labels = Dict{String, String}(n.uuid => n.uuid for n in nodes)
    node_set = Set{String}(n.uuid for n in nodes)

    for _ in 1:max_iterations
        changed = false
        order = shuffle!(rng, collect(keys(labels)))

        for uuid in order
            nbr_labels = [labels[nbr]
                for nbr in _entity_neighbors(uuid, edges, node_set)]
            isempty(nbr_labels) && continue

            # Most-frequent label; stable sort + RNG for tie-breaking
            counts = Dict{String, Int}()
            for l in nbr_labels
                counts[l] = get(counts, l, 0) + 1
            end
            max_c = maximum(values(counts))
            candidates = sort!(String[k for (k, v) in counts if v == max_c])
            new_lbl = length(candidates) == 1 ?
                candidates[1] : candidates[rand(rng, 1:length(candidates))]

            if new_lbl != labels[uuid]
                labels[uuid] = new_lbl
                changed = true
            end
        end

        !changed && break
    end

    return labels
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    build_communities!(client; group_ids, clear_existing, max_iterations)

Run label-propagation community detection over entity nodes, create
`CommunityNode` + `CommunityEdge` (HAS\\_MEMBER) records, call
`summarize_community!` for each cluster, and return the new nodes.

* `group_ids` — list of group IDs to process; empty means all groups.
* `clear_existing` — if `true` (default) existing community nodes and edges
  for the targeted groups are deleted first.
* `max_iterations` — label-propagation iteration cap (default 10).
"""
function build_communities!(
    client::GraphitiClient;
    group_ids::Vector{String} = String[],
    clear_existing::Bool = true,
    max_iterations::Int = 10,
)::Vector{CommunityNode}
    target_groups = isempty(group_ids) ? String[""] : group_ids
    all_communities = CommunityNode[]

    for gid in target_groups
        # Optionally remove stale communities
        if clear_existing
            old_cnodes = get_community_nodes(client.driver, gid)
            for cn in old_cnodes
                delete_node!(client.driver, cn.uuid)
            end
            old_cedges = get_community_edges(client.driver, gid)
            for ce in old_cedges
                delete_edge!(client.driver, ce.uuid)
            end
        end

        nodes = get_entity_nodes(client.driver, gid)
        isempty(nodes) && continue
        edges = get_entity_edges(client.driver, gid)

        rng = Random.MersenneTwister(42)
        labels = _run_label_propagation(nodes, edges;
            max_iterations = max_iterations, rng = rng)

        # Group nodes by converged label
        clusters = Dict{String, Vector{EntityNode}}()
        for n in nodes
            lbl = get(labels, n.uuid, n.uuid)
            push!(get!(clusters, lbl, EntityNode[]), n)
        end

        for (_, members) in clusters
            cn = CommunityNode(group_id = gid)
            save_node!(client.driver, cn)

            for m in members
                ce = CommunityEdge(
                    source_node_uuid = cn.uuid,
                    target_node_uuid = m.uuid,
                    group_id = gid,
                )
                save_edge!(client.driver, ce)
            end

            summarize_community!(client, cn, members)
            push!(all_communities, cn)
        end
    end

    return all_communities
end

"""
    update_community!(client, entity; group_id)

Assign `entity` to the most-popular community among its current neighbors.
If no neighbors belong to any community, returns `nothing` (entity left
unassigned).  Creates a `CommunityEdge` on success.
"""
function update_community!(
    client::GraphitiClient,
    entity::EntityNode;
    group_id::String = entity.group_id,
)::Union{Nothing, CommunityNode}
    all_edges = get_entity_edges(client.driver, group_id)
    node_set = Set{String}(n.uuid for n in get_entity_nodes(client.driver, group_id))
    neighbor_uuids = Set{String}(_entity_neighbors(entity.uuid, all_edges, node_set))
    isempty(neighbor_uuids) && return nothing

    # Tally which community each neighbor belongs to
    ced_all = get_community_edges(client.driver, group_id)
    community_counts = Dict{String, Int}()
    for ce in ced_all
        ce.target_node_uuid in neighbor_uuids || continue
        community_counts[ce.source_node_uuid] =
            get(community_counts, ce.source_node_uuid, 0) + 1
    end
    isempty(community_counts) && return nothing

    best_cuuid = argmax(community_counts)
    cn = get_node(client.driver, best_cuuid)
    (cn === nothing || !(cn isa CommunityNode)) && return nothing

    # Add membership edge
    save_edge!(client.driver, CommunityEdge(
        source_node_uuid = cn.uuid,
        target_node_uuid = entity.uuid,
        group_id = group_id,
    ))
    return cn
end
