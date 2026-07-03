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

# ── kuzu C ABI mirrors ────────────────────────────────────────────────────────

@static if Sys.isapple()
struct KuzuSystemConfig
    buffer_pool_size::UInt64
    max_num_threads::UInt64
    enable_compression::Bool
    read_only::Bool
    _pad1::NTuple{6, UInt8}
    max_db_size::UInt64
    auto_checkpoint::Bool
    _pad2::NTuple{7, UInt8}
    checkpoint_threshold::UInt64
    thread_qos::UInt32
    _pad3::NTuple{4, UInt8}
end
else
struct KuzuSystemConfig
    buffer_pool_size::UInt64
    max_num_threads::UInt64
    enable_compression::Bool
    read_only::Bool
    _pad1::NTuple{6, UInt8}
    max_db_size::UInt64
    auto_checkpoint::Bool
    _pad2::NTuple{7, UInt8}
    checkpoint_threshold::UInt64
end
end

struct KuzuDatabase
    _database::Ptr{Cvoid}
end

struct KuzuConnection
    _connection::Ptr{Cvoid}
end

struct KuzuQueryResult
    _query_result::Ptr{Cvoid}
    _is_owned_by_cpp::Bool
end

struct KuzuFlatTuple
    _flat_tuple::Ptr{Cvoid}
    _is_owned_by_cpp::Bool
end

struct KuzuLogicalType
    _data_type::Ptr{Cvoid}
end

struct KuzuValue
    _value::Ptr{Cvoid}
    _is_owned_by_cpp::Bool
end

const KUZU_SUCCESS = 0
const KUZU_BOOL   = 22
const KUZU_INT64  = 23
const KUZU_INT32  = 24
const KUZU_UINT64 = 27
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
    symbols::Dict{Symbol, Ptr{Cvoid}}
    db::Base.RefValue{KuzuDatabase}
    conn::Base.RefValue{KuzuConnection}
    db_path::String
    closed::Bool
end

_is_open(handle::Ptr{Cvoid}) = handle != C_NULL
_is_open(db::KuzuDatabase) = _is_open(db._database)
_is_open(conn::KuzuConnection) = _is_open(conn._connection)
_is_open(qr::KuzuQueryResult) = _is_open(qr._query_result)
_is_open(ft::KuzuFlatTuple) = _is_open(ft._flat_tuple)
_is_open(v::KuzuValue) = _is_open(v._value)
_is_open(t::KuzuLogicalType) = _is_open(t._data_type)

function _sym(c::KuzuFFIConnection, name::Symbol)::Ptr{Cvoid}
    return get!(c.symbols, name) do
        Libdl.dlsym(c.libhandle, name)
    end
end

function _default_system_config(libhandle::Ptr{Cvoid}, symbols::Dict{Symbol, Ptr{Cvoid}})::KuzuSystemConfig
    fn = get!(symbols, :kuzu_default_system_config) do
        Libdl.dlsym(libhandle, :kuzu_default_system_config)
    end
    return ccall(fn, KuzuSystemConfig, ())
end

function _check_status(status::Integer, context::AbstractString)
    status == KUZU_SUCCESS && return nothing
    throw(GraphitiKuzuError("$context (state=$status)"))
end

function _take_kuzu_string(c::KuzuFFIConnection, ptr::Cstring)::String
    ptr == C_NULL && throw(GraphitiKuzuError("libkuzu returned a null string pointer"))
    try
        return unsafe_string(ptr)
    finally
        ccall(_sym(c, :kuzu_destroy_string), Cvoid, (Cstring,), ptr)
    end
end

