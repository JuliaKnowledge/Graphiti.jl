# OpenAI / Azure OpenAI usage example for Graphiti.jl
#
# Requires:
#   - OPENAI_API_KEY environment variable for OpenAI, OR
#   - AZURE_OPENAI_API_KEY + AZURE_OPENAI_ENDPOINT + AZURE_OPENAI_DEPLOYMENT
#     for Azure OpenAI.
#
# This script is illustrative — it makes real HTTP calls when run.

using Graphiti

# ── OpenAI ────────────────────────────────────────────────────────────────────
llm      = OpenAILLMClient(model = "gpt-4o-mini")
embedder = OpenAIEmbedder(model = "text-embedding-3-small")

driver = MemoryDriver()
client = GraphitiClient(driver, llm, embedder)

r = add_episode(client, "intro",
    "Alice met Bob in Seattle last week and they discussed the weather.";
    group_id = "demo")

println("Entities: ", [n.name for n in r.nodes])
println("Facts:    ", [e.fact for e in r.edges])

# Query the graph
results = search(client, "Who did Alice meet?"; group_id = "demo")
println("\nContext:\n", build_context_string(results))

# Token usage
println("\nTokens used: ", client.usage.total_tokens)

# ── Azure OpenAI variant ──────────────────────────────────────────────────────
# llm_az = AzureOpenAILLMClient(
#     endpoint = "https://my-aoai.openai.azure.com",
#     deployment = "gpt-4o-mini",
#     api_version = "2024-06-01",
# )
# emb_az = AzureOpenAIEmbedder(
#     endpoint = "https://my-aoai.openai.azure.com",
#     deployment = "text-embedding-3-small",
#     api_version = "2024-06-01",
# )
# client_az = GraphitiClient(MemoryDriver(), llm_az, emb_az)
