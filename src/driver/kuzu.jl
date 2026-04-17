"""
Kùzu embedded graph database driver.

Kùzu (https://kuzudb.com) is an embedded property-graph database with a
Cypher-like query language. There is no native Julia client; this driver
uses an injectable `_query_fn` so the structure can be unit-tested without
the C library, and integrators can plug in their own libkuzu binding
(typically via `Libdl.dlopen` / `ccall`).

Differences from Neo4jDriver/FalkorDBDriver:

* **Strict schema.** Kùzu requires `CREATE NODE TABLE` / `CREATE REL TABLE`
  before nodes/edges can be inserted. Call `init_schema!(driver)` once
  on a fresh database (or run with `auto_init_schema=true`).
* **No Bolt-style param binding** in our default path — params are inlined
  into the query string before being handed to `_query_fn`. (Real
  applications using `kuzu_prepared_statement` can override `_query_fn`
  to bind params natively.)
* **Rel tables are typed.** `RELATES_TO` is Entity→Entity; `MENTIONS` is
  Episodic→Entity; `HAS_MEMBER` is Community→Entity. Edges that do not
  match these types should be saved via a custom schema extension.
"""

struct GraphitiKuzuError <: Exception
    message::String
end

Base.showerror(io::IO, e::GraphitiKuzuError) = print(io, "GraphitiKuzuError: ", e.message)

# ── default _query_fn (no-op stub that raises a helpful error) ──────────────

function _default_kuzu_query(d, query::String, params::Dict)::Vector{Dict{String,Any}}
    throw(GraphitiKuzuError(
        "No Kùzu backend is wired in. Construct KuzuDriver with " *
        "_query_fn = my_fn, where my_fn(driver, query, params)::Vector{Dict} " *
        "executes the query against libkuzu (e.g. via Libdl/ccall) and " *
        "returns the result rows. See docs/src/guide/kuzu.md."
    ))
end

# ── value encoding (used for inline param substitution) ──────────────────────

function _kuzu_encode_value(v)::String
    v === nothing && return "NULL"
    v isa Bool && return v ? "true" : "false"
    v isa Real && return string(v)
    v isa AbstractVector && return "[" * join((_kuzu_encode_value(x) for x in v), ", ") * "]"
    s = string(v)
    return "'" * replace(s, "\\" => "\\\\", "'" => "\\'") * "'"
end

"""
    _kuzu_inline_params(query, params) -> String

Replace `\$name` placeholders in `query` with literal Cypher values from
`params`. Longest names are substituted first to avoid `\$ab` matching
inside `\$abc`.
"""
function _kuzu_inline_params(query::String, params::Dict)::String
    isempty(params) && return query
    out = query
    keys_sorted = sort!(collect(keys(params)); by = k -> -length(string(k)))
    for k in keys_sorted
        ks = string(k)
        out = replace(out, "\$" * ks => _kuzu_encode_value(params[k]))
    end
    return out
end

# ── driver struct ────────────────────────────────────────────────────────────

mutable struct KuzuDriver <: AbstractGraphDriver
    db_path::String
    _query_fn::Function
    schema_initialized::Bool
end

function KuzuDriver(;
    db_path::String = get(ENV, "KUZU_DB_PATH", "./kuzu_db"),
    _query_fn::Function = _default_kuzu_query,
    auto_init_schema::Bool = false,
)
    d = KuzuDriver(db_path, _query_fn, false)
    if auto_init_schema
        init_schema!(d)
    end
    return d
end

# ── schema ───────────────────────────────────────────────────────────────────

const KUZU_NODE_TABLES = [
    ("Entity",    "uuid STRING, name STRING, summary STRING, group_id STRING, PRIMARY KEY(uuid)"),
    ("Episodic",  "uuid STRING, name STRING, content STRING, group_id STRING, saga_uuid STRING, PRIMARY KEY(uuid)"),
    ("Community", "uuid STRING, name STRING, summary STRING, group_id STRING, PRIMARY KEY(uuid)"),
    ("Saga",      "uuid STRING, name STRING, summary STRING, group_id STRING, PRIMARY KEY(uuid)"),
]

