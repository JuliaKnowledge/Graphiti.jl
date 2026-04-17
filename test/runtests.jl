using Test
using Graphiti
using Dates
using JSON3

@testset "Graphiti.jl" begin
    include("test_phase1.jl")
    include("test_phase2.jl")
    include("test_phase3.jl")
    include("test_community.jl")
    include("test_saga.jl")
    include("test_agent_framework_integration.jl")
    include("test_phase6.jl")
    include("test_falkordb.jl")

    # Extension tests — only run if the optional weak dep is installable
    # in the active env. (RDFLib and ACSets pin conflicting DataStructures
    # versions, so they cannot share a test target; CI runs each in its own
    # scratch env and `Pkg.test()` runs whichever is currently resolved.)
    function _try_include(file, pkgname)
        if Base.find_package(pkgname) !== nothing
            include(file)
        else
            @info "Skipping $file: $pkgname not installed in this env"
        end
    end
    _try_include("test_rdflib_ext.jl", "RDFLib")
    _try_include("test_acsets_ext.jl", "ACSets")
    _try_include("test_csql_ext.jl", "CSQL")
    _try_include("test_sst_ext.jl", "SemanticSpacetime")
end
