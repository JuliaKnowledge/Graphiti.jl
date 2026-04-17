"""Node types — entity, episodic, community, saga."""

Base.@kwdef mutable struct EntityNode
    uuid::String = string(uuid4())
    name::String = ""
    name_embedding::Union{Nothing, Vector{Float64}} = nothing
    summary::String = ""
    group_id::String = ""
    labels::Vector{String} = String[]
    attributes::Dict{String, Any} = Dict{String, Any}()
    created_at::DateTime = now(UTC)
end

Base.@kwdef mutable struct EpisodicNode
    uuid::String = string(uuid4())
    name::String = ""
    content::String = ""
    content_embedding::Union{Nothing, Vector{Float64}} = nothing
    source::EpisodeType = TEXT
    source_description::String = ""
    valid_at::DateTime = now(UTC)
    group_id::String = ""
    entity_edges::Vector{String} = String[]
    saga_uuid::Union{Nothing, String} = nothing
    created_at::DateTime = now(UTC)
end

Base.@kwdef mutable struct CommunityNode
    uuid::String = string(uuid4())
    name::String = ""
    name_embedding::Union{Nothing, Vector{Float64}} = nothing
    summary::String = ""
    group_id::String = ""
    created_at::DateTime = now(UTC)
end

Base.@kwdef mutable struct SagaNode
    uuid::String = string(uuid4())
    name::String = ""
    summary::String = ""
    group_id::String = ""
    last_updated::DateTime = now(UTC)
end
