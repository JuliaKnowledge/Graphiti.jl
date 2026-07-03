"""FalkorDB driver — Cypher over Redis `GRAPH.QUERY` with injectable transport.

FalkorDB ([falkordb.com](https://www.falkordb.com)) is a Redis-backed
graph database that exposes the OpenCypher query language via the
`GRAPH.QUERY` Redis command. This driver speaks the RESP2 wire
protocol directly (no external Julia client required) but, like
[`Neo4jDriver`](@ref), accepts an injectable command function so tests
can stub the network entirely.
"""

struct GraphitiFalkorDBError <: Exception
    message::String
end

Base.showerror(io::IO, e::GraphitiFalkorDBError) =
    print(io, "GraphitiFalkorDBError: ", e.message)

# ── RESP2 protocol (minimal, command + reply only) ───────────────────────────

function _resp2_encode_command(args::AbstractVector{<:AbstractString})::String
    io = IOBuffer()
    print(io, "*", length(args), "\r\n")
    for a in args
        bytes = String(a)
        print(io, "\$", sizeof(bytes), "\r\n", bytes, "\r\n")
    end
    return String(take!(io))
end

# Read a single \r\n-terminated line from `io`, excluding the CRLF.
function _resp2_read_line(io::IO)::String
    buf = IOBuffer()
    while !eof(io)
        b = read(io, UInt8)
        if b == UInt8('\r')
            if !eof(io)
                nb = read(io, UInt8)
                nb == UInt8('\n') || throw(GraphitiFalkorDBError("RESP2: expected LF after CR"))
            end
            return String(take!(buf))
        else
            write(buf, b)
        end
    end
    throw(GraphitiFalkorDBError("RESP2: unexpected EOF reading line"))
end

# Decode a single RESP2 reply value.
function _resp2_decode(io::IO)
    eof(io) && throw(GraphitiFalkorDBError("RESP2: unexpected EOF"))
    tag = read(io, UInt8)
    if tag == UInt8('+')
        return _resp2_read_line(io)                        # simple string
    elseif tag == UInt8('-')
        throw(GraphitiFalkorDBError(_resp2_read_line(io))) # error
    elseif tag == UInt8(':')
        return parse(Int, _resp2_read_line(io))            # integer
    elseif tag == UInt8('$')
        len = parse(Int, _resp2_read_line(io))             # bulk string
        len < 0 && return nothing
        bytes = read(io, len)
        # Discard trailing \r\n
        read(io, 2)
        return String(bytes)
    elseif tag == UInt8('*')
        n = parse(Int, _resp2_read_line(io))               # array
        n < 0 && return nothing
        return [_resp2_decode(io) for _ in 1:n]
    else
        throw(GraphitiFalkorDBError("RESP2: unknown tag $(Char(tag))"))
    end
end

# Default network command function: open a fresh socket per call (simple,
# correct, low-throughput; users can swap in a pooled implementation).
function _default_falkor_command(d, args::AbstractVector{<:AbstractString})
    sock = Sockets.connect(d.host, d.port)
    try
        if !isempty(d.password)
            write(sock, _resp2_encode_command(["AUTH", d.password]))
            reply = _resp2_decode(sock)
            reply == "OK" || throw(GraphitiFalkorDBError("AUTH failed: $reply"))
        end
        write(sock, _resp2_encode_command(args))
        return _resp2_decode(sock)
    finally
        close(sock)
    end
end

# ── Driver ───────────────────────────────────────────────────────────────────

"""
    FalkorDBDriver(; host, port, password, graph, _command_fn)

Cypher-over-Redis driver for [FalkorDB](https://www.falkordb.com).
Speaks raw RESP2 over TCP using `Sockets` stdlib (no external Julia
client dependency). Defaults read `FALKORDB_HOST`, `FALKORDB_PORT`,
`FALKORDB_PASSWORD`, `FALKORDB_GRAPH` env vars. Override `_command_fn`
with `(driver, args::Vector{String}) -> reply` to swap the transport
in tests.

Parameter binding: FalkorDB does not yet support Bolt-style parameter
binding, so the driver transparently rewrites `\$param` queries with a
`CYPHER name='val' …` prelude. See the FalkorDB guide for details.
"""
mutable struct FalkorDBDriver <: AbstractGraphDriver
    host::String
    port::Int
    password::String
    graph::String
    _command_fn::Function
end

