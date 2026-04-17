"""Edge types — entity, episodic, community."""

Base.@kwdef mutable struct EntityEdge
    uuid::String = string(uuid4())
    source_node_uuid::String = ""
    target_node_uuid::String = ""
    name::String = ""
    fact::String = ""
    fact_embedding::Union{Nothing, Vector{Float64}} = nothing
    episodes::Vector{String} = String[]
    group_id::String = ""
    valid_at::Union{Nothing, DateTime} = nothing
    invalid_at::Union{Nothing, DateTime} = nothing
    expired_at::Union{Nothing, DateTime} = nothing
    reference_time::DateTime = now(UTC)
    attributes::Dict{String, Any} = Dict{String, Any}()
    created_at::DateTime = now(UTC)
end

Base.@kwdef mutable struct EpisodicEdge
    uuid::String = string(uuid4())
    source_node_uuid::String = ""
    target_node_uuid::String = ""
    group_id::String = ""
    created_at::DateTime = now(UTC)
end

Base.@kwdef mutable struct CommunityEdge
    uuid::String = string(uuid4())
    source_node_uuid::String = ""
    target_node_uuid::String = ""
    group_id::String = ""
    created_at::DateTime = now(UTC)
end
