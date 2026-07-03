"""Neo4j HTTP driver with injectable request function for testing."""

struct GraphitiNeo4jError <: Exception
    message::String
end

Base.showerror(io::IO, e::GraphitiNeo4jError) = print(io, "GraphitiNeo4jError: ", e.message)

function _default_neo4j_http(url::String, headers::Vector, body::String)::Tuple{Int, String}
    resp = HTTP.post(url, headers, body; status_exception=false)
    return resp.status, String(resp.body)
end

function _neo4j_build_body(query::String, params::Dict)::String
    return JSON3.write(Dict(
        "statements" => [Dict(
            "statement" => query,
            "parameters" => params,
        )],
    ))
end

function _neo4j_parse_response(body::String)::Vector{Dict{String, Any}}
    parsed = JSON3.read(body, Dict)
    errors = get(parsed, "errors", Any[])
    if !isempty(errors)
        throw(GraphitiNeo4jError(string(errors)))
    end
    rows = Dict{String, Any}[]
    for result in get(parsed, "results", Any[])
        columns = [string(c) for c in get(result, "columns", Any[])]
        for entry in get(result, "data", Any[])
            row = get(entry, "row", Any[])
            d = Dict{String, Any}()
            for (i, col) in enumerate(columns)
                d[col] = i <= length(row) ? row[i] : nothing
            end
            push!(rows, d)
        end
    end
    return rows
end

_neo4j_where_group(alias::String, group_id::String) =
    isempty(group_id) ? "" : " WHERE $alias.group_id = \$group_id"

_neo4j_entity_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.name_embedding AS name_embedding, " *
    "$alias.summary AS summary, $alias.group_id AS group_id, $alias.labels AS labels, " *
    "$alias.attributes AS attributes, $alias.created_at AS created_at"

_neo4j_episodic_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.content AS content, " *
    "$alias.content_embedding AS content_embedding, $alias.source AS source, " *
    "$alias.source_description AS source_description, $alias.valid_at AS valid_at, " *
    "$alias.group_id AS group_id, $alias.entity_edges AS entity_edges, " *
    "$alias.saga_uuid AS saga_uuid, $alias.created_at AS created_at"

_neo4j_community_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.name_embedding AS name_embedding, " *
    "$alias.summary AS summary, $alias.group_id AS group_id, $alias.created_at AS created_at"

_neo4j_saga_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.summary AS summary, " *
    "$alias.group_id AS group_id, $alias.last_updated AS last_updated"

_neo4j_entity_edge_projection(rel::String = "r", src::String = "a", tgt::String = "b") =
    "$rel.uuid AS uuid, $src.uuid AS src, $tgt.uuid AS tgt, $rel.name AS name, " *
    "$rel.fact AS fact, $rel.fact_embedding AS fact_embedding, $rel.episodes AS episodes, " *
    "$rel.group_id AS group_id, $rel.valid_at AS valid_at, $rel.invalid_at AS invalid_at, " *
    "$rel.expired_at AS expired_at, $rel.reference_time AS reference_time, " *
    "$rel.attributes AS attributes, $rel.created_at AS created_at"

_neo4j_simple_edge_projection(rel::String = "r", src::String = "a", tgt::String = "b") =
    "$rel.uuid AS uuid, $src.uuid AS src, $tgt.uuid AS tgt, $rel.group_id AS group_id, " *
    "$rel.created_at AS created_at"

"""
    Neo4jDriver(; url, user, password, database, _request_fn)

HTTP-transport driver for [Neo4j](https://neo4j.com). Defaults pull from
`NEO4J_URL`, `NEO4J_USER`, `NEO4J_PASSWORD`, and `NEO4J_DATABASE` env
vars. The `_request_fn` hook accepts `(url, headers, body) ->
(status, body)` and lets you stub HTTP calls in tests; the default uses
`HTTP.post`.
"""
mutable struct Neo4jDriver <: AbstractGraphDriver
    url::String
    user::String
    password::String
    database::String
    _request_fn::Function
end

function Neo4jDriver(;
    url::String = get(ENV, "NEO4J_URL", "http://localhost:7474"),
    user::String = get(ENV, "NEO4J_USER", "neo4j"),
    password::String = get(ENV, "NEO4J_PASSWORD", ""),
    database::String = get(ENV, "NEO4J_DATABASE", "neo4j"),
    _request_fn::Function = _default_neo4j_http,
)
    return Neo4jDriver(url, user, password, database, _request_fn)
end

