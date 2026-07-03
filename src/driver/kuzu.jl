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

"""
    KuzuDriver(; db_path, _query_fn, auto_init_schema=false)

Driver for [Kùzu](https://kuzudb.com), an embedded property-graph
database with a Cypher-like query language. There is no native Julia
client for Kùzu; this driver delegates query execution to a
`_query_fn(driver, query::String, params::Dict) -> Vector{Dict}` that
the user supplies (typically a `ccall` wrapper over `libkuzu`).

`db_path` defaults to the `KUZU_DB_PATH` env var. Pass
`auto_init_schema=true` (or call [`init_schema!`](@ref) once) on a
fresh database to create the Entity / Episodic / Community / Saga
node tables and the RELATES_TO / MENTIONS / HAS_MEMBER rel tables.

The default `_query_fn` raises `Graphiti.GraphitiKuzuError` to
encourage users to wire in a real backend; the Kùzu guide page
includes an FFI sketch.
"""
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
    ("Entity",    "uuid STRING, name STRING, name_embedding STRING, summary STRING, group_id STRING, labels STRING, attributes STRING, created_at STRING, PRIMARY KEY(uuid)"),
    ("Episodic",  "uuid STRING, name STRING, content STRING, content_embedding STRING, source STRING, source_description STRING, valid_at STRING, group_id STRING, entity_edges STRING, saga_uuid STRING, created_at STRING, PRIMARY KEY(uuid)"),
    ("Community", "uuid STRING, name STRING, name_embedding STRING, summary STRING, group_id STRING, created_at STRING, PRIMARY KEY(uuid)"),
    ("Saga",      "uuid STRING, name STRING, summary STRING, group_id STRING, last_updated STRING, PRIMARY KEY(uuid)"),
]

