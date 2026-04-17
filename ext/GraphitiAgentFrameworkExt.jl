module GraphitiAgentFrameworkExt

using Graphiti
using AgentFramework

using Graphiti: ContextBuilder, GraphitiClient, SearchConfig, build,
                search, build_context_string
using AgentFramework: BaseContextProvider, AgentSession, SessionContext,
                      Message, ROLE_USER, extend_messages!

import AgentFramework: before_run!, after_run!

"""
    GraphitiContextProvider <: AgentFramework.BaseContextProvider

Context provider that injects temporal-knowledge-graph context from
[`Graphiti.jl`](https://github.com/JuliaKnowledge/Graphiti.jl) before each
model call.

This provider runs when both `AgentFramework` and `Graphiti` are loaded
(Julia package extension).

# Construction

```julia
using AgentFramework, Graphiti
client = GraphitiClient(MemoryDriver(), EchoLLMClient(), DeterministicEmbedder())
provider = GraphitiContextProvider(client; group_id="user-123", limit=10)
```

# Behaviour

- **`before_run!`** — extracts the latest user message, runs a hybrid
  `Graphiti.search` (cosine + BM25 + BFS, reranked), and injects the
  formatted context string as a user message ahead of the model call.
- **`after_run!`** — optional `writer_fn(client, session, ctx)` can
  persist the turn as an episode (`Graphiti.add_episode`). By default
  no writing is performed.

# Fields

- `client::GraphitiClient` — underlying Graphiti client.
- `config::SearchConfig` — search / rerank configuration.
- `group_id::String` — scope searches/writes to a single group (e.g. a
  user id).
- `context_prompt::String` — header placed before the retrieved facts.
- `writer_fn::Union{Nothing, Function}` — optional hook called in
  `after_run!`; signature `(client, session, ctx) -> Nothing`.
"""
mutable struct GraphitiContextProvider <: BaseContextProvider
    client::GraphitiClient
    config::SearchConfig
    group_id::String
    context_prompt::String
    writer_fn::Union{Nothing, Function}
end

const _DEFAULT_PROMPT =
    "## Knowledge graph context\nConsider the following facts retrieved from the temporal knowledge graph:"

function GraphitiContextProvider(client::GraphitiClient;
                                 config::SearchConfig = SearchConfig(),
                                 group_id::AbstractString = "",
                                 context_prompt::AbstractString = _DEFAULT_PROMPT,
                                 writer_fn::Union{Nothing, Function} = nothing)
    return GraphitiContextProvider(
        client,
        config,
        String(group_id),
        String(context_prompt),
        writer_fn,
    )
end

function Base.show(io::IO, p::GraphitiContextProvider)
    print(io, "GraphitiContextProvider(group_id=", repr(p.group_id),
              ", limit=", p.config.limit, ")")
end

function _latest_user_query(ctx::SessionContext)::Union{Nothing, String}
    for msg in Iterators.reverse(ctx.input_messages)
        text = strip(msg.text)
        isempty(text) && continue
        return String(text)
    end
    return nothing
end

function before_run!(
    provider::GraphitiContextProvider,
    agent,
    session::AgentSession,
    ctx::SessionContext,
    state::Dict{String, Any},
)
    query = _latest_user_query(ctx)
    query === nothing && return nothing
    state["last_query"] = query

    results = search(provider.client, query;
                     config = provider.config,
                     group_id = provider.group_id)

    state["last_edge_count"] = length(results.edges)
    state["last_node_count"] = length(results.nodes)

    body = build_context_string(results)
    isempty(strip(body)) && return nothing

    text = string(provider.context_prompt, "\n", body)
    extend_messages!(ctx, provider, [Message(ROLE_USER, text)])
    return nothing
end

function after_run!(
    provider::GraphitiContextProvider,
    agent,
    session::AgentSession,
    ctx::SessionContext,
    state::Dict{String, Any},
)
    provider.writer_fn === nothing && return nothing
    provider.writer_fn(provider.client, session, ctx)
    state["persisted_turn"] = get(state, "persisted_turn", 0) + 1
    return nothing
end

# Re-export for callers of either namespace.
export GraphitiContextProvider

end # module GraphitiAgentFrameworkExt