function FalkorDBDriver(;
    host::String = get(ENV, "FALKORDB_HOST", "localhost"),
    port::Int    = parse(Int, get(ENV, "FALKORDB_PORT", "6379")),
    password::String = get(ENV, "FALKORDB_PASSWORD", ""),
    graph::String    = get(ENV, "FALKORDB_GRAPH", "graphiti"),
    _command_fn::Function = _default_falkor_command,
)
    return FalkorDBDriver(host, port, password, graph, _command_fn)
end

# ── Cypher parameter encoding ────────────────────────────────────────────────
# FalkorDB does not yet support CYPHER parameters in the same way Neo4j does;
# the canonical workaround is a `CYPHER` parameter prelude:
#   GRAPH.QUERY g "CYPHER name='Alice' MATCH (n {name:\$name}) RETURN n"

_falkor_quote(s::AbstractString) = "'" * replace(String(s), "\\" => "\\\\", "'" => "\\'") * "'"

function _falkor_encode_value(v)
    v === nothing && return "null"
    v isa Bool    && return v ? "true" : "false"
    v isa Real    && return string(v)
    v isa AbstractString && return _falkor_quote(v)
    v isa AbstractVector && return "[" * join((_falkor_encode_value(x) for x in v), ",") * "]"
    return _falkor_quote(string(v))
end

function _falkor_param_prelude(params::Dict)
    isempty(params) && return ""
    parts = String[]
    for (k, v) in params
        push!(parts, string(k, "=", _falkor_encode_value(v)))
    end
    return "CYPHER " * join(parts, " ") * " "
end

# ── execute_query ────────────────────────────────────────────────────────────
# Reply shape for GRAPH.QUERY: an array
#   [ header_array, rows_array, statistics_array ]
# header_array : [ [type_int, name_string], ... ]
# rows_array   : [ [val, val, ...], ... ]   (each `val` is itself a 2-element
#                                            [type, value] in newer protocols,
#                                            or just the raw value in older ones)

function _flatten_value(v)
    v isa AbstractVector && length(v) == 2 && v[1] isa Integer ?
        _flatten_value(v[2]) : v
end

function _falkor_parse_reply(reply)::Vector{Dict{String,Any}}
    reply === nothing && return Dict{String,Any}[]
    reply isa AbstractVector || return Dict{String,Any}[]
    length(reply) < 2 && return Dict{String,Any}[]   # no result-set form

    header = reply[1]
    rows   = reply[2]
    cols   = String[]
    if header isa AbstractVector
        for h in header
            if h isa AbstractString
                push!(cols, h)
            elseif h isa AbstractVector && length(h) >= 2 && h[2] isa AbstractString
                push!(cols, h[2])
            elseif h isa AbstractVector && length(h) >= 2
                push!(cols, string(h[2]))
            else
                push!(cols, string(h))
            end
        end
    end

    out = Dict{String,Any}[]
    rows isa AbstractVector || return out
    for row in rows
        d = Dict{String,Any}()
        if row isa AbstractVector
            for (i, v) in enumerate(row)
                col = i <= length(cols) ? cols[i] : string("col", i)
                d[col] = _flatten_value(v)
            end
        end
        push!(out, d)
    end
    return out
end

function execute_query(d::FalkorDBDriver, query::String; params::Dict=Dict())::Vector{Dict}
    full_query = string(_falkor_param_prelude(params), query)
    reply = d._command_fn(d, ["GRAPH.QUERY", d.graph, full_query, "--compact"])
    return _falkor_parse_reply(reply)
end

_falkor_where_group(alias::String, group_id::String) =
    isempty(group_id) ? "" : " WHERE $alias.group_id = \$group_id"

_falkor_entity_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.name_embedding AS name_embedding, " *
    "$alias.summary AS summary, $alias.group_id AS group_id, $alias.labels AS labels, " *
    "$alias.attributes AS attributes, $alias.created_at AS created_at"

_falkor_episodic_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.content AS content, " *
    "$alias.content_embedding AS content_embedding, $alias.source AS source, " *
    "$alias.source_description AS source_description, $alias.valid_at AS valid_at, " *
    "$alias.group_id AS group_id, $alias.entity_edges AS entity_edges, " *
    "$alias.saga_uuid AS saga_uuid, $alias.created_at AS created_at"

_falkor_community_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.name_embedding AS name_embedding, " *
    "$alias.summary AS summary, $alias.group_id AS group_id, $alias.created_at AS created_at"