function _neo4j_headers(d::Neo4jDriver)
    headers = ["Content-Type" => "application/json", "Accept" => "application/json"]
    if !isempty(d.user) || !isempty(d.password)
        token = Base64.base64encode(string(d.user, ":", d.password))
        push!(headers, "Authorization" => "Basic " * token)
    end
    return headers
end

function execute_query(d::Neo4jDriver, query::String; params::Dict=Dict())::Vector{Dict}
    body = _neo4j_build_body(query, params)
    endpoint = string(rstrip(d.url, '/'), "/db/", d.database, "/tx/commit")
    status, resp_body = d._request_fn(endpoint, _neo4j_headers(d), body)
    if status < 200 || status >= 300
        throw(GraphitiNeo4jError("HTTP $status: $resp_body"))
    end
    return _neo4j_parse_response(resp_body)
end

function save_node!(d::Neo4jDriver, n::EntityNode)
    params = _entity_node_params(n)
    query = """
    MERGE (n:Entity {uuid: \$uuid})
    SET n.name = \$name,
        n.name_embedding = \$name_embedding,
        n.summary = \$summary,
        n.group_id = \$group_id,
        n.labels = \$labels,
        n.attributes = \$attributes,
        n.created_at = \$created_at
    RETURN n.uuid
    """
    execute_query(d, query; params = params)
    return n
end

function save_node!(d::Neo4jDriver, n::EpisodicNode)
    params = _episodic_node_params(n)
    query = """
    MERGE (n:Episodic {uuid: \$uuid})
    SET n.name = \$name,
        n.content = \$content,
        n.content_embedding = \$content_embedding,
        n.source = \$source,
        n.source_description = \$source_description,
        n.valid_at = \$valid_at,
        n.group_id = \$group_id,
        n.entity_edges = \$entity_edges,
        n.saga_uuid = \$saga_uuid,
        n.created_at = \$created_at
    RETURN n.uuid
    """
    execute_query(d, query; params = params)
    return n
end

function save_node!(d::Neo4jDriver, n::CommunityNode)
    params = _community_node_params(n)
    execute_query(d,
        "MERGE (n:Community {uuid: \$uuid}) " *
        "SET n.name = \$name, n.name_embedding = \$name_embedding, " *
        "n.summary = \$summary, n.group_id = \$group_id, n.created_at = \$created_at " *
        "RETURN n.uuid";
        params = params)
    return n
end

function save_edge!(d::Neo4jDriver, e::EntityEdge)
    params = _entity_edge_params(e)
    query = """
    MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
    MERGE (a)-[r:RELATES_TO {uuid: \$uuid}]->(b)
    SET r.name = \$name,
        r.fact = \$fact,
        r.fact_embedding = \$fact_embedding,
        r.episodes = \$episodes,
        r.group_id = \$group_id,
        r.valid_at = \$valid_at,
        r.invalid_at = \$invalid_at,
        r.expired_at = \$expired_at,
        r.reference_time = \$reference_time,
        r.attributes = \$attributes,
        r.created_at = \$created_at
    RETURN r.uuid
    """
    execute_query(d, query; params = params)
    return e
end

function save_edge!(d::Neo4jDriver, e::EpisodicEdge)
    params = _episodic_edge_params(e)
    query = """
    MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
    MERGE (a)-[r:MENTIONS {uuid: \$uuid}]->(b)
    SET r.group_id = \$group_id, r.created_at = \$created_at
    RETURN r.uuid
    """
    execute_query(d, query; params = params)
    return e
end

function save_edge!(d::Neo4jDriver, e::CommunityEdge)
    params = _community_edge_params(e)
    query = """
    MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
    MERGE (a)-[r:HAS_MEMBER {uuid: \$uuid}]->(b)
    SET r.group_id = \$group_id, r.created_at = \$created_at
    RETURN r.uuid
    """
    execute_query(d, query; params = params)
    return e
end

function get_node(d::Neo4jDriver, uuid::String)
    params = Dict("uuid" => uuid)
    rows = execute_query(d, "MATCH (n:Entity {uuid: \$uuid}) RETURN $(_neo4j_entity_node_projection())"; params = params)
    !isempty(rows) && return _entity_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Episodic {uuid: \$uuid}) RETURN $(_neo4j_episodic_node_projection())"; params = params)
    !isempty(rows) && return _episodic_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Community {uuid: \$uuid}) RETURN $(_neo4j_community_node_projection())"; params = params)
    !isempty(rows) && return _community_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Saga {uuid: \$uuid}) RETURN $(_neo4j_saga_node_projection())"; params = params)
    !isempty(rows) && return _saga_node_from_row(rows[1])
    return nothing
