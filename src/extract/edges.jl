"""LLM-backed relationship extraction between previously extracted entities."""

function extract_edges_from_episode(
    llm::AbstractLLMClient,
    episode::EpisodicNode,
    entities::Vector{EntityNode},
)::Vector{EntityEdge}
    isempty(entities) && return EntityEdge[]

    entity_names = join([e.name for e in entities], ", ")
    messages = [
        Dict("role" => "system", "content" => EXTRACT_EDGES_SYSTEM),
        Dict("role" => "user", "content" => format_prompt(EXTRACT_EDGES_USER;
            entity_names = entity_names,
            episode_content = episode.content)),
    ]

    response = try
        complete_json(llm, messages)
    catch e
        @warn "Edge extraction LLM call failed: $e"
        return EntityEdge[]
    end

    name_to_uuid = Dict(lowercase(e.name) => e.uuid for e in entities)

    edges = EntityEdge[]
    for edge_data in get(response, "edges", Any[])
        src_name = lowercase(string(get(edge_data, "source_entity_name", "")))
        tgt_name = lowercase(string(get(edge_data, "target_entity_name", "")))
        src_uuid = get(name_to_uuid, src_name, nothing)
        tgt_uuid = get(name_to_uuid, tgt_name, nothing)
        (src_uuid === nothing || tgt_uuid === nothing) && continue

        valid_at = parse_temporal(get(edge_data, "valid_at", nothing), episode.valid_at)
        invalid_at = parse_temporal(get(edge_data, "invalid_at", nothing), episode.valid_at)

        push!(edges, EntityEdge(
            source_node_uuid = src_uuid,
            target_node_uuid = tgt_uuid,
            name = string(get(edge_data, "relation_type", "RELATES_TO")),
            fact = string(get(edge_data, "fact", "")),
            episodes = [episode.uuid],
            group_id = episode.group_id,
            valid_at = valid_at,
            invalid_at = invalid_at,
            reference_time = episode.valid_at,
        ))
    end
    return edges
end
