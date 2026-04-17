"""OpenAI and Azure OpenAI embedding clients."""

mutable struct OpenAIEmbedder <: AbstractEmbedder
    api_key::String
    base_url::String
    model::String
    _request_fn::Function
end

function OpenAIEmbedder(;
    api_key::String = get(ENV, "OPENAI_API_KEY", ""),
    base_url::String = "https://api.openai.com/v1",
    model::String = "text-embedding-3-small",
    _request_fn::Function = _default_openai_http,
)
    return OpenAIEmbedder(api_key, base_url, model, _request_fn)
end

mutable struct AzureOpenAIEmbedder <: AbstractEmbedder
    api_key::String
    endpoint::String
    deployment::String
    api_version::String
    _request_fn::Function
end

function AzureOpenAIEmbedder(;
    api_key::String = get(ENV, "AZURE_OPENAI_API_KEY", ""),
    endpoint::String = get(ENV, "AZURE_OPENAI_ENDPOINT", ""),
    deployment::String = get(ENV, "AZURE_OPENAI_EMBEDDING_DEPLOYMENT", ""),
    api_version::String = get(ENV, "AZURE_OPENAI_API_VERSION", "2024-06-01"),
    _request_fn::Function = _default_openai_http,
)
    return AzureOpenAIEmbedder(api_key, endpoint, deployment, api_version, _request_fn)
end

_embed_headers(e::OpenAIEmbedder) =
    ["Content-Type" => "application/json", "Authorization" => "Bearer $(e.api_key)"]

_embed_headers(e::AzureOpenAIEmbedder) =
    ["Content-Type" => "application/json", "api-key" => e.api_key]

_embed_url(e::OpenAIEmbedder) = rstrip(e.base_url, '/') * "/embeddings"

function _embed_url(e::AzureOpenAIEmbedder)
    base = rstrip(e.endpoint, '/')
    return "$(base)/openai/deployments/$(e.deployment)/embeddings?api-version=$(e.api_version)"
end

_embed_model(e::OpenAIEmbedder) = e.model
_embed_model(e::AzureOpenAIEmbedder) = e.deployment

function embed(e::OpenAIEmbedder, text::String)::Vector{Float64}
    return _openai_do_embed(e, text)
end

function embed(e::AzureOpenAIEmbedder, text::String)::Vector{Float64}
    return _openai_do_embed(e, text)
end

function _openai_do_embed(e::Union{OpenAIEmbedder, AzureOpenAIEmbedder}, text::String)::Vector{Float64}
    body = Dict("model" => _embed_model(e), "input" => text)
    status, resp_body = e._request_fn(_embed_url(e), _embed_headers(e), JSON3.write(body))
    if status < 200 || status >= 300
        error("OpenAI embeddings HTTP $status: $resp_body")
    end
    parsed = JSON3.read(resp_body, Dict{String, Any})
    data = parsed["data"]
    vec = data[1]["embedding"]
    return Float64[Float64(x) for x in vec]
end