end

function get_edge(d::Neo4jDriver, uuid::String)
    params = Dict("uuid" => uuid)
    rows = execute_query(d,
        "MATCH (a)-[r:RELATES_TO {uuid: \$uuid}]->(b) RETURN $(_neo4j_entity_edge_projection())";
        params = params)
    !isempty(rows) && return _entity_edge_from_row(rows[1])
    rows = execute_query(d,
        "MATCH (a)-[r:MENTIONS {uuid: \$uuid}]->(b) RETURN $(_neo4j_simple_edge_projection())";
        params = params)
    !isempty(rows) && return _episodic_edge_from_row(rows[1])
    rows = execute_query(d,
        "MATCH (a)-[r:HAS_MEMBER {uuid: \$uuid}]->(b) RETURN $(_neo4j_simple_edge_projection())";
        params = params)
    !isempty(rows) && return _community_edge_from_row(rows[1])
    return nothing
end

function delete_node!(d::Neo4jDriver, uuid::String)
    execute_query(d, "MATCH (n {uuid: \$uuid}) DETACH DELETE n"; params=Dict("uuid" => uuid))
end

function delete_edge!(d::Neo4jDriver, uuid::String)
    execute_query(d, "MATCH ()-[r {uuid: \$uuid}]-() DELETE r"; params=Dict("uuid" => uuid))
end

function clear!(d::Neo4jDriver)
    execute_query(d, "MATCH (n) DETACH DELETE n")
end

function get_entity_nodes(d::Neo4jDriver, group_id::String)::Vector{EntityNode}
    query = "MATCH (n:Entity)$(_neo4j_where_group("n", group_id)) RETURN $(_neo4j_entity_node_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_entity_node_from_row(r) for r in rows]
end

function get_entity_edges(d::Neo4jDriver, group_id::String)::Vector{EntityEdge}
    query = "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity)$(_neo4j_where_group("r", group_id)) RETURN $(_neo4j_entity_edge_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_entity_edge_from_row(r) for r in rows]
end

function get_episodic_nodes(d::Neo4jDriver, group_id::String)::Vector{EpisodicNode}
    query = "MATCH (n:Episodic)$(_neo4j_where_group("n", group_id)) RETURN $(_neo4j_episodic_node_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_episodic_node_from_row(r) for r in rows]
end

function get_latest_episodic_node(d::Neo4jDriver, group_id::String)::Union{Nothing, EpisodicNode}
    nodes = get_episodic_nodes(d, group_id)
    isempty(nodes) && return nothing
    return reduce((a, b) -> a.valid_at >= b.valid_at ? a : b, nodes)
end

function save_node!(d::Neo4jDriver, n::SagaNode)
    params = _saga_node_params(n)
    query = """
    MERGE (n:Saga {uuid: \$uuid})
    SET n.name = \$name,
        n.summary = \$summary,
        n.group_id = \$group_id,
        n.last_updated = \$last_updated
    RETURN n.uuid
    """
    execute_query(d, query; params = params)
    return n
end

function get_community_nodes(d::Neo4jDriver, group_id::String)::Vector{CommunityNode}
    query = "MATCH (n:Community)$(_neo4j_where_group("n", group_id)) RETURN $(_neo4j_community_node_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_community_node_from_row(r) for r in rows]
end

function get_community_edges(d::Neo4jDriver, group_id::String)::Vector{CommunityEdge}
    query = "MATCH (c:Community)-[r:HAS_MEMBER]->(n)$(_neo4j_where_group("r", group_id)) RETURN $(_neo4j_simple_edge_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_community_edge_from_row(r) for r in rows]
end

function get_saga_nodes(d::Neo4jDriver, group_id::String)::Vector{SagaNode}
    query = "MATCH (n:Saga)$(_neo4j_where_group("n", group_id)) RETURN $(_neo4j_saga_node_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_saga_node_from_row(r) for r in rows]
end

function get_episodes_for_saga(d::Neo4jDriver, saga_uuid::String)::Vector{EpisodicNode}
    query = "MATCH (n:Episodic {saga_uuid: \$saga_uuid}) " *
            "RETURN $(_neo4j_episodic_node_projection())"
    rows = execute_query(d, query; params = Dict("saga_uuid" => saga_uuid))
    return [_episodic_node_from_row(r) for r in rows]
end