function _query_error_message(c::KuzuFFIConnection, qr::Base.RefValue{KuzuQueryResult})::String
    !_is_open(qr[]) && return "(no query-result error message available)"
    err_ptr = ccall(_sym(c, :kuzu_query_result_get_error_message), Cstring,
        (Ref{KuzuQueryResult},), qr)
    err_ptr == C_NULL && return "(no query-result error message available)"
    return _take_kuzu_string(c, err_ptr)
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
    symbols = Dict{Symbol, Ptr{Cvoid}}()
    cfg = _default_system_config(libhandle, symbols)

    db_ref = Ref(KuzuDatabase(C_NULL))
    try
        st = ccall(get!(symbols, :kuzu_database_init) do
                Libdl.dlsym(libhandle, :kuzu_database_init)
            end,
            Cint,
            (Cstring, KuzuSystemConfig, Ref{KuzuDatabase}),
            String(db_path), cfg, db_ref,
        )
        _check_status(st, "kuzu_database_init failed for $db_path")

        conn_ref = Ref(KuzuConnection(C_NULL))
        try
            st = ccall(get!(symbols, :kuzu_connection_init) do
                    Libdl.dlsym(libhandle, :kuzu_connection_init)
                end,
                Cint,
                (Ref{KuzuDatabase}, Ref{KuzuConnection}),
                db_ref, conn_ref,
            )
            _check_status(st, "kuzu_connection_init failed")

            c = KuzuFFIConnection(libhandle, symbols, db_ref, conn_ref, String(db_path), false)
            finalizer(close!, c)
            return c
        catch
            if _is_open(db_ref[])
                ccall(get!(symbols, :kuzu_database_destroy) do
                        Libdl.dlsym(libhandle, :kuzu_database_destroy)
                    end,
                    Cvoid, (Ref{KuzuDatabase},), db_ref)
            end
            rethrow()
        end
    catch
        try
            Libdl.dlclose(libhandle)
        catch
        end
        rethrow()
    end
end

"""
    close!(c::KuzuFFIConnection)

Release the connection, the database, and the libkuzu dlopen handle.
Safe to call multiple times; the finalizer will also call this on GC.
"""
function close!(c::KuzuFFIConnection)
    c.closed && return c
    try
        if _is_open(c.conn[])
            ccall(_sym(c, :kuzu_connection_destroy), Cvoid, (Ref{KuzuConnection},), c.conn)
            c.conn[] = KuzuConnection(C_NULL)
        end
        if _is_open(c.db[])
            ccall(_sym(c, :kuzu_database_destroy), Cvoid, (Ref{KuzuDatabase},), c.db)
            c.db[] = KuzuDatabase(C_NULL)
        end
    catch
    end
    try
        Libdl.dlclose(c.libhandle)
    catch
    end
    c.closed = true
    return c
end

# ── value decoding ───────────────────────────────────────────────────────────

