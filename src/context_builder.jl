"""
    ContextBuilder

Standalone context builder that wraps a `GraphitiClient`.  No hard dependency
on AgentFramework.jl — any agent framework can call `build(builder, query)` to
get a formatted context string ready to inject into a system prompt.

## AgentFramework.jl integration

```julia
using Graphiti, AgentFramework

# One-liner: wrap the builder in a custom context provider
struct GraphitiContextProvider <: BaseContextProvider
    builder::ContextBuilder
end

function AgentFramework.before_run!(provider::GraphitiContextProvider, agent, session, context, state)
    user_msg = last_user_message(context)
    ctx = Graphiti.build(provider.builder, user_msg)
    isempty(ctx) || push_system_message!(context, ctx)
end
```
"""
Base.@kwdef struct ContextBuilder
    client::GraphitiClient
    config::SearchConfig = SearchConfig()
    group_id::String = ""
end

"""
    build(builder, query) -> String

Search the knowledge graph for `query` and return the formatted context string
produced by `build_context_string`.
"""
function build(builder::ContextBuilder, query::String)::String
    results = search(builder.client, query;
        config = builder.config, group_id = builder.group_id)
    return build_context_string(results)
end