const KUZU_REL_TABLES = [
    ("RELATES_TO", "FROM Entity TO Entity, uuid STRING, name STRING, fact STRING, fact_embedding STRING, episodes STRING, group_id STRING, valid_at STRING, invalid_at STRING, expired_at STRING, reference_time STRING, attributes STRING, created_at STRING"),
    ("MENTIONS",   "FROM Episodic TO Entity, uuid STRING, group_id STRING, created_at STRING"),
    ("HAS_MEMBER", "FROM Community TO Entity, uuid STRING, group_id STRING, created_at STRING"),
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

_kuzu_where_group(alias::String, group_id::String) =
    isempty(group_id) ? "" : " WHERE $alias.group_id = \$group_id"

_kuzu_entity_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.name_embedding AS name_embedding, " *
    "$alias.summary AS summary, $alias.group_id AS group_id, $alias.labels AS labels, " *
    "$alias.attributes AS attributes, $alias.created_at AS created_at"

_kuzu_episodic_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.content AS content, " *
    "$alias.content_embedding AS content_embedding, $alias.source AS source, " *
    "$alias.source_description AS source_description, $alias.valid_at AS valid_at, " *
    "$alias.group_id AS group_id, $alias.entity_edges AS entity_edges, " *
    "$alias.saga_uuid AS saga_uuid, $alias.created_at AS created_at"

_kuzu_community_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.name_embedding AS name_embedding, " *
    "$alias.summary AS summary, $alias.group_id AS group_id, $alias.created_at AS created_at"

_kuzu_saga_node_projection(alias::String = "n") =
    "$alias.uuid AS uuid, $alias.name AS name, $alias.summary AS summary, " *
    "$alias.group_id AS group_id, $alias.last_updated AS last_updated"

_kuzu_entity_edge_projection(rel::String = "r", src::String = "a", tgt::String = "b") =
    "$rel.uuid AS uuid, $src.uuid AS src, $tgt.uuid AS tgt, $rel.name AS name, " *
    "$rel.fact AS fact, $rel.fact_embedding AS fact_embedding, $rel.episodes AS episodes, " *
    "$rel.group_id AS group_id, $rel.valid_at AS valid_at, $rel.invalid_at AS invalid_at, " *
    "$rel.expired_at AS expired_at, $rel.reference_time AS reference_time, " *
    "$rel.attributes AS attributes, $rel.created_at AS created_at"

_kuzu_simple_edge_projection(rel::String = "r", src::String = "a", tgt::String = "b") =
    "$rel.uuid AS uuid, $src.uuid AS src, $tgt.uuid AS tgt, $rel.group_id AS group_id, " *
    "$rel.created_at AS created_at"

# ── mutations ────────────────────────────────────────────────────────────────
# Kùzu MERGE semantics: `MERGE (n:Entity {uuid: '…'}) ON CREATE SET … ON MATCH SET …`

function save_node!(d::KuzuDriver, n::EntityNode)
    params = _entity_node_params(n)
    q = """
    MERGE (n:Entity {uuid: \$uuid})
    ON CREATE SET n.name = \$name, n.name_embedding = \$name_embedding, n.summary = \$summary,
                  n.group_id = \$group_id, n.labels = \$labels, n.attributes = \$attributes,
                  n.created_at = \$created_at
    ON MATCH  SET n.name = \$name, n.name_embedding = \$name_embedding, n.summary = \$summary,
                  n.group_id = \$group_id, n.labels = \$labels, n.attributes = \$attributes,
                  n.created_at = \$created_at
    """
    execute_query(d, q; params = params)
    return n
end

function save_node!(d::KuzuDriver, n::EpisodicNode)
    params = _episodic_node_params(n)
    q = """
    MERGE (n:Episodic {uuid: \$uuid})
    ON CREATE SET n.name = \$name, n.content = \$content, n.content_embedding = \$content_embedding,
                  n.source = \$source, n.source_description = \$source_description,
                  n.valid_at = \$valid_at, n.group_id = \$group_id,
                  n.entity_edges = \$entity_edges, n.saga_uuid = \$saga_uuid,
                  n.created_at = \$created_at
    ON MATCH  SET n.name = \$name, n.content = \$content, n.content_embedding = \$content_embedding,
                  n.source = \$source, n.source_description = \$source_description,
                  n.valid_at = \$valid_at, n.group_id = \$group_id,
                  n.entity_edges = \$entity_edges, n.saga_uuid = \$saga_uuid,
                  n.created_at = \$created_at
    """
    execute_query(d, q; params = params)
    return n
end

function save_node!(d::KuzuDriver, n::CommunityNode)
    params = _community_node_params(n)
    q = """
    MERGE (n:Community {uuid: \$uuid})
    ON CREATE SET n.name = \$name, n.name_embedding = \$name_embedding, n.summary = \$summary,
                  n.group_id = \$group_id, n.created_at = \$created_at
    ON MATCH  SET n.name = \$name, n.name_embedding = \$name_embedding, n.summary = \$summary,
                  n.group_id = \$group_id, n.created_at = \$created_at
    """
    execute_query(d, q; params = params)
    return n
end

function save_node!(d::KuzuDriver, n::SagaNode)
    params = _saga_node_params(n)
    q = """
    MERGE (n:Saga {uuid: \$uuid})
    ON CREATE SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id,
                  n.last_updated = \$last_updated
    ON MATCH  SET n.name = \$name, n.summary = \$summary, n.group_id = \$group_id,
                  n.last_updated = \$last_updated
    """
    execute_query(d, q; params = params)
    return n
end

function save_edge!(d::KuzuDriver, e::EntityEdge)
    params = _entity_edge_params(e)
    q = """
    MATCH (a:Entity {uuid: \$src}), (b:Entity {uuid: \$tgt})
    MERGE (a)-[r:RELATES_TO {uuid: \$uuid}]->(b)
    SET r.name = \$name, r.fact = \$fact, r.fact_embedding = \$fact_embedding,
        r.episodes = \$episodes, r.group_id = \$group_id, r.valid_at = \$valid_at,
        r.invalid_at = \$invalid_at, r.expired_at = \$expired_at,
        r.reference_time = \$reference_time, r.attributes = \$attributes,
        r.created_at = \$created_at
    """
    execute_query(d, q; params = params)
    return e
end

function save_edge!(d::KuzuDriver, e::EpisodicEdge)
    params = _episodic_edge_params(e)
    q = """
    MATCH (a:Episodic {uuid: \$src}), (b:Entity {uuid: \$tgt})
    MERGE (a)-[r:MENTIONS {uuid: \$uuid}]->(b)
    SET r.group_id = \$group_id, r.created_at = \$created_at
    """
    execute_query(d, q; params = params)
    return e
end

function save_edge!(d::KuzuDriver, e::CommunityEdge)
    params = _community_edge_params(e)
    q = """
    MATCH (a:Community {uuid: \$src}), (b:Entity {uuid: \$tgt})
    MERGE (a)-[r:HAS_MEMBER {uuid: \$uuid}]->(b)
    SET r.group_id = \$group_id, r.created_at = \$created_at
    """
    execute_query(d, q; params = params)
    return e
end

# ── deletions ────────────────────────────────────────────────────────────────

function get_node(d::KuzuDriver, uuid::String)
    params = Dict("uuid" => uuid)
    rows = execute_query(d, "MATCH (n:Entity) WHERE n.uuid = \$uuid RETURN $(_kuzu_entity_node_projection())"; params = params)
    !isempty(rows) && return _entity_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Episodic) WHERE n.uuid = \$uuid RETURN $(_kuzu_episodic_node_projection())"; params = params)
    !isempty(rows) && return _episodic_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Community) WHERE n.uuid = \$uuid RETURN $(_kuzu_community_node_projection())"; params = params)
    !isempty(rows) && return _community_node_from_row(rows[1])
    rows = execute_query(d, "MATCH (n:Saga) WHERE n.uuid = \$uuid RETURN $(_kuzu_saga_node_projection())"; params = params)
    !isempty(rows) && return _saga_node_from_row(rows[1])
    return nothing