function _read_value(c::KuzuFFIConnection, value_ref::Base.RefValue{KuzuValue})::Any
    !_is_open(value_ref[]) && return nothing
    if ccall(_sym(c, :kuzu_value_is_null), Bool, (Ref{KuzuValue},), value_ref)
        return nothing
    end

    type_ref = Ref(KuzuLogicalType(C_NULL))
    ccall(_sym(c, :kuzu_value_get_data_type), Cvoid,
        (Ref{KuzuValue}, Ref{KuzuLogicalType}), value_ref, type_ref)
    try
        tid = ccall(_sym(c, :kuzu_data_type_get_id), Cint,
            (Ref{KuzuLogicalType},), type_ref)
        if tid == KUZU_STRING
            str_ref = Ref{Cstring}(C_NULL)
            st = ccall(_sym(c, :kuzu_value_get_string), Cint,
                (Ref{KuzuValue}, Ref{Cstring}), value_ref, str_ref)
            _check_status(st, "kuzu_value_get_string failed")
            str_ref[] == C_NULL && throw(GraphitiKuzuError("kuzu_value_get_string returned null"))
            return _take_kuzu_string(c, str_ref[])
        elseif tid == KUZU_INT64
            out = Ref{Int64}(0)
            st = ccall(_sym(c, :kuzu_value_get_int64), Cint,
                (Ref{KuzuValue}, Ref{Int64}), value_ref, out)
            _check_status(st, "kuzu_value_get_int64 failed")
            return out[]
        elseif tid == KUZU_INT32
            out = Ref{Int32}(0)
            st = ccall(_sym(c, :kuzu_value_get_int32), Cint,
                (Ref{KuzuValue}, Ref{Int32}), value_ref, out)
            _check_status(st, "kuzu_value_get_int32 failed")
            return out[]
        elseif tid == KUZU_UINT64
            out = Ref{UInt64}(0)
            st = ccall(_sym(c, :kuzu_value_get_uint64), Cint,
                (Ref{KuzuValue}, Ref{UInt64}), value_ref, out)
            _check_status(st, "kuzu_value_get_uint64 failed")
            return Int64(out[])
        elseif tid == KUZU_BOOL
            out = Ref{Bool}(false)
            st = ccall(_sym(c, :kuzu_value_get_bool), Cint,
                (Ref{KuzuValue}, Ref{Bool}), value_ref, out)
            _check_status(st, "kuzu_value_get_bool failed")
            return out[]
        elseif tid == KUZU_DOUBLE
            out = Ref{Float64}(0.0)
            st = ccall(_sym(c, :kuzu_value_get_double), Cint,
                (Ref{KuzuValue}, Ref{Float64}), value_ref, out)
            _check_status(st, "kuzu_value_get_double failed")
            return out[]
        else
            return "<kuzu type $tid>"
        end
    finally
        if _is_open(type_ref[])
            ccall(_sym(c, :kuzu_data_type_destroy), Cvoid, (Ref{KuzuLogicalType},), type_ref)
        end
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

    qr = Ref(KuzuQueryResult(C_NULL, false))
    st = ccall(_sym(c, :kuzu_connection_query), Cint,
        (Ref{KuzuConnection}, Cstring, Ref{KuzuQueryResult}),
        c.conn, String(query), qr)
    if st != KUZU_SUCCESS
        msg = _query_error_message(c, qr)
        _is_open(qr[]) && ccall(_sym(c, :kuzu_query_result_destroy), Cvoid, (Ref{KuzuQueryResult},), qr)
        throw(GraphitiKuzuError(msg))
    end

    try
        ncols = ccall(_sym(c, :kuzu_query_result_get_num_columns), UInt64,
            (Ref{KuzuQueryResult},), qr)
        cols = String[]
        for i in 0:Int(ncols)-1
            name_ref = Ref{Cstring}(C_NULL)
            st = ccall(_sym(c, :kuzu_query_result_get_column_name), Cint,
                (Ref{KuzuQueryResult}, UInt64, Ref{Cstring}), qr, UInt64(i), name_ref)
            _check_status(st, "kuzu_query_result_get_column_name failed for column $(i + 1)")
            name_ref[] == C_NULL && throw(GraphitiKuzuError("kuzu_query_result_get_column_name returned null"))
            push!(cols, _take_kuzu_string(c, name_ref[]))
        end

        rows = Dict{String,Any}[]
        while ccall(_sym(c, :kuzu_query_result_has_next), Bool, (Ref{KuzuQueryResult},), qr)
            tuple_ref = Ref(KuzuFlatTuple(C_NULL, false))
            st = ccall(_sym(c, :kuzu_query_result_get_next), Cint,
                (Ref{KuzuQueryResult}, Ref{KuzuFlatTuple}), qr, tuple_ref)
            _check_status(st, "kuzu_query_result_get_next failed")
            try
                row = Dict{String,Any}()
                for i in 0:Int(ncols)-1
                    value_ref = Ref(KuzuValue(C_NULL, false))
                    st = ccall(_sym(c, :kuzu_flat_tuple_get_value), Cint,
                        (Ref{KuzuFlatTuple}, UInt64, Ref{KuzuValue}), tuple_ref, UInt64(i), value_ref)
                    _check_status(st, "kuzu_flat_tuple_get_value failed for column $(i + 1)")
                    try
                        row[cols[i + 1]] = _read_value(c, value_ref)
                    finally
                        if _is_open(value_ref[])
                            ccall(_sym(c, :kuzu_value_destroy), Cvoid, (Ref{KuzuValue},), value_ref)
                        end
                    end
                end
                push!(rows, row)
            finally
                if _is_open(tuple_ref[])
                    ccall(_sym(c, :kuzu_flat_tuple_destroy), Cvoid, (Ref{KuzuFlatTuple},), tuple_ref)
                end
            end
        end
        return rows
    finally
        if _is_open(qr[])
            ccall(_sym(c, :kuzu_query_result_destroy), Cvoid, (Ref{KuzuQueryResult},), qr)
        end
    end
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
    open_driver(libpath; db_path=joinpath(pwd(), "kuzu_db"), auto_init_schema=true)
        -> (driver::KuzuDriver, conn::KuzuFFIConnection)

One-liner that opens libkuzu, creates the database directory if it does
not exist, wires the connection into a fresh [`KuzuDriver`](@ref), and
optionally runs [`init_schema!`](@ref). Returns both the driver (for
queries) and the connection (so the caller can [`close!`](@ref) it).
"""
function open_driver(libpath::AbstractString;
                     db_path::AbstractString = joinpath(pwd(), "kuzu_db"),
                     auto_init_schema::Bool = true)
    mkpath(dirname(String(db_path)))
    conn = open_connection(libpath, db_path)
    qfn = make_query_fn(conn)
    driver = KuzuDriver(db_path = String(db_path), _query_fn = qfn,
                        auto_init_schema = auto_init_schema)
    return driver, conn
end

end # module KuzuFFI
