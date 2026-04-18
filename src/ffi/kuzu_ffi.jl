# Optional libkuzu FFI shim for the Kùzu driver.
#
# This module is included unconditionally but does no work at module-load
# time — every ccall is gated behind `open_connection` (which calls
# `Libdl.dlopen`). Users who never invoke a `KuzuFFI.*` function pay no
# cost and need no libkuzu installed.
#
# Layout mirrors the in-test FFI sketch that previously lived in
# test/test_kuzu_live.jl — it has been promoted here so consumers can
# point a `KuzuDriver` at libkuzu without re-deriving the C API.

"""
    Graphiti.KuzuFFI

Thin `Libdl`/`ccall` shim over libkuzu's C API. Enough surface to back
[`KuzuDriver`](@ref); not a full Kùzu binding.

Typical usage:

```julia
using Graphiti
driver, conn = Graphiti.KuzuFFI.open_driver(
    "/path/to/libkuzu.dylib";
    db_path = "./my_kuzu_db",
    auto_init_schema = true,
)

# … use `driver` like any other Graphiti driver …

Graphiti.KuzuFFI.close!(conn)
```

The connection holds the open libkuzu handles. Closing it — explicitly
or by letting the finalizer fire — releases the database, connection,
and dlopen handle.
"""
module KuzuFFI

using Libdl
using ..Graphiti: KuzuDriver, _kuzu_inline_params, GraphitiKuzuError, init_schema!

# ── kuzu_system_config layout (matches kuzu.h ~line 112) ─────────────────────
# Field order:
#   uint64 buffer_pool_size
#   uint64 max_num_threads
#   bool   enable_compression
#   bool   read_only
#   uint64 max_db_size
#   bool   auto_checkpoint
#   uint64 checkpoint_threshold
#   uint32 thread_qos          (Apple only, but always present in struct)
struct KuzuSystemConfig
    buffer_pool_size::UInt64
    max_num_threads::UInt64
    enable_compression::Bool
    _pad1::UInt8
    _pad2::UInt8
    _pad3::UInt8
    _pad4::UInt8
    _pad5::UInt8
    _pad6::UInt8
    _pad7::UInt8
    read_only::Bool
    _pad8::UInt8
    _pad9::UInt8
    _pad10::UInt8
    _pad11::UInt8
    _pad12::UInt8
    _pad13::UInt8
    _pad14::UInt8
    max_db_size::UInt64
    auto_checkpoint::Bool
    _pad15::UInt8
    _pad16::UInt8
    _pad17::UInt8
    _pad18::UInt8
    _pad19::UInt8
    _pad20::UInt8
    _pad21::UInt8
    checkpoint_threshold::UInt64
    thread_qos::UInt32
end

# Kùzu type IDs we currently decode. Other types fall back to a string
# placeholder; extend `_read_value` if you need richer coverage.
const KUZU_BOOL   = 22
const KUZU_INT64  = 23
const KUZU_DOUBLE = 32
const KUZU_STRING = 50

# ── connection wrapper ───────────────────────────────────────────────────────

"""
    KuzuFFIConnection

Opaque handle bundling a libkuzu dlopen handle and the matching
`kuzu_database` / `kuzu_connection` pointers. Created via
[`open_connection`](@ref); released via [`close!`](@ref) (or its
finalizer at GC time).
"""
mutable struct KuzuFFIConnection
    libhandle::Ptr{Cvoid}
    db::Base.RefValue{NTuple{1, Ptr{Cvoid}}}
    conn::Base.RefValue{NTuple{1, Ptr{Cvoid}}}
    db_path::String
    closed::Bool
end

function _default_system_config(libhandle::Ptr{Cvoid})::KuzuSystemConfig
    return ccall(Libdl.dlsym(libhandle, :kuzu_default_system_config),
                 KuzuSystemConfig, ())
end

