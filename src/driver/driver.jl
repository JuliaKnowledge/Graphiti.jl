"""Abstract graph driver interface."""

"""
    AbstractGraphDriver

Supertype for storage backends. Concrete subtypes implement the
ingestion and retrieval methods used by [`GraphitiClient`](@ref):
`save_node!`, `save_edge!`, `get_node`, `get_edge`, `delete_node!`,
`delete_edge!`, `clear!`, `execute_query`, plus the typed `get_*`
helpers. See [`MemoryDriver`](@ref), [`Neo4jDriver`](@ref),
[`FalkorDBDriver`](@ref), [`KuzuDriver`](@ref).
"""
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

const GRAPHITI_DATETIME_FORMATS = (
    dateformat"yyyy-mm-ddTHH:MM:SS.sss",
    dateformat"yyyy-mm-ddTHH:MM:SS",
    dateformat"yyyy-mm-dd HH:MM:SS.sss",
    dateformat"yyyy-mm-dd HH:MM:SS",
    dateformat"yyyy-mm-dd",
)

_serialize_datetime(dt::DateTime) = Dates.format(dt, dateformat"yyyy-mm-ddTHH:MM:SS.sss")
_serialize_datetime(::Nothing) = nothing

function _deserialize_datetime(value)::Union{Nothing, DateTime}
    value === nothing && return nothing
    value isa DateTime && return value
    s = strip(string(value))
    isempty(s) && return nothing
    for fmt in GRAPHITI_DATETIME_FORMATS
        try
            return DateTime(s, fmt)
        catch
        end
    end
    return nothing
end

_serialize_optional_json(::Nothing) = nothing
_serialize_optional_json(value) = JSON3.write(value)

function _deserialize_float_vector(value)::Union{Nothing, Vector{Float64}}
    value === nothing && return nothing
    if value isa AbstractVector
        return Float64[Float64(x) for x in value]
    end
    s = strip(string(value))
    isempty(s) && return nothing
    lowercase(s) == "null" && return nothing
    try
        parsed = JSON3.read(s)
        parsed isa AbstractVector || return nothing
        return Float64[Float64(x) for x in parsed]
    catch
        return nothing
    end
end

function _deserialize_string_vector(value)::Vector{String}
    value === nothing && return String[]
    if value isa AbstractVector
        return String[string(x) for x in value]
    end
    s = strip(string(value))
    isempty(s) && return String[]
    try
        parsed = JSON3.read(s)
        parsed isa AbstractVector || return String[]
        return String[string(x) for x in parsed]
    catch
        return String[]
    end
end

function _deserialize_dict(value)::Dict{String, Any}
    value === nothing && return Dict{String, Any}()
    if value isa AbstractDict
        return Dict(string(k) => v for (k, v) in pairs(value))
    end
    s = strip(string(value))
    isempty(s) && return Dict{String, Any}()
    try
        parsed = JSON3.read(s, Dict{String, Any})
        return parsed isa Dict{String, Any} ? parsed : Dict{String, Any}()
    catch
        return Dict{String, Any}()
    end
end

function _deserialize_episode_type(value)::EpisodeType
    value isa EpisodeType && return value
    s = uppercase(strip(string(value)))
    s == "MESSAGE" && return MESSAGE
    s == "JSON_DATA" && return JSON_DATA
    return TEXT
end

_row_string(row, key::String, default::String = "") = begin
    value = get(row, key, default)
    value === nothing ? default : string(value)
end

function _row_datetime(row, key::String, default::DateTime)
    return something(_deserialize_datetime(get(row, key, nothing)), default)
end

function _entity_node_params(n::EntityNode)::Dict{String, Any}
    return Dict(
        "uuid" => n.uuid,
        "name" => n.name,
        "name_embedding" => _serialize_optional_json(n.name_embedding),
        "summary" => n.summary,
        "group_id" => n.group_id,
        "labels" => JSON3.write(n.labels),
        "attributes" => JSON3.write(n.attributes),
        "created_at" => _serialize_datetime(n.created_at),
    )
end

function _episodic_node_params(n::EpisodicNode)::Dict{String, Any}
    return Dict(
        "uuid" => n.uuid,
        "name" => n.name,
        "content" => n.content,
        "content_embedding" => _serialize_optional_json(n.content_embedding),
        "source" => string(n.source),
        "source_description" => n.source_description,
        "valid_at" => _serialize_datetime(n.valid_at),
        "group_id" => n.group_id,
        "entity_edges" => JSON3.write(n.entity_edges),
        "saga_uuid" => n.saga_uuid,
        "created_at" => _serialize_datetime(n.created_at),
    )
end

function _community_node_params(n::CommunityNode)::Dict{String, Any}
    return Dict(
        "uuid" => n.uuid,
        "name" => n.name,
        "name_embedding" => _serialize_optional_json(n.name_embedding),
        "summary" => n.summary,
        "group_id" => n.group_id,
        "created_at" => _serialize_datetime(n.created_at),
    )
end

function _saga_node_params(n::SagaNode)::Dict{String, Any}
    return Dict(
        "uuid" => n.uuid,
        "name" => n.name,
        "summary" => n.summary,
        "group_id" => n.group_id,
        "last_updated" => _serialize_datetime(n.last_updated),
    )
end

