# FalkorDB driver

[FalkorDB](https://www.falkordb.com) is a Redis-backed graph database
that exposes the OpenCypher query language via the `GRAPH.QUERY` Redis
command. Graphiti.jl ships a built-in `FalkorDBDriver` that mirrors the
[`Neo4jDriver`](neo4j.md) feature surface and shares the same
**injectable transport** pattern for testing.

The driver speaks the RESP2 wire protocol directly using only Julia's
`Sockets` stdlib — there is no extra package dependency.

## Quick start

```julia
using Graphiti

driver = FalkorDBDriver(
    host     = "localhost",   # or $FALKORDB_HOST
    port     = 6379,          # or $FALKORDB_PORT
    password = "",            # or $FALKORDB_PASSWORD
    graph    = "graphiti",    # or $FALKORDB_GRAPH
)

client = GraphitiClient(driver, EchoLLMClient(), DeterministicEmbedder())

add_triplet(client, "Alice", "REPORTS_TO", "Bob"; group_id="org")
```

All four environment variables (`FALKORDB_HOST`, `FALKORDB_PORT`,
`FALKORDB_PASSWORD`, `FALKORDB_GRAPH`) override the corresponding
keyword defaults.

## Cypher parameters

FalkorDB does not yet support Bolt-style parameter binding. The driver
transparently rewrites parameterised queries using FalkorDB's `CYPHER`
prelude:

```cypher
GRAPH.QUERY g "CYPHER name='Alice' MATCH (n {name: $name}) RETURN n"
```

You write your Cypher with `$param` placeholders exactly as for Neo4j,
and the driver assembles the prelude. Strings are single-quoted with
backslash escaping, numbers and booleans pass through, and `nothing`
becomes `null`.

## Mutations

The driver implements the same mutation surface as `Neo4jDriver`:

| Method                            | Cypher                                                    |
|-----------------------------------|-----------------------------------------------------------|
| `save_node!(d, ::EntityNode)`     | `MERGE (n:Entity {uuid: $uuid}) SET …`                    |
| `save_node!(d, ::EpisodicNode)`   | `MERGE (n:Episodic {uuid: $uuid}) SET …`                  |
| `save_node!(d, ::CommunityNode)`  | `MERGE (n:Community {uuid: $uuid}) SET name = …`          |
| `save_node!(d, ::SagaNode)`       | `MERGE (n:Saga {uuid: $uuid}) SET …`                      |
| `save_edge!(d, ::EntityEdge)`     | `MERGE (a)-[r:RELATES_TO {uuid: $uuid}]->(b) SET …`       |
| `save_edge!(d, ::EpisodicEdge)`   | `MERGE (a)-[r:MENTIONS {uuid: $uuid}]->(b) SET group_id…` |
| `save_edge!(d, ::CommunityEdge)`  | `MERGE (a)-[r:HAS_MEMBER {uuid: $uuid}]->(b)`             |
| `delete_node!(d, uuid)`           | `MATCH (n {uuid: $uuid}) DETACH DELETE n`                 |
| `delete_edge!(d, uuid)`           | `MATCH ()-[r {uuid: $uuid}]-() DELETE r`                  |
| `clear!(d)`                       | `GRAPH.DELETE <graph>` (atomic, fast)                     |

## Reads

`get_community_nodes`, `get_community_edges`, `get_saga_nodes`, and
`get_episodes_for_saga` issue Cypher and parse the result-set. Other
read accessors (`get_entity_nodes`, `get_entity_edges`,
`get_episodic_nodes`, `get_latest_episodic_node`) currently return
empty collections — the same scope as `Neo4jDriver`. Use
`execute_query(d, …)` for arbitrary Cypher.

## Testing without a server

Like `Neo4jDriver`, `FalkorDBDriver` accepts an injectable
`_command_fn(driver, args::Vector{String}) -> Any` that bypasses the
network. This is how Graphiti's own test suite exercises the driver:

```julia
captured = String[]
stub = (drv, args) -> begin
    push!(captured, args[3])             # the query
    return [[], [], ["stats"]]           # empty result-set reply
end

d = FalkorDBDriver(_command_fn=stub)
save_node!(d, EntityNode(name="Alice", group_id="g1"))
@assert occursin("MERGE (n:Entity", captured[1])
```

## RESP2 helpers

The lower-level wire helpers are reused by tests but also available:

- `Graphiti._resp2_encode_command(args)` → command frame string
- `Graphiti._resp2_decode(io)` → decode one reply from any `IO`
- `Graphiti._falkor_parse_reply(reply)` → turn a `GRAPH.QUERY` array
  reply into `Vector{Dict{String,Any}}`

## Errors

Network or protocol failures throw `Graphiti.GraphitiFalkorDBError`,
which carries a human-readable message and round-trips through
`showerror`. `clear!` deliberately swallows this exception so it is
idempotent against a non-existent graph.
