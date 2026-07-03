"""Breadth-first graph traversal from seed nodes."""

function bfs_search(
    driver::AbstractGraphDriver,
    seed_node_uuids::Vector{String},
    max_depth::Int;
    group_id::String = "",
)::Tuple{Vector{EntityNode}, Vector{EntityEdge}}
    visited_nodes = Set{String}()
    visited_edges = Set{String}()
    result_nodes = EntityNode[]
    result_edges = EntityEdge[]

    all_edges = isempty(group_id) ? _all_entity_edges(driver) : get_entity_edges(driver, group_id)
    adjacency = Dict{String, Vector{Tuple{EntityEdge, String}}}()
    for edge in all_edges
        push!(get!(adjacency, edge.source_node_uuid, Tuple{EntityEdge, String}[]), (edge, edge.target_node_uuid))
        push!(get!(adjacency, edge.target_node_uuid, Tuple{EntityEdge, String}[]), (edge, edge.source_node_uuid))
    end

    all_nodes_map = if driver isa MemoryDriver
        driver.entity_nodes
    else
        Dict(n.uuid => n for n in get_entity_nodes(driver, group_id))
    end

    queue = Tuple{String, Int}[(uuid, 0) for uuid in seed_node_uuids]
    queue_idx = 1

    while queue_idx <= length(queue)
        (uuid, depth) = queue[queue_idx]
        queue_idx += 1
        uuid in visited_nodes && continue
        push!(visited_nodes, uuid)

        if haskey(all_nodes_map, uuid)
            push!(result_nodes, all_nodes_map[uuid])
        end

        depth >= max_depth && continue

        for (edge, neighbor) in get(adjacency, uuid, Tuple{EntityEdge, String}[])
            edge.uuid in visited_edges && continue
            push!(visited_edges, edge.uuid)
            push!(result_edges, edge)
            neighbor in visited_nodes || push!(queue, (neighbor, depth + 1))
        end
    end

    return result_nodes, result_edges
end
