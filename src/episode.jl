"""High-level add_episode pipeline orchestration."""

struct AddEpisodeResults
    episode::EpisodicNode
    episodic_edges::Vector{EpisodicEdge}
    nodes::Vector{EntityNode}
    edges::Vector{EntityEdge}
end

function add_episode(
    client::GraphitiClient,
    name::String,
    content::String;
    source::EpisodeType = TEXT,
    source_description::String = "",
    group_id::String = "",
    valid_at::DateTime = now(UTC),
    reference_time::DateTime = now(UTC),
)::AddEpisodeResults
    episode = EpisodicNode(
        name = name, content = content, source = source,
        source_description = source_description, group_id = group_id,
        valid_at = valid_at,
    )
    save_node!(client.driver, episode)

    entities = extract_entities(client.llm, episode)

    for node in entities
        node.name_embedding = embed(client.embedder, node.name)
    end

    canonical_nodes = dedupe_entities!(client.driver, client.embedder, client.llm, entities, group_id)

    raw_edges = extract_edges_from_episode(client.llm, episode, canonical_nodes)

    for edge in raw_edges
        edge.fact_embedding = embed(client.embedder, edge.fact)
    end

    canonical_edges = dedupe_edges!(client.driver, client.embedder, raw_edges, group_id)

    invalidate_edges!(client.driver, client.llm, canonical_edges, group_id, reference_time)

    episodic_edges = EpisodicEdge[]
    for node in canonical_nodes
        ee = EpisodicEdge(
            source_node_uuid = episode.uuid,
            target_node_uuid = node.uuid,
            group_id = group_id,
        )
        save_edge!(client.driver, ee)
        push!(episodic_edges, ee)
    end

    return AddEpisodeResults(episode, episodic_edges, canonical_nodes, canonical_edges)
end

function add_episode_bulk(
    client::GraphitiClient,
    episodes::Vector;
    group_id::String = "",
)::Vector{AddEpisodeResults}
    results = AddEpisodeResults[]
    for ep in episodes
        r = add_episode(
            client,
            _ep_field(ep, :name, "episode"),
            _ep_field(ep, :content, "");
            source = _ep_field(ep, :source, TEXT),
            source_description = _ep_field(ep, :source_description, ""),
            group_id = _ep_field(ep, :group_id, group_id),
            valid_at = _ep_field(ep, :valid_at, now(UTC)),
        )
        push!(results, r)
    end
    return results
end

_ep_field(ep::NamedTuple, key::Symbol, default) = hasproperty(ep, key) ? getproperty(ep, key) : default
_ep_field(ep::AbstractDict, key::Symbol, default) = get(ep, key, get(ep, string(key), default))

"""
    ingest_conversation!(client, messages; group_id) -> Vector{AddEpisodeResults}

Turn a chat transcript into a sequence of `EpisodicNode`s — one per message —
and run the full `add_episode` pipeline for each.

Each element of `messages` should be a `Dict` with at least `"role"` and
`"content"` keys (string or symbol keys both accepted).  Empty content strings
are skipped.

This is the recommended entry point for persisting agent conversation history
into the knowledge graph.
"""
function ingest_conversation!(
    client::GraphitiClient,
    messages::Vector{<:Dict};
    group_id::String = "",
)::Vector{AddEpisodeResults}
    results = AddEpisodeResults[]
    for (i, msg) in enumerate(messages)
        role    = string(get(msg, "role",    get(msg, :role,    "user")))
        content = string(get(msg, "content", get(msg, :content, "")))
        isempty(strip(content)) && continue
        r = add_episode(
            client,
            "message_$(i)",
            content;
            source = MESSAGE,
            source_description = role,
            group_id = group_id,
            valid_at = now(UTC),
        )
        push!(results, r)
    end
    return results
end