_falkor_saga_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.summary AS summary, " *
    "$alias.group_id AS group_id, $alias.last_updated AS last_updated"

_falkor_entity_edge_projection(rel::String = "r", src::String = "a", tgt::String = "b") =
    "$rel.uuid AS uuid, $src.uuid AS src, $tgt.uuid AS tgt, $rel.name AS name, " *
    "$rel.fact AS fact, $rel.fact_embedding AS fact_embedding, $rel.episodes AS episodes, " *
    "$rel.group_id AS group_id, $rel.valid_at AS valid_at, $rel.invalid_at AS invalid_at, " *
    "$rel.expired_at AS expired_at, $rel.reference_time AS reference_time, " *
    "$rel.attributes AS attributes, $rel.created_at AS created_at"

_falkor_simple_edge_projection(rel::String = "r", src::String = "a", tgt::String = "b") =
    "$rel.uuid AS uuid, $src.uuid AS src, $tgt.uuid AS tgt, $rel.group_id AS group_id, " *
    "$rel.created_at AS created_at"

# ── Mutation API (mirrors Neo4jDriver) ───────────────────────────────────────

function save_node!(d::FalkorDBDriver, n::EntityNode)
    params = _entity_node_params(n)
    execute_query(d, """
        MERGE (n:Entity {uuid: \$uuid})
        SET n.name = \$name,
            n.name_embedding = \$name_embedding,
            n.summary = \$summary,
            n.group_id = \$group_id,
            n.labels = \$labels,
            n.attributes = \$attributes,
            n.created_at = \$created_at
        RETURN n.uuid
        """;
        params = params)
    return n
end

function save_node!(d::FalkorDBDriver, n::EpisodicNode)
    params = _episodic_node_params(n)
    execute_query(d, """
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
        """;
        params = params)
    return n
end

function save_node!(d::FalkorDBDriver, n::CommunityNode)
    params = _community_node_params(n)
    execute_query(d,
        "MERGE (n:Community {uuid: \$uuid}) " *
        "SET n.name = \$name, n.name_embedding = \$name_embedding, " *
        "n.summary = \$summary, n.group_id = \$group_id, n.created_at = \$created_at " *
        "RETURN n.uuid";
        params = params)
    return n
end

function save_node!(d::FalkorDBDriver, n::SagaNode)
    params = _saga_node_params(n)
    execute_query(d, """
        MERGE (n:Saga {uuid: \$uuid})
        SET n.name = \$name,
            n.summary = \$summary,
            n.group_id = \$group_id,
            n.last_updated = \$last_updated
        RETURN n.uuid
        """;
        params = params)
    return n
end

function save_edge!(d::FalkorDBDriver, e::EntityEdge)
    params = _entity_edge_params(e)
    execute_query(d, """
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
        """;
        params = params)
    return e
end

function save_edge!(d::FalkorDBDriver, e::EpisodicEdge)
    params = _episodic_edge_params(e)
    execute_query(d, """
        MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
        MERGE (a)-[r:MENTIONS {uuid: \$uuid}]->(b)
        SET r.group_id = \$group_id, r.created_at = \$created_at
        RETURN r.uuid
        """;
        params = params)
    return e
end

function save_edge!(d::FalkorDBDriver, e::CommunityEdge)
    params = _community_edge_params(e)
    execute_query(d, """
        MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
        MERGE (a)-[r:HAS_MEMBER {uuid: \$uuid}]->(b)
        SET r.group_id = \$group_id, r.created_at = \$created_at
        RETURN r.uuid
        """;
        params = params)
    return e
end

function get_node(d::FalkorDBDriver, uuid::String)
    params = Dict("uuid" => uuid)
    rows = execute_query(d, "MATCH (n:Entity {uuid: \$uuid}) RETURN $(_falkor_entity_node_projection())"; params = params)
    !isempty(rows) && return _entity_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Episodic {uuid: \$uuid}) RETURN $(_falkor_episodic_node_projection())"; params = params)
    !isempty(rows) && return _episodic_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Community {uuid: \$uuid}) RETURN $(_falkor_community_node_projection())"; params = params)
    !isempty(rows) && return _community_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Saga {uuid: \$uuid}) RETURN $(_falkor_saga_node_projection())"; params = params)
    !isempty(rows) && return _saga_node_from_row(rows[1])
    return nothing
