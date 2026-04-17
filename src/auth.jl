"""Credential / bearer-token resolution for Graphiti OpenAI clients.

OpenAI / Azure-OpenAI clients accept either a raw API key string or any
external credential object (e.g. an `AzureIdentity.AbstractAzureCredential`).
`_resolve_bearer` turns the supplied value into a concrete bearer token
string at request time.

The generic `_resolve_bearer` function is intentionally extensible — the
`GraphitiAzureIdentityExt` package extension adds a method for
`AzureIdentity.AbstractAzureCredential` so callers can pass a credential
without Graphiti.jl taking a hard dependency on AzureIdentity.
"""

const AZURE_COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default"

_resolve_bearer(s::AbstractString, scope=AZURE_COGNITIVE_SERVICES_SCOPE) = String(s)
_resolve_bearer(::Nothing, scope=AZURE_COGNITIVE_SERVICES_SCOPE) = ""
_resolve_bearer(f::Function, scope=AZURE_COGNITIVE_SERVICES_SCOPE) = String(f())
_resolve_bearer(x, scope=AZURE_COGNITIVE_SERVICES_SCOPE) =
    error("Graphiti: cannot resolve bearer token from object of type $(typeof(x)). " *
          "Pass a String API key, a zero-arg Function, or load a credential-aware " *
          "package extension (e.g. `using AzureIdentity`).")

"""
    _is_raw_api_key(x) -> Bool

True when `x` is a raw API key string (or nothing). False for anything that
needs to be resolved into a bearer token — credentials, callables, etc.
Used to decide between the Azure `api-key` header and `Authorization: Bearer`.
"""
_is_raw_api_key(::AbstractString) = true
_is_raw_api_key(::Nothing) = true
_is_raw_api_key(_) = false