"""
    open_connection(libpath, db_path) -> KuzuFFIConnection

`Libdl.dlopen` libkuzu, open or create the database at `db_path`, and
return a connection bundle. Throws [`Graphiti.GraphitiKuzuError`](@ref)
if libkuzu fails to initialise the database or connection.
"""
function open_connection(libpath::AbstractString, db_path::AbstractString)::KuzuFFIConnection
    isfile(libpath) || throw(GraphitiKuzuError("libkuzu not found at $libpath"))
    libhandle = Libdl.dlopen(String(libpath))
    cfg = _default_system_config(libhandle)

    db_buf = Ref{NTuple{1, Ptr{Cvoid}}}((C_NULL,))
    st = ccall(Libdl.dlsym(libhandle, :kuzu_database_init),
               Cint, (Cstring, KuzuSystemConfig, Ptr{Cvoid}),
               String(db_path), cfg, db_buf)
    if st != 0
        Libdl.dlclose(libhandle)
        throw(GraphitiKuzuError("kuzu_database_init failed (state=$st) for $db_path"))
    end

    conn_buf = Ref{NTuple{1, Ptr{Cvoid}}}((C_NULL,))
    st = ccall(Libdl.dlsym(libhandle, :kuzu_connection_init),
               Cint, (Ptr{Cvoid}, Ptr{Cvoid}), db_buf, conn_buf)
    if st != 0
        ccall(Libdl.dlsym(libhandle, :kuzu_database_destroy),
              Cvoid, (Ptr{Cvoid},), db_buf)
        Libdl.dlclose(libhandle)
        throw(GraphitiKuzuError("kuzu_connection_init failed (state=$st)"))
    end

    c = KuzuFFIConnection(libhandle, db_buf, conn_buf, String(db_path), false)
    finalizer(close!, c)
    return c
end

"""
    close!(c::KuzuFFIConnection)

Release the connection, the database, and the libkuzu dlopen handle.
Safe to call multiple times; the finalizer will also call this on GC.
"""
function close!(c::KuzuFFIConnection)
    c.closed && return c
    try
        ccall(Libdl.dlsym(c.libhandle, :kuzu_connection_destroy),
              Cvoid, (Ptr{Cvoid},), c.conn)
        ccall(Libdl.dlsym(c.libhandle, :kuzu_database_destroy),
              Cvoid, (Ptr{Cvoid},), c.db)
    catch
        # Best-effort cleanup; if the handle is already gone we still want
        # to mark the connection closed.
    end
    try
        Libdl.dlclose(c.libhandle)
    catch
    end
    c.closed = true
    return c
end

# ── value decoding ───────────────────────────────────────────────────────────

function _read_value(libhandle::Ptr{Cvoid}, v::Ref)::Any
    if ccall(Libdl.dlsym(libhandle, :kuzu_value_is_null), Bool, (Ptr{Cvoid},), v)
        return nothing
    end
    lt = Ref{NTuple{1, Ptr{Cvoid}}}((C_NULL,))
    ccall(Libdl.dlsym(libhandle, :kuzu_value_get_data_type),
          Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), v, lt)
    tid = ccall(Libdl.dlsym(libhandle, :kuzu_data_type_get_id),
                Cint, (Ptr{Cvoid},), lt)
    ccall(Libdl.dlsym(libhandle, :kuzu_data_type_destroy), Cvoid, (Ptr{Cvoid},), lt)

    if tid == KUZU_STRING
        s = Ref{Cstring}(C_NULL)
        ccall(Libdl.dlsym(libhandle, :kuzu_value_get_string),
              Cint, (Ptr{Cvoid}, Ptr{Cstring}), v, s)
        out = unsafe_string(s[])
        ccall(Libdl.dlsym(libhandle, :kuzu_destroy_string), Cvoid, (Cstring,), s[])
        return out
    elseif tid == KUZU_INT64
        r = Ref{Int64}(0)
        ccall(Libdl.dlsym(libhandle, :kuzu_value_get_int64),
              Cint, (Ptr{Cvoid}, Ptr{Int64}), v, r)
        return r[]
    elseif tid == KUZU_BOOL
        r = Ref{Bool}(false)
        ccall(Libdl.dlsym(libhandle, :kuzu_value_get_bool),
              Cint, (Ptr{Cvoid}, Ptr{Bool}), v, r)
        return r[]
    elseif tid == KUZU_DOUBLE
        r = Ref{Float64}(0.0)
        ccall(Libdl.dlsym(libhandle, :kuzu_value_get_double),
              Cint, (Ptr{Cvoid}, Ptr{Float64}), v, r)
        return r[]
    else
        return "<kuzu type $tid>"
    end
end

# ── query execution ──────────────────────────────────────────────────────────

