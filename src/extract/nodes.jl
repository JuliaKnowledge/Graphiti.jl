"""LLM-backed entity extraction."""

function extract_entities(
    llm::AbstractLLMClient,
    episode::EpisodicNode;
    previous_episodes::Vector{EpisodicNode} = EpisodicNode[],
)::Vector{EntityNode}
    messages = [
        Dict("role" => "system", "content" => EXTRACT_ENTITIES_SYSTEM),
        Dict("role" => "user", "content" => format_prompt(EXTRACT_ENTITIES_USER;
            episode_content = episode.content)),
    ]

    response = try
        complete_json(llm, messages)
    catch e
        @warn "Entity extraction LLM call failed: $e"
        return EntityNode[]
    end

    return _parse_entity_response(response, episode)
end

function extract_entities(
    client::GraphitiClient,
    episode::EpisodicNode;
    previous_episodes::Vector{EpisodicNode} = EpisodicNode[],
)::Vector{EntityNode}
    messages = [
        Dict("role" => "system", "content" => EXTRACT_ENTITIES_SYSTEM),
        Dict("role" => "user", "content" => format_prompt(EXTRACT_ENTITIES_USER;
            episode_content = episode.content)),
    ]

    response = try
        _complete_json!(client, messages)
    catch e
        @warn "Entity extraction LLM call failed: $e"
        return EntityNode[]
    end

    return _parse_entity_response(response, episode)
end

function _parse_entity_response(response, episode::EpisodicNode)::Vector{EntityNode}
    nodes = EntityNode[]
    for e in get(response, "extracted_entities", Any[])
        name = string(get(e, "name", ""))
        isempty(name) && continue
        push!(nodes, EntityNode(
            name = name,
            summary = string(get(e, "summary", "")),
            group_id = episode.group_id,
        ))
    end
    return nodes
end
