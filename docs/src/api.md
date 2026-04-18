# API Reference

This page is auto-generated from the docstrings in `Graphiti`. Public symbols
without a docstring are listed under [Undocumented exports](@ref) below — see
the source for usage.

## Drivers

```@docs
AbstractGraphDriver
MemoryDriver
Neo4jDriver
FalkorDBDriver
KuzuDriver
init_schema!
clear!
```

## LLM and embedders

```@docs
AbstractLLMClient
AbstractEmbedder
```

## Search

```@docs
cosine_search_communities
cosine_search_episodes
AbstractCrossEncoder
DummyCrossEncoder
LLMCrossEncoder
rerank
```

## High-level client

```@docs
GraphitiClient
ContextBuilder
build
TokenUsage
reset!
ingest_conversation!
```

## Communities

```@docs
build_communities!
update_community!
summarize_community!
```

## Sagas

```@docs
add_saga!
assign_episode_to_saga!
summarize_saga!
```

## MCP

```@docs
mcp_serve
```

## Extensions

These functions are exported but their implementations live in package
extensions that load only when the corresponding optional package is
`using`'d alongside `Graphiti`. Calling them without the extension loaded
raises a `Graphiti.ExtensionNotLoadedError`.

### RDFLib (SPARQL / Turtle)

```@docs
to_rdf_graph
sparql_kg
kg_to_turtle
```

### ACSets

```@docs
to_acset
acset_query
```

### Causal SQL

```@docs
to_csql
causal_query
```

### Semantic Spacetime

```@docs
to_sst
sst_query
```

## Undocumented exports

The following symbols are exported but do not (yet) carry a docstring. They
remain part of the public API; consult the source files for now and please
file PRs adding docstrings.

```@autodocs
Modules = [Graphiti]
Order   = [:type, :function]
Filter  = obj -> begin
    bind = Base.Docs.Binding(Graphiti, Symbol(string(obj)))
    !haskey(Base.Docs.meta(Graphiti), bind)
end
```