"""
    execute_cypher(c::KuzuFFIConnection, query::AbstractString) -> Vector{Dict{String,Any}}

Run a Cypher string against the connection's database. Throws
[`Graphiti.GraphitiKuzuError`](@ref) with the libkuzu error message on
failure. Returns one dict per result row, keyed by column name.
"""
function execute_cypher(c::KuzuFFIConnection, query::AbstractString)::Vector{Dict{String,Any}}
    c.closed && throw(GraphitiKuzuError("connection is closed"))
    libhandle = c.libhandle

    # kuzu_query_result is { void* _query_result; bool _is_owned_by_cpp; }
    qr = Ref{NTuple{2, Ptr{Cvoid}}}((C_NULL, C_NULL))
    st = ccall(Libdl.dlsym(libhandle, :kuzu_connection_query),
               Cint, (Ptr{Cvoid}, Cstring, Ptr{Cvoid}),
               c.conn, String(query), qr)
    if st != 0
        err = ccall(Libdl.dlsym(libhandle, :kuzu_query_result_get_error_message),
                    Cstring, (Ptr{Cvoid},), qr)
        msg = err == C_NULL ? "(no message)" : unsafe_string(err)
        if err != C_NULL
            ccall(Libdl.dlsym(libhandle, :kuzu_destroy_string), Cvoid, (Cstring,), err)
        end
        ccall(Libdl.dlsym(libhandle, :kuzu_query_result_destroy),
              Cvoid, (Ptr{Cvoid},), qr)
        throw(GraphitiKuzuError(msg))
    end

    ncols = ccall(Libdl.dlsym(libhandle, :kuzu_query_result_get_num_columns),
                  UInt64, (Ptr{Cvoid},), qr)
    cols = String[]
    for i in 0:Int(ncols)-1
        cn = Ref{Cstring}(C_NULL)
        ccall(Libdl.dlsym(libhandle, :kuzu_query_result_get_column_name),
              Cint, (Ptr{Cvoid}, UInt64, Ptr{Cstring}), qr, UInt64(i), cn)
        push!(cols, unsafe_string(cn[]))
        ccall(Libdl.dlsym(libhandle, :kuzu_destroy_string), Cvoid, (Cstring,), cn[])
    end

    rows = Dict{String,Any}[]
    while ccall(Libdl.dlsym(libhandle, :kuzu_query_result_has_next),
                Bool, (Ptr{Cvoid},), qr)
        ft = Ref{NTuple{2, Ptr{Cvoid}}}((C_NULL, C_NULL))
        ccall(Libdl.dlsym(libhandle, :kuzu_query_result_get_next),
              Cint, (Ptr{Cvoid}, Ptr{Cvoid}), qr, ft)
        row = Dict{String,Any}()
        for i in 0:Int(ncols)-1
            v = Ref{NTuple{2, Ptr{Cvoid}}}((C_NULL, C_NULL))
            ccall(Libdl.dlsym(libhandle, :kuzu_flat_tuple_get_value),
                  Cint, (Ptr{Cvoid}, UInt64, Ptr{Cvoid}), ft, UInt64(i), v)
            row[cols[i+1]] = _read_value(libhandle, v)
            ccall(Libdl.dlsym(libhandle, :kuzu_value_destroy), Cvoid, (Ptr{Cvoid},), v)
        end
        push!(rows, row)
        ccall(Libdl.dlsym(libhandle, :kuzu_flat_tuple_destroy), Cvoid, (Ptr{Cvoid},), ft)
    end

    ccall(Libdl.dlsym(libhandle, :kuzu_query_result_destroy), Cvoid, (Ptr{Cvoid},), qr)
    return rows
end

# ── KuzuDriver glue ──────────────────────────────────────────────────────────

"""
    make_query_fn(c::KuzuFFIConnection) -> Function

Build a closure suitable for `KuzuDriver(_query_fn = …)`. The returned
function inlines `\$param` placeholders via
[`Graphiti._kuzu_inline_params`](@ref) before handing the query to
libkuzu.
"""
function make_query_fn(c::KuzuFFIConnection)::Function
    return (drv, query::String, params::Dict) -> begin
        full = _kuzu_inline_params(query, params)
        return execute_cypher(c, full)
    end
end

"""
    open_driver(libpath; db_path=mktempdir()/kuzu_db, auto_init_schema=true)
        -> (driver::KuzuDriver, conn::KuzuFFIConnection)

One-liner that opens libkuzu, creates the database directory if it does
not exist, wires the connection into a fresh [`KuzuDriver`](@ref), and
optionally runs [`init_schema!`](@ref). Returns both the driver (for
queries) and the connection (so the caller can [`close!`](@ref) it).
"""
function open_driver(libpath::AbstractString;
                     db_path::AbstractString = joinpath(mktempdir(), "kuzu_db"),
                     auto_init_schema::Bool = true)
    conn = open_connection(libpath, db_path)
    qfn = make_query_fn(conn)
    driver = KuzuDriver(db_path = String(db_path), _query_fn = qfn,
                        auto_init_schema = auto_init_schema)
    return driver, conn
end

end # module KuzuFFI
