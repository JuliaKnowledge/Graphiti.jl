"""Edge deduplication and temporal invalidation."""

_edge_window_key(edge::EntityEdge) = (edge.valid_at, edge.invalid_at)

function _edge_windows_overlap(a::EntityEdge, b::EntityEdge)::Bool
    a_start, a_end = a.valid_at, a.invalid_at
    b_start, b_end = b.valid_at, b.invalid_at
    left_ok = a_end === nothing || b_start === nothing || a_end >= b_start
    right_ok = b_end === nothing || a_start === nothing || b_end >= a_start
    return left_ok && right_ok
end

function _merge_edge_temporal_window!(canonical::EntityEdge, incoming::EntityEdge)
    if canonical.valid_at === nothing
        canonical.valid_at = incoming.valid_at
    elseif incoming.valid_at !== nothing
        canonical.valid_at = min(canonical.valid_at, incoming.valid_at)
    end

    if canonical.invalid_at === nothing || incoming.invalid_at === nothing
        canonical.invalid_at = nothing
    elseif incoming.invalid_at !== nothing
        canonical.invalid_at = max(canonical.invalid_at, incoming.invalid_at)
    end

    if canonical.expired_at === nothing
        canonical.expired_at = incoming.expired_at
    elseif incoming.expired_at !== nothing
        canonical.expired_at = max(canonical.expired_at, incoming.expired_at)
    end
    return canonical
end

_dedupe_bucket_key(edge::EntityEdge) =
    (edge.source_node_uuid, edge.target_node_uuid, edge.name)

_invalidation_bucket_key(edge::EntityEdge) = (edge.source_node_uuid, edge.name)

function dedupe_edges!(
    driver::AbstractGraphDriver,
    embedder::AbstractEmbedder,
    new_edges::Vector{EntityEdge},
    group_id::String;
    sim_threshold::Float64 = 0.85,
)::Vector{EntityEdge}
    canonical = EntityEdge[]
    existing_by_key = Dict{Tuple{String, String, String}, Vector{EntityEdge}}()
    for edge in get_entity_edges(driver, group_id)
        push!(get!(existing_by_key, _dedupe_bucket_key(edge), EntityEdge[]), edge)
    end

    for edge in new_edges
        if edge.fact_embedding === nothing
            edge.fact_embedding = embed(embedder, edge.fact)
        end

        same_pair = filter(
            e -> _edge_windows_overlap(e, edge),
            get(existing_by_key, _dedupe_bucket_key(edge), EntityEdge[]),
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
            _merge_edge_temporal_window!(best_match, edge)
            if best_match.fact_embedding === nothing
                best_match.fact_embedding = edge.fact_embedding
            end
            isempty(best_match.fact) && (best_match.fact = edge.fact)
            save_edge!(driver, best_match)
            push!(canonical, best_match)
        else
            save_edge!(driver, edge)
            push!(get!(existing_by_key, _dedupe_bucket_key(edge), EntityEdge[]), edge)
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
    existing_by_key = Dict{Tuple{String, String}, Vector{EntityEdge}}()
    for edge in get_entity_edges(driver, group_id)
        push!(get!(existing_by_key, _invalidation_bucket_key(edge), EntityEdge[]), edge)
    end

    for new_edge in new_edges
        same_source = get(existing_by_key, _invalidation_bucket_key(new_edge), EntityEdge[])
        invalidation_time = something(new_edge.valid_at, reference_time)

        for old_edge in same_source
            old_edge.uuid == new_edge.uuid && continue
            old_edge.invalid_at === nothing || continue
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
                    old_edge.invalid_at = invalidation_time
                    save_edge!(driver, old_edge)
                end
            catch e
                @warn "Invalidation LLM call failed: $e"
            end
        end
    end
end

function invalidate_edges!(
    client::GraphitiClient,
    new_edges::Vector{EntityEdge},
    group_id::String,
    reference_time::DateTime,
)
    existing_by_key = Dict{Tuple{String, String}, Vector{EntityEdge}}()
    for edge in get_entity_edges(client.driver, group_id)
        push!(get!(existing_by_key, _invalidation_bucket_key(edge), EntityEdge[]), edge)
    end

    for new_edge in new_edges
        same_source = get(existing_by_key, _invalidation_bucket_key(new_edge), EntityEdge[])
        invalidation_time = something(new_edge.valid_at, reference_time)

        for old_edge in same_source
            old_edge.uuid == new_edge.uuid && continue
            old_edge.invalid_at === nothing || continue
            messages = [
                Dict("role" => "system", "content" => INVALIDATION_SYSTEM),
                Dict("role" => "user", "content" => format_prompt(
                    INVALIDATION_USER;
                    existing_fact = old_edge.fact,
                    new_fact = new_edge.fact,
                )),
            ]
            try
                resp = _complete_json!(client, messages)
                if get(resp, "contradicts", false) == true
                    old_edge.invalid_at = invalidation_time
                    save_edge!(client.driver, old_edge)
                end
            catch e
                @warn "Invalidation LLM call failed: $e"
            end
        end
    end
end
