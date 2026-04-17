"""LLM client abstraction and EchoLLMClient for offline testing."""

abstract type AbstractLLMClient end

complete(c::AbstractLLMClient, messages; kwargs...)::String =
    error("complete not implemented for $(typeof(c))")

complete_json(c::AbstractLLMClient, messages; kwargs...)::Dict{String, Any} =
    error("complete_json not implemented for $(typeof(c))")

mutable struct EchoLLMClient <: AbstractLLMClient
    queue::Vector{Dict{String, Any}}
    fallback::Dict{String, Any}
end

EchoLLMClient(; fallback::Dict{String, Any} = Dict{String, Any}()) =
    EchoLLMClient(Dict{String, Any}[], fallback)

function enqueue_response!(client::EchoLLMClient, resp::Dict{String, Any})
    push!(client.queue, resp)
    return client
end

function complete_json(client::EchoLLMClient, messages; kwargs...)::Dict{String, Any}
    if !isempty(client.queue)
        return popfirst!(client.queue)
    end
    return client.fallback
end

function complete(client::EchoLLMClient, messages; kwargs...)::String
    return JSON3.write(complete_json(client, messages; kwargs...))
end
