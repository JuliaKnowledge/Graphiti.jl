"""Edge deduplication and temporal invalidation."""

function dedupe_edges!(
    driver::AbstractGraphDriver,
    embedder::AbstractEmbedder,
    new_edges::Vector{EntityEdge},
    group_id::String;
    sim_threshold::Float64 = 0.85,
)::Vector{EntityEdge}
    canonical = EntityEdge[]

    for edge in new_edges
        if edge.fact_embedding === nothing
            edge.fact_embedding = embed(embedder, edge.fact)
        end

        existing = get_entity_edges(driver, group_id)
        same_pair = filter(
            e -> e.source_node_uuid == edge.source_node_uuid &&
                 e.target_node_uuid == edge.target_node_uuid &&
                 e.invalid_at === nothing,
            existing,
        )

        best_match = nothing
        best_score = 0.0
        for e in same_pair
            e.fact_embedding === nothing && continue
            s = cosine_similarity(edge.fact_embedding, e.fact_embedding)
            if s > best_score
                best_score = s
                best_match = e
            end
        end

        if best_match !== nothing && best_score >= sim_threshold
            for ep in edge.episodes
                ep in best_match.episodes || push!(best_match.episodes, ep)
            end
            save_edge!(driver, best_match)
            push!(canonical, best_match)
        else
            save_edge!(driver, edge)
            push!(canonical, edge)
        end
    end
    return canonical
end

function invalidate_edges!(
    driver::AbstractGraphDriver,
    llm::AbstractLLMClient,
    new_edges::Vector{EntityEdge},
    group_id::String,
    reference_time::DateTime,
)
    for new_edge in new_edges
        existing = get_entity_edges(driver, group_id)
        same_source = filter(
            e -> e.source_node_uuid == new_edge.source_node_uuid &&
                 e.name == new_edge.name &&
                 e.uuid != new_edge.uuid &&
                 e.invalid_at === nothing,
            existing,
        )

        for old_edge in same_source
            messages = [
                Dict("role" => "system", "content" => INVALIDATION_SYSTEM),
                Dict("role" => "user", "content" => format_prompt(
                    INVALIDATION_USER;
                    existing_fact = old_edge.fact,
                    new_fact = new_edge.fact,
                )),
            ]
            try
                resp = complete_json(llm, messages)
                if get(resp, "contradicts", false) == true
                    old_edge.invalid_at = reference_time
                    save_edge!(driver, old_edge)
                end
            catch e
                @warn "Invalidation LLM call failed: $e"
            end
        end
    end
end
