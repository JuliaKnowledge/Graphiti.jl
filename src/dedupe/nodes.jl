"""Entity deduplication against existing graph nodes."""

function dedupe_entities!(
    driver::AbstractGraphDriver,
    embedder::AbstractEmbedder,
    llm::AbstractLLMClient,
    new_nodes::Vector{EntityNode},
    group_id::String;
    sim_threshold::Float64 = 0.9,
)::Vector{EntityNode}
    existing = get_entity_nodes(driver, group_id)
    canonical = EntityNode[]

    for node in new_nodes
        if node.name_embedding === nothing
            node.name_embedding = embed(embedder, node.name)
        end

        # 1. Exact (case-insensitive) name match
        idx = findfirst(
            e -> Unicode.normalize(lowercase(e.name)) == Unicode.normalize(lowercase(node.name)),
            existing,
        )
        if idx !== nothing
            existing_node = existing[idx]
            if !isempty(node.summary) && isempty(existing_node.summary)
                existing_node.summary = node.summary
                save_node!(driver, existing_node)
            end
            push!(canonical, existing_node)
            continue
        end

        # 2. Embedding-based similarity
        best_match = nothing
        best_score = 0.0
        for e in existing
            e.name_embedding === nothing && continue
            s = cosine_similarity(node.name_embedding, e.name_embedding)
            if s > best_score
                best_score = s
                best_match = e
            end
        end

        if best_match !== nothing && best_score >= sim_threshold
            if !isempty(node.summary) && isempty(best_match.summary)
                best_match.summary = node.summary
                save_node!(driver, best_match)
            end
            push!(canonical, best_match)
            continue
        end

        # 3. Novel entity
        save_node!(driver, node)
        push!(existing, node)
        push!(canonical, node)
    end
    return canonical
end
