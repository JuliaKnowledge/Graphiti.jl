"""In-memory graph driver backed by dictionaries."""

mutable struct MemoryDriver <: AbstractGraphDriver
    entity_nodes::Dict{String, EntityNode}
    episodic_nodes::Dict{String, EpisodicNode}
    community_nodes::Dict{String, CommunityNode}
    saga_nodes::Dict{String, SagaNode}
    entity_edges::Dict{String, EntityEdge}
    episodic_edges::Dict{String, EpisodicEdge}
    community_edges::Dict{String, CommunityEdge}
end

MemoryDriver() = MemoryDriver(
    Dict{String, EntityNode}(),
    Dict{String, EpisodicNode}(),
    Dict{String, CommunityNode}(),
    Dict{String, SagaNode}(),
    Dict{String, EntityEdge}(),
    Dict{String, EpisodicEdge}(),
    Dict{String, CommunityEdge}(),
)

execute_query(::MemoryDriver, query::String; params::Dict=Dict()) = Dict[]

save_node!(d::MemoryDriver, n::EntityNode)    = (d.entity_nodes[n.uuid] = n; n)
save_node!(d::MemoryDriver, n::EpisodicNode)  = (d.episodic_nodes[n.uuid] = n; n)
save_node!(d::MemoryDriver, n::CommunityNode) = (d.community_nodes[n.uuid] = n; n)
save_node!(d::MemoryDriver, n::SagaNode)      = (d.saga_nodes[n.uuid] = n; n)

save_edge!(d::MemoryDriver, e::EntityEdge)    = (d.entity_edges[e.uuid] = e; e)
save_edge!(d::MemoryDriver, e::EpisodicEdge)  = (d.episodic_edges[e.uuid] = e; e)
save_edge!(d::MemoryDriver, e::CommunityEdge) = (d.community_edges[e.uuid] = e; e)

function get_node(d::MemoryDriver, uuid::String)
    for dict in (d.entity_nodes, d.episodic_nodes, d.community_nodes, d.saga_nodes)
        haskey(dict, uuid) && return dict[uuid]
    end
    return nothing
end

function get_edge(d::MemoryDriver, uuid::String)
    for dict in (d.entity_edges, d.episodic_edges, d.community_edges)
        haskey(dict, uuid) && return dict[uuid]
    end
    return nothing
end

function delete_node!(d::MemoryDriver, uuid::String)
    for dict in (d.entity_nodes, d.episodic_nodes, d.community_nodes, d.saga_nodes)
        delete!(dict, uuid)
    end
end

function delete_edge!(d::MemoryDriver, uuid::String)
    for dict in (d.entity_edges, d.episodic_edges, d.community_edges)
        delete!(dict, uuid)
    end
end

function clear!(d::MemoryDriver)
    empty!(d.entity_nodes); empty!(d.episodic_nodes)
    empty!(d.community_nodes); empty!(d.saga_nodes)
    empty!(d.entity_edges); empty!(d.episodic_edges); empty!(d.community_edges)
    return d
end

function get_entity_nodes(d::MemoryDriver, group_id::String)::Vector{EntityNode}
    if isempty(group_id)
        return collect(values(d.entity_nodes))
    end
    return [n for n in values(d.entity_nodes) if n.group_id == group_id]
end

function get_entity_edges(d::MemoryDriver, group_id::String)::Vector{EntityEdge}
    if isempty(group_id)
        return collect(values(d.entity_edges))
    end
    return [e for e in values(d.entity_edges) if e.group_id == group_id]
end

function get_episodic_nodes(d::MemoryDriver, group_id::String)::Vector{EpisodicNode}
    if isempty(group_id)
        return collect(values(d.episodic_nodes))
    end
    return [n for n in values(d.episodic_nodes) if n.group_id == group_id]
end

function get_latest_episodic_node(d::MemoryDriver, group_id::String)::Union{Nothing, EpisodicNode}
    nodes = get_episodic_nodes(d, group_id)
    isempty(nodes) && return nothing
    return reduce((a, b) -> a.valid_at >= b.valid_at ? a : b, nodes)
end

function get_community_nodes(d::MemoryDriver, group_id::String)::Vector{CommunityNode}
    if isempty(group_id)
        return collect(values(d.community_nodes))
    end
    return [n for n in values(d.community_nodes) if n.group_id == group_id]
end

function get_community_edges(d::MemoryDriver, group_id::String)::Vector{CommunityEdge}
    if isempty(group_id)
        return collect(values(d.community_edges))
    end
    return [e for e in values(d.community_edges) if e.group_id == group_id]
end

function get_saga_nodes(d::MemoryDriver, group_id::String)::Vector{SagaNode}
    if isempty(group_id)
        return collect(values(d.saga_nodes))
    end
    return [n for n in values(d.saga_nodes) if n.group_id == group_id]
end

function get_entity_nodes_with_embeddings(d::MemoryDriver, group_id::String)::Vector{EntityNode}
    return [n for n in get_entity_nodes(d, group_id) if n.name_embedding !== nothing]
end

function get_entity_edges_with_embeddings(d::MemoryDriver, group_id::String)::Vector{EntityEdge}
    return [e for e in get_entity_edges(d, group_id) if e.fact_embedding !== nothing]
end
