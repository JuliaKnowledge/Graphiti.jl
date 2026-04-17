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

# ── Mutation API (mirrors Neo4jDriver) ───────────────────────────────────────

function save_node!(d::FalkorDBDriver, n::EntityNode)
    execute_query(d, """
        MERGE (n:Entity {uuid: \$uuid})
        SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
        RETURN n.uuid
        """;
        params = Dict("uuid" => n.uuid, "name" => n.name,
                      "summary" => n.summary, "group_id" => n.group_id))
    return n
end

function save_node!(d::FalkorDBDriver, n::EpisodicNode)
    execute_query(d, """
        MERGE (n:Episodic {uuid: \$uuid})
        SET n.name = \$name, n.content = \$content, n.group_id = \$group_id
        RETURN n.uuid
        """;
        params = Dict("uuid" => n.uuid, "name" => n.name,
                      "content" => n.content, "group_id" => n.group_id))
    return n
end

function save_node!(d::FalkorDBDriver, n::CommunityNode)
    execute_query(d,
        "MERGE (n:Community {uuid: \$uuid}) " *
        "SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id " *
        "RETURN n.uuid";
        params = Dict("uuid" => n.uuid, "name" => n.name,
                      "summary" => n.summary, "group_id" => n.group_id))
    return n
end

function save_node!(d::FalkorDBDriver, n::SagaNode)
    execute_query(d, """
        MERGE (n:Saga {uuid: \$uuid})
        SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
        RETURN n.uuid
        """;
        params = Dict("uuid" => n.uuid, "name" => n.name,
                      "summary" => n.summary, "group_id" => n.group_id))
    return n
end

function save_edge!(d::FalkorDBDriver, e::EntityEdge)
    execute_query(d, """
        MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
        MERGE (a)-[r:RELATES_TO {uuid: \$uuid}]->(b)
        SET r.name = \$name, r.fact = \$fact, r.group_id = \$group_id
        RETURN r.uuid
        """;
        params = Dict("uuid" => e.uuid, "src" => e.source_node_uuid,
                      "tgt" => e.target_node_uuid, "name" => e.name,
                      "fact" => e.fact, "group_id" => e.group_id))
    return e
end

function save_edge!(d::FalkorDBDriver, e::EpisodicEdge)
    execute_query(d, """
        MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
        MERGE (a)-[r:MENTIONS {uuid: \$uuid}]->(b)
        SET r.group_id = \$group_id
        RETURN r.uuid
        """;
        params = Dict("uuid" => e.uuid, "src" => e.source_node_uuid,
                      "tgt" => e.target_node_uuid, "group_id" => e.group_id))
    return e
end

function save_edge!(d::FalkorDBDriver, e::CommunityEdge)
    execute_query(d, """
        MATCH (a {uuid: \$src}), (b {uuid: \$tgt})
        MERGE (a)-[r:HAS_MEMBER {uuid: \$uuid}]->(b)
        RETURN r.uuid
        """;
        params = Dict("uuid" => e.uuid, "src" => e.source_node_uuid,
                      "tgt" => e.target_node_uuid))
    return e
end

get_node(::FalkorDBDriver, uuid::String) = nothing
get_edge(::FalkorDBDriver, uuid::String) = nothing

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

# Read methods — return empty by default (parity with Neo4jDriver scope).
get_entity_nodes(::FalkorDBDriver, ::String)::Vector{EntityNode}     = EntityNode[]
get_entity_edges(::FalkorDBDriver, ::String)::Vector{EntityEdge}     = EntityEdge[]
get_episodic_nodes(::FalkorDBDriver, ::String)::Vector{EpisodicNode} = EpisodicNode[]
get_latest_episodic_node(::FalkorDBDriver, ::String)::Union{Nothing, EpisodicNode} = nothing

function get_community_nodes(d::FalkorDBDriver, group_id::String)::Vector{CommunityNode}
    rows = isempty(group_id) ?
        execute_query(d,
            "MATCH (n:Community) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id") :
        execute_query(d,
            "MATCH (n:Community {group_id: \$group_id}) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id";
            params = Dict("group_id" => group_id))
    return [CommunityNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        summary = string(get(r, "summary", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_community_edges(d::FalkorDBDriver, community_uuid::String)::Vector{CommunityEdge}
    rows = execute_query(d,
        "MATCH (c:Community {uuid: \$uuid})-[r:HAS_MEMBER]->(n) " *
        "RETURN r.uuid AS uuid, c.uuid AS src, n.uuid AS tgt, r.group_id AS group_id";
        params = Dict("uuid" => community_uuid))
    return [CommunityEdge(
        uuid = string(get(r, "uuid", "")),
        source_node_uuid = string(get(r, "src", "")),
        target_node_uuid = string(get(r, "tgt", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_saga_nodes(d::FalkorDBDriver, group_id::String)::Vector{SagaNode}
    rows = isempty(group_id) ?
        execute_query(d,
            "MATCH (n:Saga) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id") :
        execute_query(d,
            "MATCH (n:Saga {group_id: \$group_id}) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id";
            params = Dict("group_id" => group_id))
    return [SagaNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        summary = string(get(r, "summary", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_episodes_for_saga(d::FalkorDBDriver, saga_uuid::String)::Vector{EpisodicNode}
    rows = execute_query(d,
        "MATCH (n:Episodic {saga_uuid: \$saga_uuid}) " *
        "RETURN n.uuid AS uuid, n.name AS name, n.content AS content, n.group_id AS group_id";
        params = Dict("saga_uuid" => saga_uuid))
    return [EpisodicNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        content = string(get(r, "content", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end
