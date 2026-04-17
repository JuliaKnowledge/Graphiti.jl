"""Top-level GraphitiClient and utility helpers."""

function cosine_similarity(a::Vector{Float64}, b::Vector{Float64})::Float64
    (isempty(a) || isempty(b)) && return 0.0
    na = sqrt(sum(a .^ 2))
    nb = sqrt(sum(b .^ 2))
    (na == 0.0 || nb == 0.0) && return 0.0
    return sum(a .* b) / (na * nb)
end

mutable struct GraphitiClient
    driver::AbstractGraphDriver
    llm::AbstractLLMClient
    embedder::AbstractEmbedder
    config::SearchConfig
end

GraphitiClient(driver::AbstractGraphDriver, llm::AbstractLLMClient, embedder::AbstractEmbedder;
    config::SearchConfig = SearchConfig()) =
    GraphitiClient(driver, llm, embedder, config)

function build_indices_and_constraints(client::GraphitiClient)
    @info "build_indices_and_constraints: no-op for $(typeof(client.driver))"
    return nothing
end

function clear_data(client::GraphitiClient)
    clear!(client.driver)
    return nothing
end
