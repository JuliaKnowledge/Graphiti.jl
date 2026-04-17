"""Embedder abstraction with random and deterministic implementations."""

abstract type AbstractEmbedder end

embed(e::AbstractEmbedder, text::String)::Vector{Float64} =
    error("embed not implemented for $(typeof(e))")

struct RandomEmbedder <: AbstractEmbedder
    dim::Int
end

RandomEmbedder() = RandomEmbedder(128)

function embed(e::RandomEmbedder, text::String)::Vector{Float64}
    v = randn(Float64, e.dim)
    n = sqrt(sum(v .^ 2))
    return n > 0 ? v ./ n : v
end

struct DeterministicEmbedder <: AbstractEmbedder
    embeddings::Dict{String, Vector{Float64}}
    dim::Int
end

DeterministicEmbedder(dim::Int = 4) = DeterministicEmbedder(Dict{String, Vector{Float64}}(), dim)

function embed(e::DeterministicEmbedder, text::String)::Vector{Float64}
    if haskey(e.embeddings, text)
        return e.embeddings[text]
    end
    seed = UInt32(hash(text) & typemax(UInt32))
    rng = Random.MersenneTwister(seed)
    v = randn(rng, Float64, e.dim)
    n = sqrt(sum(v .^ 2))
    return n > 0 ? v ./ n : v
end