const KUZU_REL_TABLES = [
    ("RELATES_TO", "FROM Entity TO Entity, uuid STRING, name STRING, fact STRING, group_id STRING"),
    ("MENTIONS",   "FROM Episodic TO Entity, uuid STRING, group_id STRING"),
    ("HAS_MEMBER", "FROM Community TO Entity, uuid STRING, group_id STRING"),
]

"""
    init_schema!(driver) -> driver

Create the node/rel tables required by Graphiti if they don't already exist.
Safe to call repeatedly — uses `CREATE NODE TABLE IF NOT EXISTS`.
"""
function init_schema!(d::KuzuDriver)
    for (name, cols) in KUZU_NODE_TABLES
        d._query_fn(d, "CREATE NODE TABLE IF NOT EXISTS $name($cols)", Dict())
    end
    for (name, cols) in KUZU_REL_TABLES
        d._query_fn(d, "CREATE REL TABLE IF NOT EXISTS $name($cols)", Dict())
    end
    d.schema_initialized = true
    return d
end

# ── execute_query ────────────────────────────────────────────────────────────

function execute_query(d::KuzuDriver, query::String; params::Dict = Dict())::Vector{Dict{String,Any}}
    return d._query_fn(d, query, params)
end

# ── mutations ────────────────────────────────────────────────────────────────
# Kùzu MERGE semantics: `MERGE (n:Entity {uuid: '…'}) ON CREATE SET … ON MATCH SET …`

function save_node!(d::KuzuDriver, n::EntityNode)
    q = """
    MERGE (n:Entity {uuid: \$uuid})
    ON CREATE SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
    ON MATCH  SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
    """
    execute_query(d, q; params = Dict(
        "uuid" => n.uuid, "name" => n.name,
        "summary" => n.summary, "group_id" => n.group_id,
    ))
    return n
end

function save_node!(d::KuzuDriver, n::EpisodicNode)
    q = """
    MERGE (n:Episodic {uuid: \$uuid})
    ON CREATE SET n.name = \$name, n.content = \$content, n.group_id = \$group_id
    ON MATCH  SET n.name = \$name, n.content = \$content, n.group_id = \$group_id
    """
    execute_query(d, q; params = Dict(
        "uuid" => n.uuid, "name" => n.name,
        "content" => n.content, "group_id" => n.group_id,
    ))
    return n
end

function save_node!(d::KuzuDriver, n::CommunityNode)
    q = """
    MERGE (n:Community {uuid: \$uuid})
    ON CREATE SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
    ON MATCH  SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
    """
    execute_query(d, q; params = Dict(
        "uuid" => n.uuid, "name" => n.name,
        "summary" => n.summary, "group_id" => n.group_id,
    ))
    return n
end

function save_node!(d::KuzuDriver, n::SagaNode)
    q = """
    MERGE (n:Saga {uuid: \$uuid})
    ON CREATE SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
    ON MATCH  SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id
    """
    execute_query(d, q; params = Dict(
        "uuid" => n.uuid, "name" => n.name,
        "summary" => n.summary, "group_id" => n.group_id,
    ))
    return n
end

function save_edge!(d::KuzuDriver, e::EntityEdge)
    q = """
    MATCH (a:Entity {uuid: \$src}), (b:Entity {uuid: \$tgt})
    MERGE (a)-[r:RELATES_TO {uuid: \$uuid}]->(b)
    SET r.name = \$name, r.fact = \$fact, r.group_id = \$group_id
    """
    execute_query(d, q; params = Dict(
        "uuid" => e.uuid, "src" => e.source_node_uuid, "tgt" => e.target_node_uuid,
        "name" => e.name, "fact" => e.fact, "group_id" => e.group_id,
    ))
    return e
end

function save_edge!(d::KuzuDriver, e::EpisodicEdge)
    q = """
    MATCH (a:Episodic {uuid: \$src}), (b:Entity {uuid: \$tgt})
    MERGE (a)-[r:MENTIONS {uuid: \$uuid}]->(b)
    SET r.group_id = \$group_id
    """
    execute_query(d, q; params = Dict(
        "uuid" => e.uuid, "src" => e.source_node_uuid,
        "tgt" => e.target_node_uuid, "group_id" => e.group_id,
    ))
    return e
end

