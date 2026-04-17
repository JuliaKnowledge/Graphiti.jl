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
    query = """
    MERGE (n:Entity {uuid: \$uuid})
    SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
    RETURN n.uuid
    """
    execute_query(d, query; params=Dict(
        "uuid" => n.uuid, "name" => n.name,
        "summary" => n.summary, "group_id" => n.group_id,
    ))
    return n
end

function save_node!(d::Neo4jDriver, n::EpisodicNode)
    query = """
    MERGE (n:Episodic {uuid: \$uuid})
    SET n.name = \$name, n.content = \$content, n.group_id = \$group_id
    RETURN n.uuid
    """
    execute_query(d, query; params=Dict(
        "uuid" => n.uuid, "name" => n.name,
        "content" => n.content, "group_id" => n.group_id,
    ))
    return n
end

function save_node!(d::Neo4jDriver, n::CommunityNode)
    execute_query(d,
        "MERGE (n:Community {uuid: \$uuid}) " *
        "SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id " *
        "RETURN n.uuid";
        params=Dict("uuid" => n.uuid, "name" => n.name,
                    "summary" => n.summary, "group_id" => n.group_id))
    return n
end

function save_edge!(d::Neo4jDriver, e::EntityEdge)
    query = """
    MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
    MERGE (a)-[r:RELATES_TO {uuid: \$uuid}]->(b)
    SET r.name = \$name, r.fact = \$fact, r.group_id = \$group_id
    RETURN r.uuid
    """
    execute_query(d, query; params=Dict(
        "uuid" => e.uuid, "src" => e.source_node_uuid, "tgt" => e.target_node_uuid,
        "name" => e.name, "fact" => e.fact, "group_id" => e.group_id,
    ))
    return e
end

function save_edge!(d::Neo4jDriver, e::EpisodicEdge)
    query = """
    MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
    MERGE (a)-[r:MENTIONS {uuid: \$uuid}]->(b)
    SET r.group_id = \$group_id
    RETURN r.uuid
    """
    execute_query(d, query; params=Dict(
        "uuid" => e.uuid, "src" => e.source_node_uuid,
        "tgt" => e.target_node_uuid, "group_id" => e.group_id,
    ))
    return e
end

function save_edge!(d::Neo4jDriver, e::CommunityEdge)
    query = """
    MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
    MERGE (a)-[r:HAS_MEMBER {uuid: \$uuid}]->(b)
    RETURN r.uuid
    """
    execute_query(d, query; params=Dict(
        "uuid" => e.uuid, "src" => e.source_node_uuid, "tgt" => e.target_node_uuid,
    ))
    return e
end

get_node(::Neo4jDriver, uuid::String) = nothing
get_edge(::Neo4jDriver, uuid::String) = nothing

function delete_node!(d::Neo4jDriver, uuid::String)
    execute_query(d, "MATCH (n {uuid: \$uuid}) DETACH DELETE n"; params=Dict("uuid" => uuid))
end

function delete_edge!(d::Neo4jDriver, uuid::String)
    execute_query(d, "MATCH ()-[r {uuid: \$uuid}]-() DELETE r"; params=Dict("uuid" => uuid))
end

function clear!(d::Neo4jDriver)
    execute_query(d, "MATCH (n) DETACH DELETE n")
end

get_entity_nodes(::Neo4jDriver, ::String)::Vector{EntityNode}       = EntityNode[]
get_entity_edges(::Neo4jDriver, ::String)::Vector{EntityEdge}       = EntityEdge[]
get_episodic_nodes(::Neo4jDriver, ::String)::Vector{EpisodicNode}   = EpisodicNode[]
get_latest_episodic_node(::Neo4jDriver, ::String)::Union{Nothing, EpisodicNode} = nothing

function save_node!(d::Neo4jDriver, n::SagaNode)
    query = """
    MERGE (n:Saga {uuid: \$uuid})
    SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
    RETURN n.uuid
    """
    execute_query(d, query; params=Dict(
        "uuid" => n.uuid, "name" => n.name,
        "summary" => n.summary, "group_id" => n.group_id,
    ))
    return n
end

function get_community_nodes(d::Neo4jDriver, group_id::String)::Vector{CommunityNode}
    query = isempty(group_id) ?
        "MATCH (n:Community) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id" :
        "MATCH (n:Community {group_id: \$group_id}) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id"
    rows = isempty(group_id) ? execute_query(d, query) :
        execute_query(d, query; params=Dict("group_id" => group_id))
    return [CommunityNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        summary = string(get(r, "summary", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_community_edges(d::Neo4jDriver, community_uuid::String)::Vector{CommunityEdge}
    query = "MATCH (c:Community {uuid: \$uuid})-[r:HAS_MEMBER]->(n) " *
            "RETURN r.uuid AS uuid, c.uuid AS src, n.uuid AS tgt, r.group_id AS group_id"
    rows = execute_query(d, query; params=Dict("uuid" => community_uuid))
    return [CommunityEdge(
        uuid = string(get(r, "uuid", "")),
        source_node_uuid = string(get(r, "src", "")),
        target_node_uuid = string(get(r, "tgt", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_saga_nodes(d::Neo4jDriver, group_id::String)::Vector{SagaNode}
    query = isempty(group_id) ?
        "MATCH (n:Saga) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id" :
        "MATCH (n:Saga {group_id: \$group_id}) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id"
    rows = isempty(group_id) ? execute_query(d, query) :
        execute_query(d, query; params=Dict("group_id" => group_id))
    return [SagaNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        summary = string(get(r, "summary", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_episodes_for_saga(d::Neo4jDriver, saga_uuid::String)::Vector{EpisodicNode}
    query = "MATCH (n:Episodic {saga_uuid: \$saga_uuid}) " *
            "RETURN n.uuid AS uuid, n.name AS name, n.content AS content, n.group_id AS group_id"
    rows = execute_query(d, query; params=Dict("saga_uuid" => saga_uuid))
    return [EpisodicNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        content = string(get(r, "content", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end