function _entity_edge_params(e::EntityEdge)::Dict{String, Any}
    return Dict(
        "uuid" => e.uuid,
        "src" => e.source_node_uuid,
        "tgt" => e.target_node_uuid,
        "name" => e.name,
        "fact" => e.fact,
        "fact_embedding" => _serialize_optional_json(e.fact_embedding),
        "episodes" => JSON3.write(e.episodes),
        "group_id" => e.group_id,
        "valid_at" => _serialize_datetime(e.valid_at),
        "invalid_at" => _serialize_datetime(e.invalid_at),
        "expired_at" => _serialize_datetime(e.expired_at),
        "reference_time" => _serialize_datetime(e.reference_time),
        "attributes" => JSON3.write(e.attributes),
        "created_at" => _serialize_datetime(e.created_at),
    )
end

function _episodic_edge_params(e::EpisodicEdge)::Dict{String, Any}
    return Dict(
        "uuid" => e.uuid,
        "src" => e.source_node_uuid,
        "tgt" => e.target_node_uuid,
        "group_id" => e.group_id,
        "created_at" => _serialize_datetime(e.created_at),
    )
end

function _community_edge_params(e::CommunityEdge)::Dict{String, Any}
    return Dict(
        "uuid" => e.uuid,
        "src" => e.source_node_uuid,
        "tgt" => e.target_node_uuid,
        "group_id" => e.group_id,
        "created_at" => _serialize_datetime(e.created_at),
    )
end

function _entity_node_from_row(row)::EntityNode
    return EntityNode(
        uuid = _row_string(row, "uuid"),
        name = _row_string(row, "name"),
        name_embedding = _deserialize_float_vector(get(row, "name_embedding", nothing)),
        summary = _row_string(row, "summary"),
        group_id = _row_string(row, "group_id"),
        labels = _deserialize_string_vector(get(row, "labels", nothing)),
        attributes = _deserialize_dict(get(row, "attributes", nothing)),
        created_at = _row_datetime(row, "created_at", now(UTC)),
    )
end

function _episodic_node_from_row(row)::EpisodicNode
    valid_at = something(_deserialize_datetime(get(row, "valid_at", nothing)), now(UTC))
    return EpisodicNode(
        uuid = _row_string(row, "uuid"),
        name = _row_string(row, "name"),
        content = _row_string(row, "content"),
        content_embedding = _deserialize_float_vector(get(row, "content_embedding", nothing)),
        source = _deserialize_episode_type(get(row, "source", TEXT)),
        source_description = _row_string(row, "source_description"),
        valid_at = valid_at,
        group_id = _row_string(row, "group_id"),
        entity_edges = _deserialize_string_vector(get(row, "entity_edges", nothing)),
        saga_uuid = let v = get(row, "saga_uuid", nothing)
            v === nothing ? nothing : string(v)
        end,
        created_at = _row_datetime(row, "created_at", now(UTC)),
    )
end

function _community_node_from_row(row)::CommunityNode
    return CommunityNode(
        uuid = _row_string(row, "uuid"),
        name = _row_string(row, "name"),
        name_embedding = _deserialize_float_vector(get(row, "name_embedding", nothing)),
        summary = _row_string(row, "summary"),
        group_id = _row_string(row, "group_id"),
        created_at = _row_datetime(row, "created_at", now(UTC)),
    )
end

function _saga_node_from_row(row)::SagaNode
    return SagaNode(
        uuid = _row_string(row, "uuid"),
        name = _row_string(row, "name"),
        summary = _row_string(row, "summary"),
        group_id = _row_string(row, "group_id"),
        last_updated = _row_datetime(row, "last_updated", now(UTC)),
    )
end

function _entity_edge_from_row(row)::EntityEdge
    reference_time = something(_deserialize_datetime(get(row, "reference_time", nothing)), now(UTC))
    return EntityEdge(
        uuid = _row_string(row, "uuid"),
        source_node_uuid = _row_string(row, "src"),
        target_node_uuid = _row_string(row, "tgt"),
        name = _row_string(row, "name"),
        fact = _row_string(row, "fact"),
        fact_embedding = _deserialize_float_vector(get(row, "fact_embedding", nothing)),
        episodes = _deserialize_string_vector(get(row, "episodes", nothing)),
        group_id = _row_string(row, "group_id"),
        valid_at = _deserialize_datetime(get(row, "valid_at", nothing)),
        invalid_at = _deserialize_datetime(get(row, "invalid_at", nothing)),
        expired_at = _deserialize_datetime(get(row, "expired_at", nothing)),
        reference_time = reference_time,
        attributes = _deserialize_dict(get(row, "attributes", nothing)),
        created_at = _row_datetime(row, "created_at", now(UTC)),
    )
end

function _episodic_edge_from_row(row)::EpisodicEdge
    return EpisodicEdge(
        uuid = _row_string(row, "uuid"),
        source_node_uuid = _row_string(row, "src"),
        target_node_uuid = _row_string(row, "tgt"),
        group_id = _row_string(row, "group_id"),
        created_at = _row_datetime(row, "created_at", now(UTC)),
    )
end

function _community_edge_from_row(row)::CommunityEdge
    return CommunityEdge(
        uuid = _row_string(row, "uuid"),
        source_node_uuid = _row_string(row, "src"),
        target_node_uuid = _row_string(row, "tgt"),
        group_id = _row_string(row, "group_id"),
        created_at = _row_datetime(row, "created_at", now(UTC)),
    )
end

_first_or_nothing(rows, parser) = isempty(rows) ? nothing : parser(rows[1])
