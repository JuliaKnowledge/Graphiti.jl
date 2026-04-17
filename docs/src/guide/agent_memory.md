# Agent Memory with ContextBuilder

## Overview

Graphiti.jl provides a standalone `ContextBuilder` that works with any agent
framework — no hard dependency on AgentFramework.jl is required.

## ContextBuilder

```julia
using Graphiti

builder = ContextBuilder(
    client   = client,       # GraphitiClient
    config   = SearchConfig(include_communities = true),
    group_id = "my-agent",
)

# Before each LLM call, build context from the knowledge graph:
ctx = build(builder, user_message)
# Returns a formatted string ready for injection into a system prompt.
```

## Wiring into AgentFramework.jl

If you are using [AgentFramework.jl](https://github.com/your-org/AgentFramework.jl),
create a thin wrapper struct:

```julia
using Graphiti, AgentFramework

struct GraphitiContextProvider <: AgentFramework.BaseContextProvider
    builder::Graphiti.ContextBuilder
end

function AgentFramework.before_run!(
    provider::GraphitiContextProvider,
    agent, session, context, state,
)
    user_msg = last_user_message(context)
    ctx = Graphiti.build(provider.builder, user_msg)
    isempty(ctx) || push_system_message!(context, ctx)
end
```

Then add the provider to your agent:

```julia
agent = Agent(
    name     = "my-agent",
    model    = "gpt-4o",
    context_providers = [
        GraphitiContextProvider(builder)
    ],
)
```

## Ingesting agent conversations

Use `ingest_conversation!` to persist the full conversation history after each
agent run:

```julia
function after_run_hook(messages, group_id)
    ingest_conversation!(client, messages; group_id = group_id)
end
```

## Token tracking

`GraphitiClient` accumulates token usage across all community and saga LLM
calls:

```julia
client.usage.prompt_tokens
client.usage.completion_tokens
client.usage.total_tokens
reset!(client.usage)    # clear counters
```