end

function get_edge(d::FalkorDBDriver, uuid::String)
    params = Dict("uuid" => uuid)
    rows = execute_query(d,
        "MATCH (a)-[r:RELATES_TO {uuid: \$uuid}]->(b) RETURN $(_falkor_entity_edge_projection())";
        params = params)
    !isempty(rows) && return _entity_edge_from_row(rows[1])
    rows = execute_query(d,
        "MATCH (a)-[r:MENTIONS {uuid: \$uuid}]->(b) RETURN $(_falkor_simple_edge_projection())";
        params = params)
    !isempty(rows) && return _episodic_edge_from_row(rows[1])
    rows = execute_query(d,
        "MATCH (a)-[r:HAS_MEMBER {uuid: \$uuid}]->(b) RETURN $(_falkor_simple_edge_projection())";
        params = params)
    !isempty(rows) && return _community_edge_from_row(rows[1])
    return nothing
end

function delete_node!(d::FalkorDBDriver, uuid::String)
    execute_query(d, "MATCH (n {uuid: \$uuid}) DETACH DELETE n";
                  params = Dict("uuid" => uuid))
end

function delete_edge!(d::FalkorDBDriver, uuid::String)
    execute_query(d, "MATCH ()-[r {uuid: \$uuid}]-() DELETE r";
                  params = Dict("uuid" => uuid))
end

function clear!(d::FalkorDBDriver)
    # `GRAPH.DELETE` removes the entire graph atomically (faster than
    # MATCH (n) DETACH DELETE n on large graphs). Ignore errors — the
    # graph may not exist yet.
    try
        d._command_fn(d, ["GRAPH.DELETE", d.graph])
    catch e
        e isa GraphitiFalkorDBError || rethrow(e)
    end
    return nothing
end

function get_entity_nodes(d::FalkorDBDriver, group_id::String)::Vector{EntityNode}
    query = "MATCH (n:Entity)$(_falkor_where_group("n", group_id)) RETURN $(_falkor_entity_node_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_entity_node_from_row(r) for r in rows]
end

function get_entity_edges(d::FalkorDBDriver, group_id::String)::Vector{EntityEdge}
    query = "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity)$(_falkor_where_group("r", group_id)) RETURN $(_falkor_entity_edge_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_entity_edge_from_row(r) for r in rows]
end

function get_episodic_nodes(d::FalkorDBDriver, group_id::String)::Vector{EpisodicNode}
    query = "MATCH (n:Episodic)$(_falkor_where_group("n", group_id)) RETURN $(_falkor_episodic_node_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_episodic_node_from_row(r) for r in rows]
end

function get_latest_episodic_node(d::FalkorDBDriver, group_id::String)::Union{Nothing, EpisodicNode}
    nodes = get_episodic_nodes(d, group_id)
    isempty(nodes) && return nothing
    return reduce((a, b) -> a.valid_at >= b.valid_at ? a : b, nodes)
end

function get_community_nodes(d::FalkorDBDriver, group_id::String)::Vector{CommunityNode}
    query = "MATCH (n:Community)$(_falkor_where_group("n", group_id)) RETURN $(_falkor_community_node_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_community_node_from_row(r) for r in rows]
end

function get_community_edges(d::FalkorDBDriver, group_id::String)::Vector{CommunityEdge}
    query = "MATCH (c:Community)-[r:HAS_MEMBER]->(n)$(_falkor_where_group("r", group_id)) RETURN $(_falkor_simple_edge_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_community_edge_from_row(r) for r in rows]
end

function get_saga_nodes(d::FalkorDBDriver, group_id::String)::Vector{SagaNode}
    query = "MATCH (n:Saga)$(_falkor_where_group("n", group_id)) RETURN $(_falkor_saga_node_projection())"
    rows = isempty(group_id) ? execute_query(d, query) : execute_query(d, query; params = Dict("group_id" => group_id))
    return [_saga_node_from_row(r) for r in rows]
end

function get_episodes_for_saga(d::FalkorDBDriver, saga_uuid::String)::Vector{EpisodicNode}
    rows = execute_query(d,
        "MATCH (n:Episodic {saga_uuid: \$saga_uuid}) " *
        "RETURN $(_falkor_episodic_node_projection())";
        params = Dict("saga_uuid" => saga_uuid))
    return [_episodic_node_from_row(r) for r in rows]
end
