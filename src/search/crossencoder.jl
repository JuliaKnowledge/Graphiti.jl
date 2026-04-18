"""Cross-encoder rerankers for reordering search results.

The `AbstractCrossEncoder` type is declared in `types.jl` so that
`SearchConfig` can reference it.  Concrete implementations live here.
"""

"""
    rerank(encoder::AbstractCrossEncoder, query::String, documents::Vector{String}) -> Vector{Float64}

Score each `document` against `query` and return one relevance score per
document (higher = more relevant). Concrete implementations:
[`DummyCrossEncoder`](@ref) (deterministic random scores for tests),
[`LLMCrossEncoder`](@ref) (LLM-as-judge).
"""
rerank(enc::AbstractCrossEncoder, query::String, documents::Vector{String})::Vector{Float64} =
    error("rerank not implemented for $(typeof(enc))")

"""Deterministic, random-score cross-encoder used for offline testing."""
mutable struct DummyCrossEncoder <: AbstractCrossEncoder
    rng::Random.AbstractRNG
end

DummyCrossEncoder(seed::Int = 42) = DummyCrossEncoder(Random.MersenneTwister(seed))

function rerank(enc::DummyCrossEncoder, query::String, documents::Vector{String})::Vector{Float64}
    return Float64[rand(enc.rng) for _ in documents]
end

"""LLM-backed cross-encoder that asks the model to score each document."""
mutable struct LLMCrossEncoder <: AbstractCrossEncoder
    llm::AbstractLLMClient
end

const CROSSENCODER_PROMPT = "Score the relevance of the following document to the query " *
    "on a scale of 0.0 to 1.0.  Return JSON: {\"score\": <float>}\n\n" *
    "Query: {query}\n\nDocument: {document}"

function rerank(enc::LLMCrossEncoder, query::String, documents::Vector{String})::Vector{Float64}
    scores = Float64[]
    for doc in documents
        messages = [Dict("role" => "user",
            "content" => format_prompt(CROSSENCODER_PROMPT; query = query, document = doc))]
        score = try
            resp = complete_json(enc.llm, messages)
            raw = get(resp, "score", get(resp, :score, 0.5))
            parsed = raw isa Number ? Float64(raw) :
                (tryparse(Float64, strip(String(raw))) === nothing ? 0.5 :
                    tryparse(Float64, strip(String(raw))))
            clamp(Float64(parsed), 0.0, 1.0)
        catch
            0.5
        end
        push!(scores, score)
    end
    return scores
end