function save_edge!(d::KuzuDriver, e::CommunityEdge)
    q = """
    MATCH (a:Community {uuid: \$src}), (b:Entity {uuid: \$tgt})
    MERGE (a)-[r:HAS_MEMBER {uuid: \$uuid}]->(b)
    SET r.group_id = \$group_id
    """
    execute_query(d, q; params = Dict(
        "uuid" => e.uuid, "src" => e.source_node_uuid,
        "tgt" => e.target_node_uuid, "group_id" => e.group_id,
    ))
    return e
end

# ── deletions ────────────────────────────────────────────────────────────────

get_node(::KuzuDriver, ::String) = nothing
get_edge(::KuzuDriver, ::String) = nothing

function delete_node!(d::KuzuDriver, uuid::String)
    execute_query(d, "MATCH (n) WHERE n.uuid = \$uuid DETACH DELETE n";
                  params = Dict("uuid" => uuid))
end

function delete_edge!(d::KuzuDriver, uuid::String)
    execute_query(d, "MATCH ()-[r]->() WHERE r.uuid = \$uuid DELETE r";
                  params = Dict("uuid" => uuid))
end

"""
    clear!(driver)

Drop all rel/node tables and recreate the schema. Idempotent.
"""
function clear!(d::KuzuDriver)
    for (name, _) in KUZU_REL_TABLES
        try
            d._query_fn(d, "DROP TABLE $name", Dict())
        catch e
            e isa GraphitiKuzuError || rethrow(e)
        end
    end
    for (name, _) in KUZU_NODE_TABLES
        try
            d._query_fn(d, "DROP TABLE $name", Dict())
        catch e
            e isa GraphitiKuzuError || rethrow(e)
        end
    end
    d.schema_initialized = false
    init_schema!(d)
    return d
end

# ── reads (parity with Neo4jDriver scope) ────────────────────────────────────

get_entity_nodes(::KuzuDriver, ::String)::Vector{EntityNode}     = EntityNode[]
get_entity_edges(::KuzuDriver, ::String)::Vector{EntityEdge}     = EntityEdge[]
get_episodic_nodes(::KuzuDriver, ::String)::Vector{EpisodicNode} = EpisodicNode[]
get_latest_episodic_node(::KuzuDriver, ::String)::Union{Nothing,EpisodicNode} = nothing

function get_community_nodes(d::KuzuDriver, group_id::String)::Vector{CommunityNode}
    q = isempty(group_id) ?
        "MATCH (n:Community) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id" :
        "MATCH (n:Community) WHERE n.group_id = \$group_id RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id"
    rows = isempty(group_id) ? execute_query(d, q) :
        execute_query(d, q; params = Dict("group_id" => group_id))
    return [CommunityNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        summary = string(get(r, "summary", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_community_edges(d::KuzuDriver, community_uuid::String)::Vector{CommunityEdge}
    q = "MATCH (c:Community)-[r:HAS_MEMBER]->(n:Entity) WHERE c.uuid = \$uuid " *
        "RETURN r.uuid AS uuid, c.uuid AS src, n.uuid AS tgt, r.group_id AS group_id"
    rows = execute_query(d, q; params = Dict("uuid" => community_uuid))
    return [CommunityEdge(
        uuid = string(get(r, "uuid", "")),
        source_node_uuid = string(get(r, "src", "")),
        target_node_uuid = string(get(r, "tgt", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_saga_nodes(d::KuzuDriver, group_id::String)::Vector{SagaNode}
    q = isempty(group_id) ?
        "MATCH (n:Saga) RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id" :
        "MATCH (n:Saga) WHERE n.group_id = \$group_id RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, n.group_id AS group_id"
    rows = isempty(group_id) ? execute_query(d, q) :
        execute_query(d, q; params = Dict("group_id" => group_id))
    return [SagaNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        summary = string(get(r, "summary", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end

function get_episodes_for_saga(d::KuzuDriver, saga_uuid::String)::Vector{EpisodicNode}
    q = "MATCH (n:Episodic) WHERE n.saga_uuid = \$saga_uuid " *
        "RETURN n.uuid AS uuid, n.name AS name, n.content AS content, n.group_id AS group_id"
    rows = execute_query(d, q; params = Dict("saga_uuid" => saga_uuid))
    return [EpisodicNode(
        uuid = string(get(r, "uuid", "")),
        name = string(get(r, "name", "")),
        content = string(get(r, "content", "")),
        group_id = string(get(r, "group_id", "")),
    ) for r in rows]
end
