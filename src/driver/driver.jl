"""Abstract graph driver interface."""

abstract type AbstractGraphDriver end

execute_query(d::AbstractGraphDriver, query::String; params::Dict=Dict()) =
    error("execute_query not implemented for $(typeof(d))")

save_node!(d::AbstractGraphDriver, node) =
    error("save_node! not implemented for $(typeof(d))")

save_edge!(d::AbstractGraphDriver, edge) =
    error("save_edge! not implemented for $(typeof(d))")

get_node(d::AbstractGraphDriver, uuid::String) =
    error("get_node not implemented for $(typeof(d))")

get_edge(d::AbstractGraphDriver, uuid::String) =
    error("get_edge not implemented for $(typeof(d))")

delete_node!(d::AbstractGraphDriver, uuid::String) =
    error("delete_node! not implemented for $(typeof(d))")

delete_edge!(d::AbstractGraphDriver, uuid::String) =
    error("delete_edge! not implemented for $(typeof(d))")

clear!(d::AbstractGraphDriver) =
    error("clear! not implemented for $(typeof(d))")

get_entity_nodes(d::AbstractGraphDriver, group_id::String)::Vector{EntityNode} =
    error("get_entity_nodes not implemented for $(typeof(d))")

get_entity_edges(d::AbstractGraphDriver, group_id::String)::Vector{EntityEdge} =
    error("get_entity_edges not implemented for $(typeof(d))")

get_episodic_nodes(d::AbstractGraphDriver, group_id::String)::Vector{EpisodicNode} =
    error("get_episodic_nodes not implemented for $(typeof(d))")

get_latest_episodic_node(d::AbstractGraphDriver, group_id::String)::Union{Nothing, EpisodicNode} =
    error("get_latest_episodic_node not implemented for $(typeof(d))")

get_community_nodes(d::AbstractGraphDriver, group_id::String)::Vector{CommunityNode} =
    error("get_community_nodes not implemented for $(typeof(d))")

get_community_edges(d::AbstractGraphDriver, group_id::String)::Vector{CommunityEdge} =
    error("get_community_edges not implemented for $(typeof(d))")

get_saga_nodes(d::AbstractGraphDriver, group_id::String)::Vector{SagaNode} =
    error("get_saga_nodes not implemented for $(typeof(d))")

get_episodes_for_saga(d::AbstractGraphDriver, saga_uuid::String)::Vector{EpisodicNode} =
    error("get_episodes_for_saga not implemented for $(typeof(d))")
