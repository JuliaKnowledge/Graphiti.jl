module GraphitiAzureIdentityExt

using Graphiti
using AzureIdentity

# Resolve Graphiti OpenAI / Azure-OpenAI bearer tokens from an
# AzureIdentity credential. Scope defaults to the Cognitive Services
# scope used by Azure OpenAI, but callers can pass a different one.
function Graphiti._resolve_bearer(cred::AzureIdentity.AbstractAzureCredential,
                                  scope::AbstractString = Graphiti.AZURE_COGNITIVE_SERVICES_SCOPE)
    return AzureIdentity.get_token(cred, String(scope)).token
end

# Credentials are NOT raw API keys — they should go in an Authorization
# bearer header, not the Azure `api-key` header.
Graphiti._is_raw_api_key(::AzureIdentity.AbstractAzureCredential) = false

end # module GraphitiAzureIdentityExt
