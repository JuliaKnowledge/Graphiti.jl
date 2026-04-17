"""Top-level GraphitiClient, TokenUsage, and utility helpers."""

function cosine_similarity(a::Vector{Float64}, b::Vector{Float64})::Float64
    (isempty(a) || isempty(b)) && return 0.0
    na = sqrt(sum(a .^ 2))
    nb = sqrt(sum(b .^ 2))
    (na == 0.0 || nb == 0.0) && return 0.0
    return sum(a .* b) / (na * nb)
end

"""Accumulates LLM token usage across the lifetime of a `GraphitiClient`."""
mutable struct TokenUsage
    prompt_tokens::Int
    completion_tokens::Int
    total_tokens::Int
end

TokenUsage() = TokenUsage(0, 0, 0)

"""Reset all counters to zero."""
function reset!(u::TokenUsage)
    u.prompt_tokens = 0
    u.completion_tokens = 0
    u.total_tokens = 0
    return u
end

mutable struct GraphitiClient
    driver::AbstractGraphDriver
    llm::AbstractLLMClient
    embedder::AbstractEmbedder
    config::SearchConfig
    usage::TokenUsage
end

GraphitiClient(driver::AbstractGraphDriver, llm::AbstractLLMClient, embedder::AbstractEmbedder;
    config::SearchConfig = SearchConfig(),
    usage::TokenUsage = TokenUsage()) =
    GraphitiClient(driver, llm, embedder, config, usage)

"""Approximate token count using word splitting (≈4 chars/token heuristic)."""
_approx_tokens(text::String)::Int = max(1, length(split(text)))

"""Track LLM usage on client from prompt messages and a response string."""
function _track_usage!(client::GraphitiClient, messages, response::String)
    prompt_text = join(
        [string(get(m, "content", get(m, :content, ""))) for m in messages], " ")
    pt = _approx_tokens(prompt_text)
    ct = _approx_tokens(response)
    client.usage.prompt_tokens += pt
    client.usage.completion_tokens += ct
    client.usage.total_tokens += pt + ct
    return nothing
end

"""Call `complete_json` on `client.llm`, track token usage, and return the result."""
function _complete_json!(client::GraphitiClient, messages; kwargs...)::Dict{String, Any}
    resp = complete_json(client.llm, messages; kwargs...)
    _track_usage!(client, messages, JSON3.write(resp))
    return resp
end

function build_indices_and_constraints(client::GraphitiClient)
    @info "build_indices_and_constraints: no-op for $(typeof(client.driver))"
    return nothing
end

function clear_data(client::GraphitiClient)
    clear!(client.driver)
    return nothing
end
