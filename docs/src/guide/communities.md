# Community Detection & Summarization

## Overview

Graphiti groups related entities into **communities** using an async label
propagation algorithm.  Each community is then summarised by the LLM into a
canonical name and a one-sentence description.

## build_communities!

Runs the full detection + summarisation pipeline:

```julia
communities = build_communities!(client;
    group_ids       = ["acme"],     # empty = all groups
    clear_existing  = true,         # delete old community nodes first
    max_iterations  = 10,           # label-propagation iteration cap
)
```

### Algorithm

1. Each entity node starts with its own UUID as its community label.
2. Nodes are iterated in random order (seed 42 for reproducibility).
   For each node, its label is updated to the most common label among
   its neighbours (async — updates are immediately visible to later nodes
   in the same pass).
3. The process repeats until stable or `max_iterations` is reached.
4. Nodes sharing a label form a community.  `CommunityNode` + `CommunityEdge`
   (HAS_MEMBER) records are created and persisted.
5. `summarize_community!` is called for each cluster.

## summarize_community!

Call directly to regenerate a community's name and summary:

```julia
summarize_community!(client, community_node, member_entity_nodes)
```

Populates `CommunityNode.name`, `.summary`, and `.name_embedding`.

## update_community!

Assign a **newly added entity** to the most popular community among its
neighbours (no full rebuild required):

```julia
cn = update_community!(client, new_entity_node; group_id = "acme")
```

Returns the assigned `CommunityNode`, or `nothing` if no community was found.

## Community search

Enable community results in `search()` via `SearchConfig`:

```julia
results = search(client, "machine learning frameworks";
    config = SearchConfig(include_communities = true))

println(build_context_string(results))
# ...
# Communities:
# - Python ML Stack: Core libraries for machine learning in Python.
```
