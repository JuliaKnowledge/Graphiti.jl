using Test
using Graphiti
using Dates
using JSON3

@testset "Graphiti.jl" begin
    include("test_phase1.jl")
    include("test_phase2.jl")
    include("test_phase3.jl")
end
