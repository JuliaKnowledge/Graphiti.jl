# Kùzu

Graphiti.jl ships an in-core driver for [Kùzu](https://kuzudb.com), an
embedded property-graph database that speaks a Cypher dialect. The driver
mirrors the `Neo4jDriver` and `FalkorDBDriver` API surface and uses the
same injectable-transport pattern: you supply a `_query_fn` that talks to
libkuzu, and the rest of the driver works the same as for any other
backend.

## Why an injectable backend?

There is no native Julia client for Kùzu yet. Rather than ship a
`Libdl`/`ccall` binding that forces every Graphiti.jl user to install
libkuzu, the driver delegates the actual query execution to a function
of your choice. This keeps Graphiti.jl light and lets you wire in
whichever Kùzu transport you prefer (FFI to libkuzu, an external
microservice, the Python client over `PyCall`, etc.).

## Quick start

```julia
using Graphiti

# Stub backend — useful for tests / dry-runs:
fake_query = (drv, q, params) -> Dict{String,Any}[]

driver = KuzuDriver(
    db_path  = "./my_kuzu_db",
    _query_fn = fake_query,
    auto_init_schema = true,
)
```

## Schema

Kùzu requires `CREATE NODE TABLE` / `CREATE REL TABLE` statements before
nodes/edges can be inserted. The driver provides a built-in schema that
matches Graphiti's domain model:

| Table        | Kind | Definition |
|--------------|------|------------|
| `Entity`     | NODE | `uuid PK, name, summary, group_id` |
| `Episodic`   | NODE | `uuid PK, name, content, group_id, saga_uuid` |
| `Community`  | NODE | `uuid PK, name, summary, group_id` |
| `Saga`       | NODE | `uuid PK, name, summary, group_id` |
| `RELATES_TO` | REL  | Entity → Entity, `uuid, name, fact, group_id` |
| `MENTIONS`   | REL  | Episodic → Entity, `uuid, group_id` |
| `HAS_MEMBER` | REL  | Community → Entity, `uuid, group_id` |

Call `init_schema!(driver)` once on a fresh database, or pass
`auto_init_schema = true` when constructing the driver. Both paths use
`CREATE … IF NOT EXISTS` and are safe to run repeatedly.

## Mutations

```julia
save_node!(driver, EntityNode(uuid="u1", name="Alice", summary="…", group_id="g1"))
save_node!(driver, EpisodicNode(uuid="e1", name="ep", content="…", group_id="g1"))
save_edge!(driver, EntityEdge(uuid="r1",
    source_node_uuid="u1", target_node_uuid="u2",
    name="knows", fact="Alice knows Bob", group_id="g1"))

delete_node!(driver, "u1")
delete_edge!(driver, "r1")

clear!(driver)   # drops all rel + node tables and recreates the schema
```

## Parameters

Kùzu supports parameter binding only through its prepared-statement API.
The default `_query_fn` path therefore inlines `\$param` placeholders
into the query text using `_kuzu_inline_params`, which:

* Escapes single quotes (`O'Reilly` → `'O\\'Reilly'`)
* Encodes `Bool` as `true`/`false`, `nothing` as `NULL`, vectors as
  `[…]`, and numbers verbatim.
* Substitutes longest names first so `\$ab` does not match inside
  `\$abc`.

If you wire `_query_fn` to a real `kuzu_prepared_statement` call, you
can ignore the inliner and bind params natively.

## Connecting libkuzu via FFI (recommended)

Graphiti.jl ships an optional [`Graphiti.KuzuFFI`](@ref) submodule that
wraps just enough of libkuzu's C API to back a `KuzuDriver`. It does
nothing at module-load time — the `Libdl.dlopen` happens only when you
call `KuzuFFI.open_driver(...)`, so users without libkuzu installed pay
no cost.

```julia
using Graphiti

driver, conn = Graphiti.KuzuFFI.open_driver(
    "/path/to/libkuzu.dylib";
    db_path = "./my_kuzu_db",
    auto_init_schema = true,
)

save_node!(driver, EntityNode(uuid="u1", name="Alice",
                                summary="", group_id="g"))
rows = execute_query(driver, "MATCH (n:Entity) RETURN n.name AS name")

Graphiti.KuzuFFI.close!(conn)   # release libkuzu handles
```

Public API:

| Symbol | Purpose |
|--------|---------|
| `KuzuFFI.open_connection(libpath, db_path)` | Low-level: open libkuzu, create the database, return a `KuzuFFIConnection`. |
| `KuzuFFI.close!(conn)` | Release the connection, the database, and the dlopen handle. Idempotent; also runs from a finalizer. |
| `KuzuFFI.execute_cypher(conn, query)` | Run a Cypher string and return `Vector{Dict{String,Any}}`. |
| `KuzuFFI.make_query_fn(conn)` | Build a closure suitable for `KuzuDriver(_query_fn = …)`. |
| `KuzuFFI.open_driver(libpath; db_path, auto_init_schema)` | One-liner that does all of the above. |

Currently decoded Kùzu types: `BOOL`, `INT64`, `DOUBLE`, `STRING`. Other
column types appear in result rows as `"<kuzu type N>"` placeholders;
extend `KuzuFFI._read_value` if you need richer coverage.

### Rolling your own backend

Because `KuzuDriver` only requires a `_query_fn`, you can bypass
`KuzuFFI` entirely — wire it to an external microservice, the Python
client over `PyCall`, or your own ccall layer. The minimum signature:

```julia
function my_kuzu_query(drv::KuzuDriver, query::String, params::Dict)
    full = Graphiti._kuzu_inline_params(query, params)
    # … hand `full` to your transport, return Vector{Dict{String,Any}} …
end

driver = KuzuDriver(db_path="./db", _query_fn=my_kuzu_query, auto_init_schema=true)
```

See the [official C API reference](https://docs.kuzudb.com/c/) for the
full function signatures, or [`Graphiti.KuzuFFI`'s source](https://github.com/JuliaKnowledge/Graphiti.jl/blob/main/src/ffi/kuzu_ffi.jl)
for a working example.

## Testing without libkuzu

All driver methods accept a stub `_query_fn`, so you can exercise the
full mutation/read surface in unit tests with no native dependencies:

```julia
issued = String[]
stub = (drv, q, p) -> (push!(issued, q); Dict{String,Any}[])
driver = KuzuDriver(_query_fn = stub)

save_node!(driver, EntityNode(uuid="u1", name="Alice",
                               summary="", group_id="g"))
@test occursin("MERGE (n:Entity", issued[end])
```

This is exactly how Graphiti.jl's own test suite covers the driver
(see `test/test_kuzu.jl`).

## Errors

The default backend raises `Graphiti.GraphitiKuzuError` if you forget to
provide a `_query_fn`. `clear!` swallows `GraphitiKuzuError` thrown by
`DROP TABLE` (so missing tables are fine) but re-raises any other
exception.