end

function get_edge(d::KuzuDriver, uuid::String)
    params = Dict("uuid" => uuid)
    rows = execute_query(d,
        "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity) WHERE r.uuid = \$uuid RETURN $(_kuzu_entity_edge_projection())";
        params = params)
    !isempty(rows) && return _entity_edge_from_row(rows[1])
    rows = execute_query(d,
        "MATCH (a:Episodic)-[r:MENTIONS]->(b:Entity) WHERE r.uuid = \$uuid RETURN $(_kuzu_simple_edge_projection())";
        params = params)
    !isempty(rows) && return _episodic_edge_from_row(rows[1])
    rows = execute_query(d,
        "MATCH (a:Community)-[r:HAS_MEMBER]->(b:Entity) WHERE r.uuid = \$uuid RETURN $(_kuzu_simple_edge_projection())";
        params = params)
    !isempty(rows) && return _community_edge_from_row(rows[1])
    return nothing
end

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

function get_entity_nodes(d::KuzuDriver, group_id::String)::Vector{EntityNode}
    q = "MATCH (n:Entity)$(_kuzu_where_group("n", group_id)) RETURN $(_kuzu_entity_node_projection())"
    rows = isempty(group_id) ? execute_query(d, q) : execute_query(d, q; params = Dict("group_id" => group_id))
    return [_entity_node_from_row(r) for r in rows]
end

function get_entity_edges(d::KuzuDriver, group_id::String)::Vector{EntityEdge}
    q = "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity)$(_kuzu_where_group("r", group_id)) RETURN $(_kuzu_entity_edge_projection())"
    rows = isempty(group_id) ? execute_query(d, q) : execute_query(d, q; params = Dict("group_id" => group_id))
    return [_entity_edge_from_row(r) for r in rows]
end

function get_episodic_nodes(d::KuzuDriver, group_id::String)::Vector{EpisodicNode}
    q = "MATCH (n:Episodic)$(_kuzu_where_group("n", group_id)) RETURN $(_kuzu_episodic_node_projection())"
    rows = isempty(group_id) ? execute_query(d, q) : execute_query(d, q; params = Dict("group_id" => group_id))
    return [_episodic_node_from_row(r) for r in rows]
end

function get_latest_episodic_node(d::KuzuDriver, group_id::String)::Union{Nothing,EpisodicNode}
    nodes = get_episodic_nodes(d, group_id)
    isempty(nodes) && return nothing
    return reduce((a, b) -> a.valid_at >= b.valid_at ? a : b, nodes)
end

function get_community_nodes(d::KuzuDriver, group_id::String)::Vector{CommunityNode}
    q = "MATCH (n:Community)$(_kuzu_where_group("n", group_id)) RETURN $(_kuzu_community_node_projection())"
    rows = isempty(group_id) ? execute_query(d, q) :
        execute_query(d, q; params = Dict("group_id" => group_id))
    return [_community_node_from_row(r) for r in rows]
end

function get_community_edges(d::KuzuDriver, group_id::String)::Vector{CommunityEdge}
    q = "MATCH (c:Community)-[r:HAS_MEMBER]->(n:Entity)$(_kuzu_where_group("r", group_id)) RETURN $(_kuzu_simple_edge_projection())"
    rows = isempty(group_id) ? execute_query(d, q) : execute_query(d, q; params = Dict("group_id" => group_id))
    return [_community_edge_from_row(r) for r in rows]
end

function get_saga_nodes(d::KuzuDriver, group_id::String)::Vector{SagaNode}
    q = "MATCH (n:Saga)$(_kuzu_where_group("n", group_id)) RETURN $(_kuzu_saga_node_projection())"
    rows = isempty(group_id) ? execute_query(d, q) :
        execute_query(d, q; params = Dict("group_id" => group_id))
    return [_saga_node_from_row(r) for r in rows]
end

function get_episodes_for_saga(d::KuzuDriver, saga_uuid::String)::Vector{EpisodicNode}
    q = "MATCH (n:Episodic) WHERE n.saga_uuid = \$saga_uuid " *
        "RETURN $(_kuzu_episodic_node_projection())"
    rows = execute_query(d, q; params = Dict("saga_uuid" => saga_uuid))
    return [_episodic_node_from_row(r) for r in rows]
end
