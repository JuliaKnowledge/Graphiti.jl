# Live integration test for KuzuDriver via libkuzu FFI.
#
# Requires libkuzu.dylib (Mac) / libkuzu.so (Linux). Download from:
#   https://github.com/kuzudb/kuzu/releases
# Then set:
#   KUZU_LIVE=1
#   KUZU_LIB=/path/to/libkuzu.dylib   (or .so)
#
# The test exercises a real round-trip through ccall + the C API.

using Test
using Graphiti
using Libdl

if get(ENV, "KUZU_LIVE", "") != "1"
    @info "Skipping live Kùzu tests (set KUZU_LIVE=1 and KUZU_LIB=/path/to/libkuzu.{so,dylib})"
else
    libpath = get(ENV, "KUZU_LIB", "")
    isempty(libpath) && error("KUZU_LIB must point to libkuzu.{so,dylib}")
    LIBKUZU = Libdl.dlopen(libpath)

    # ── Minimal mirror of kuzu.h structs ─────────────────────────────────────
    # kuzu_database / kuzu_connection / kuzu_query_result / kuzu_flat_tuple /
    # kuzu_logical_type / kuzu_value all start with a void* and (for a few)
    # an additional bool. We allocate them on the Julia side as Ref{NTuple}.

    # kuzu_system_config layout (matches kuzu.h ~line 112):
    #   uint64 buffer_pool_size
    #   uint64 max_num_threads
    #   bool   enable_compression
    #   bool   read_only
    #   uint64 max_db_size
    #   bool   auto_checkpoint
    #   uint64 checkpoint_threshold
    #   uint32 thread_qos          (Apple only)
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

    # Use kuzu_default_system_config() for portable initialisation
    default_cfg() = ccall(Libdl.dlsym(LIBKUZU, :kuzu_default_system_config),
                          KuzuSystemConfig, ())

    # Type-tag enum values we care about
    const KUZU_BOOL   = 22
    const KUZU_INT64  = 23
    const KUZU_DOUBLE = 32
    const KUZU_STRING = 50

    # ── ccall helpers ────────────────────────────────────────────────────────
    # Database/connection/query_result are 1- or 2-pointer structs; we
    # allocate as pointer-sized buffers and pass &buf.

    function kuzu_open(path::String)
        cfg = default_cfg()
        db_buf = Ref{NTuple{1, Ptr{Cvoid}}}((C_NULL,))
        st = ccall(Libdl.dlsym(LIBKUZU, :kuzu_database_init),
                   Cint, (Cstring, KuzuSystemConfig, Ptr{Cvoid}),
                   path, cfg, db_buf)
        st == 0 || error("kuzu_database_init failed: state=$st")
        return db_buf
    end

    function kuzu_connect(db_buf)
        conn_buf = Ref{NTuple{1, Ptr{Cvoid}}}((C_NULL,))
        st = ccall(Libdl.dlsym(LIBKUZU, :kuzu_connection_init),
                   Cint, (Ptr{Cvoid}, Ptr{Cvoid}), db_buf, conn_buf)
        st == 0 || error("kuzu_connection_init failed: state=$st")
        return conn_buf
    end

    """Return Vector{Dict{String,Any}} from a query."""
    function run_cypher(conn_buf, query::String)::Vector{Dict{String,Any}}
        # kuzu_query_result is { void* _query_result; bool _is_owned_by_cpp; }
        qr = Ref{NTuple{2, Ptr{Cvoid}}}((C_NULL, C_NULL))
        st = ccall(Libdl.dlsym(LIBKUZU, :kuzu_connection_query),
                   Cint, (Ptr{Cvoid}, Cstring, Ptr{Cvoid}),
                   conn_buf, query, qr)
        if st != 0
            err = ccall(Libdl.dlsym(LIBKUZU, :kuzu_query_result_get_error_message),
                        Cstring, (Ptr{Cvoid},), qr)
            msg = err == C_NULL ? "(no message)" : unsafe_string(err)
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_destroy_string), Cvoid, (Cstring,), err)
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_query_result_destroy),
                  Cvoid, (Ptr{Cvoid},), qr)
            throw(Graphiti.GraphitiKuzuError(msg))
        end

        ncols = ccall(Libdl.dlsym(LIBKUZU, :kuzu_query_result_get_num_columns),
                      UInt64, (Ptr{Cvoid},), qr)
        cols = String[]
        for i in 0:Int(ncols)-1
            cn = Ref{Cstring}(C_NULL)
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_query_result_get_column_name),
                  Cint, (Ptr{Cvoid}, UInt64, Ptr{Cstring}), qr, UInt64(i), cn)
            push!(cols, unsafe_string(cn[]))
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_destroy_string), Cvoid, (Cstring,), cn[])
        end

        rows = Dict{String,Any}[]
        while ccall(Libdl.dlsym(LIBKUZU, :kuzu_query_result_has_next),
                    Bool, (Ptr{Cvoid},), qr)
            ft = Ref{NTuple{2, Ptr{Cvoid}}}((C_NULL, C_NULL))
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_query_result_get_next),
                  Cint, (Ptr{Cvoid}, Ptr{Cvoid}), qr, ft)
            row = Dict{String,Any}()
            for i in 0:Int(ncols)-1
                v = Ref{NTuple{2, Ptr{Cvoid}}}((C_NULL, C_NULL))
                ccall(Libdl.dlsym(LIBKUZU, :kuzu_flat_tuple_get_value),
                      Cint, (Ptr{Cvoid}, UInt64, Ptr{Cvoid}), ft, UInt64(i), v)
                row[cols[i+1]] = _read_value(v)
                ccall(Libdl.dlsym(LIBKUZU, :kuzu_value_destroy), Cvoid, (Ptr{Cvoid},), v)
            end
            push!(rows, row)
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_flat_tuple_destroy), Cvoid, (Ptr{Cvoid},), ft)
        end

        ccall(Libdl.dlsym(LIBKUZU, :kuzu_query_result_destroy), Cvoid, (Ptr{Cvoid},), qr)
        return rows
    end

    function _read_value(v)
        if ccall(Libdl.dlsym(LIBKUZU, :kuzu_value_is_null), Bool, (Ptr{Cvoid},), v)
            return nothing
        end
        lt = Ref{NTuple{1, Ptr{Cvoid}}}((C_NULL,))
        ccall(Libdl.dlsym(LIBKUZU, :kuzu_value_get_data_type),
              Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), v, lt)
        tid = ccall(Libdl.dlsym(LIBKUZU, :kuzu_data_type_get_id),
                    Cint, (Ptr{Cvoid},), lt)
        ccall(Libdl.dlsym(LIBKUZU, :kuzu_data_type_destroy), Cvoid, (Ptr{Cvoid},), lt)
        if tid == KUZU_STRING
            s = Ref{Cstring}(C_NULL)
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_value_get_string),
                  Cint, (Ptr{Cvoid}, Ptr{Cstring}), v, s)
            out = unsafe_string(s[])
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_destroy_string), Cvoid, (Cstring,), s[])
            return out
        elseif tid == KUZU_INT64
            r = Ref{Int64}(0)
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_value_get_int64),
                  Cint, (Ptr{Cvoid}, Ptr{Int64}), v, r)
            return r[]
        elseif tid == KUZU_BOOL
            r = Ref{Bool}(false)
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_value_get_bool),
                  Cint, (Ptr{Cvoid}, Ptr{Bool}), v, r)
            return r[]
        elseif tid == KUZU_DOUBLE
            r = Ref{Float64}(0.0)
            ccall(Libdl.dlsym(LIBKUZU, :kuzu_value_get_double),
                  Cint, (Ptr{Cvoid}, Ptr{Float64}), v, r)
            return r[]
        else
            return "<kuzu type $tid>"
        end
    end

    # ── Plug into KuzuDriver ────────────────────────────────────────────────
    db_path = joinpath(mktempdir(), "kuzu_live_db")
    db   = kuzu_open(db_path)
    conn = kuzu_connect(db)

    try
        ffi_query = (drv, q, params) -> begin
            full = Graphiti._kuzu_inline_params(q, params)
            return run_cypher(conn, full)
        end
        d = KuzuDriver(db_path = db_path, _query_fn = ffi_query, auto_init_schema = true)

        @testset "KuzuDriver — live (libkuzu FFI)" begin
            @test d.schema_initialized == true

            # Sanity: simple RETURN
            rows = execute_query(d, "RETURN 1 AS x")
            @test length(rows) == 1
            @test get(rows[1], "x", nothing) == 1

            # Mutations
            save_node!(d, EntityNode(uuid="a", name="Alice", summary="person", group_id="g1"))
            save_node!(d, EntityNode(uuid="b", name="Bob",   summary="person", group_id="g1"))
            save_edge!(d, EntityEdge(uuid="r1", source_node_uuid="a",
                                     target_node_uuid="b", name="knows",
                                     fact="Alice knows Bob", group_id="g1"))

            rows = execute_query(d,
                "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity) " *
                "WHERE a.uuid = \$u " *
                "RETURN r.fact AS fact, b.name AS name";
                params = Dict("u" => "a"),
            )
            @test length(rows) == 1
            @test rows[1]["fact"] == "Alice knows Bob"
            @test rows[1]["name"] == "Bob"

            # String-escape via inliner against a real engine
            save_node!(d, EntityNode(uuid="o", name="O'Reilly",
                                     summary="publisher", group_id="g1"))
            rows = execute_query(d,
                "MATCH (n:Entity) WHERE n.uuid = \$u RETURN n.name AS name";
                params = Dict("u" => "o"),
            )
            @test rows[1]["name"] == "O'Reilly"

            # Communities + reads
            save_node!(d, CommunityNode(uuid="c1", name="Friends",
                                         summary="", group_id="g1"))
            save_edge!(d, CommunityEdge(uuid="h1", source_node_uuid="c1",
                                         target_node_uuid="a",  group_id="g1"))
            comms = get_community_nodes(d, "g1")
            @test length(comms) == 1
            @test comms[1].name == "Friends"
            cedges = get_community_edges(d, "c1")
            @test length(cedges) == 1
            @test cedges[1].target_node_uuid == "a"

            # Saga + episode
            save_node!(d, SagaNode(uuid="s1", name="Sprint", summary="",
                                    group_id="g1"))
            sagas = get_saga_nodes(d, "g1")
            @test length(sagas) == 1
            @test sagas[1].name == "Sprint"

            # Deletion
            delete_edge!(d, "r1")
            rows = execute_query(d,
                "MATCH ()-[r:RELATES_TO]->() WHERE r.uuid = \$u RETURN count(r) AS c";
                params = Dict("u" => "r1"),
            )
            @test rows[1]["c"] == 0

            delete_node!(d, "b")
            rows = execute_query(d,
                "MATCH (n:Entity) WHERE n.uuid = \$u RETURN count(n) AS c";
                params = Dict("u" => "b"),
            )
            @test rows[1]["c"] == 0

            # clear! drops everything and recreates schema
            clear!(d)
            rows = execute_query(d, "MATCH (n:Entity) RETURN count(n) AS c")
            @test rows[1]["c"] == 0
            @test d.schema_initialized == true
        end
    finally
        ccall(Libdl.dlsym(LIBKUZU, :kuzu_connection_destroy), Cvoid, (Ptr{Cvoid},), conn)
        ccall(Libdl.dlsym(LIBKUZU, :kuzu_database_destroy),   Cvoid, (Ptr{Cvoid},), db)
    end
end
