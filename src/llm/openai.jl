"""OpenAI and Azure OpenAI chat completion clients."""

function _default_openai_http(url::String, headers::Vector, body::String)::Tuple{Int, String}
    resp = HTTP.post(url, headers, body; status_exception=false)
    return resp.status, String(resp.body)
end

mutable struct OpenAILLMClient <: AbstractLLMClient
    api_key::String
    base_url::String
    model::String
    temperature::Float64
    timeout::Int
    usage::TokenUsage
    _request_fn::Function
end

function OpenAILLMClient(;
    api_key::String = get(ENV, "OPENAI_API_KEY", ""),
    base_url::String = "https://api.openai.com/v1",
    model::String = "gpt-4o-mini",
    temperature::Float64 = 0.0,
    timeout::Int = 60,
    _request_fn::Function = _default_openai_http,
)
    return OpenAILLMClient(api_key, base_url, model, temperature, timeout, TokenUsage(), _request_fn)
end

mutable struct AzureOpenAILLMClient <: AbstractLLMClient
    api_key::String
    endpoint::String
    deployment::String
    api_version::String
    temperature::Float64
    timeout::Int
    usage::TokenUsage
    _request_fn::Function
end

function AzureOpenAILLMClient(;
    api_key::String = get(ENV, "AZURE_OPENAI_API_KEY", ""),
    endpoint::String = get(ENV, "AZURE_OPENAI_ENDPOINT", ""),
    deployment::String = get(ENV, "AZURE_OPENAI_DEPLOYMENT", ""),
    api_version::String = get(ENV, "AZURE_OPENAI_API_VERSION", "2024-06-01"),
    temperature::Float64 = 0.0,
    timeout::Int = 60,
    _request_fn::Function = _default_openai_http,
)
    return AzureOpenAILLMClient(api_key, endpoint, deployment, api_version,
        temperature, timeout, TokenUsage(), _request_fn)
end

_chat_headers(c::OpenAILLMClient) =
    ["Content-Type" => "application/json", "Authorization" => "Bearer $(c.api_key)"]

_chat_headers(c::AzureOpenAILLMClient) =
    ["Content-Type" => "application/json", "api-key" => c.api_key]

_chat_url(c::OpenAILLMClient) = rstrip(c.base_url, '/') * "/chat/completions"

function _chat_url(c::AzureOpenAILLMClient)
    base = rstrip(c.endpoint, '/')
    return "$(base)/openai/deployments/$(c.deployment)/chat/completions?api-version=$(c.api_version)"
end

_chat_model(c::OpenAILLMClient) = c.model
_chat_model(c::AzureOpenAILLMClient) = c.deployment

_chat_usage(c::Union{OpenAILLMClient, AzureOpenAILLMClient}) = c.usage
_chat_request_fn(c::Union{OpenAILLMClient, AzureOpenAILLMClient}) = c._request_fn
_chat_temperature(c::Union{OpenAILLMClient, AzureOpenAILLMClient}) = c.temperature

function _openai_chat(client::Union{OpenAILLMClient, AzureOpenAILLMClient},
                       messages; response_format=nothing)::Dict{String, Any}
    body = Dict{String, Any}(
        "model" => _chat_model(client),
        "messages" => messages,
        "temperature" => _chat_temperature(client),
    )
    if response_format !== nothing
        body["response_format"] = response_format
    end
    status, resp_body = _chat_request_fn(client)(_chat_url(client), _chat_headers(client), JSON3.write(body))
    if status < 200 || status >= 300
        error("OpenAI HTTP $status: $resp_body")
    end
    parsed = JSON3.read(resp_body, Dict{String, Any})
    if haskey(parsed, "usage")
        u = parsed["usage"]
        pt = Int(get(u, "prompt_tokens", 0))
        ct = Int(get(u, "completion_tokens", 0))
        usage = _chat_usage(client)
        usage.prompt_tokens += pt
        usage.completion_tokens += ct
        usage.total_tokens += pt + ct
    end
    return parsed
end

function complete(client::OpenAILLMClient, messages; kwargs...)::String
    resp = _openai_chat(client, messages)
    return string(resp["choices"][1]["message"]["content"])
end

function complete(client::AzureOpenAILLMClient, messages; kwargs...)::String
    resp = _openai_chat(client, messages)
    return string(resp["choices"][1]["message"]["content"])
end

function complete_json(client::OpenAILLMClient, messages; schema=nothing, kwargs...)::Dict{String, Any}
    resp = _openai_chat(client, messages; response_format=Dict("type" => "json_object"))
    content = string(resp["choices"][1]["message"]["content"])
    return Dict{String, Any}(JSON3.read(content, Dict{String, Any}))
end

function complete_json(client::AzureOpenAILLMClient, messages; schema=nothing, kwargs...)::Dict{String, Any}
    resp = _openai_chat(client, messages; response_format=Dict("type" => "json_object"))
    content = string(resp["choices"][1]["message"]["content"])
    return Dict{String, Any}(JSON3.read(content, Dict{String, Any}))
end
