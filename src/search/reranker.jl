"""Rerankers (RRF, MMR) and the top-level search() pipeline."""

function rrf_rerank(
    ranked_lists::Vector{Vector{T}},
    _scored_lists::Vector{Vector{Float64}};
    k::Int = 60,
)::Tuple{Vector{T}, Vector{Float64}} where T
    scores = Dict{T, Float64}()
    for lst in ranked_lists
        for (rank, item) in enumerate(lst)
            scores[item] = get(scores, item, 0.0) + 1.0 / (k + rank)
        end
    end
    sorted = sort(collect(pairs(scores)); by = x -> x[2], rev = true)
    return T[x[1] for x in sorted], Float64[x[2] for x in sorted]
end

function mmr_rerank(
    query_embedding::Vector{Float64},
    candidates::Vector{T},
    embeddings::Vector{Vector{Float64}};
    lambda::Float64 = 0.5,
    limit::Int = 10,
)::Tuple{Vector{T}, Vector{Float64}} where T
    isempty(candidates) && return T[], Float64[]
    selected = Int[]
    selected_embeddings = Vector{Float64}[]
    remaining = collect(1:length(candidates))

    while !isempty(remaining) && length(selected) < limit
        best_idx = -1
        best_score = -Inf

        for i in remaining
            rel = cosine_similarity(query_embedding, embeddings[i])
            div = isempty(selected_embeddings) ? 0.0 :
                maximum(cosine_similarity(embeddings[i], se) for se in selected_embeddings)
            score = lambda * rel - (1 - lambda) * div
            if score > best_score
                best_score = score
                best_idx = i
            end
        end

        best_idx == -1 && break
        push!(selected, best_idx)
        push!(selected_embeddings, embeddings[best_idx])
        filter!(x -> x != best_idx, remaining)
    end

    items = T[candidates[i] for i in selected]
    scores = Float64[cosine_similarity(query_embedding, embeddings[i]) for i in selected]
    return items, scores
end

function _combine_ranked_items(lists::Vector{Vector{T}}, score_lists::Vector{Vector{Float64}})::Tuple{Vector{T}, Vector{Float64}} where T
    combined = Tuple{T, Float64}[]
    for (lst, scrs) in zip(lists, score_lists)
        for (item, score) in zip(lst, scrs)
            push!(combined, (item, score))
        end
    end
    seen = Set{String}()
    dedup = Tuple{T, Float64}[]
    for (item, score) in combined
        uuid = getfield(item, :uuid)
        uuid in seen && continue
        push!(seen, uuid)
        push!(dedup, (item, score))
    end
    sort!(dedup; by = x -> x[2], rev = true)
    return T[x[1] for x in dedup], Float64[x[2] for x in dedup]
end

function _fallback_reranker(method::RerankerMethod)
    if method == NODE_DISTANCE || method == EPISODE_MENTIONS
        @warn "Reranker $(method) is not implemented; falling back to RRF."
        return RRF
    end
    return method
end

function _unique_preserve(items::Vector{T}) where T
    seen = Set{T}()
    out = T[]
    for x in items
        x in seen && continue
        push!(seen, x)
        push!(out, x)
    end
    return out
end

function search(
    client::GraphitiClient,
    query::String;
    config::SearchConfig = client.config,
    group_id::String = "",
)::SearchResults
    query_embedding = embed(client.embedder, query)
    reranker = _fallback_reranker(config.reranker)

    edge_lists = Vector{Vector{EntityEdge}}()
    edge_score_lists = Vector{Vector{Float64}}()
    node_lists = Vector{Vector{EntityNode}}()
    node_score_lists = Vector{Vector{Float64}}()

    for method in config.search_methods
        if method == COSINE_SIMILARITY
            if config.include_edges
                edges, scores = cosine_search_edges(client.driver, query_embedding, config.limit;
                    group_id = group_id, min_score = config.sim_min_score)
                if !isempty(edges)
                    push!(edge_lists, edges); push!(edge_score_lists, scores)
                end
            end
            if config.include_nodes
                nodes, nscores = cosine_search_nodes(client.driver, query_embedding, config.limit;
                    group_id = group_id, min_score = config.sim_min_score)
                if !isempty(nodes)
                    push!(node_lists, nodes); push!(node_score_lists, nscores)
                end
            end
        elseif method == BM25_SEARCH
            if config.include_edges
                edges2, scores2 = bm25_search_edges(client.driver, query, config.limit; group_id = group_id)
                if !isempty(edges2)
                    push!(edge_lists, edges2); push!(edge_score_lists, scores2)
                end
            end
            if config.include_nodes
                nodes2, nscores2 = bm25_search_nodes(client.driver, query, config.limit; group_id = group_id)
                if !isempty(nodes2)
                    push!(node_lists, nodes2); push!(node_score_lists, nscores2)
                end
            end
        elseif method == BFS_SEARCH
            seed_edges, _ = cosine_search_edges(client.driver, query_embedding, 3; group_id = group_id)
            seed_uuids = unique(vcat(
                [e.source_node_uuid for e in seed_edges],
                [e.target_node_uuid for e in seed_edges],
            ))
            if !isempty(seed_uuids)
                bfs_nodes, bfs_edges = bfs_search(client.driver, seed_uuids, config.bfs_max_depth;
                    group_id = group_id)
                if !isempty(bfs_edges)
                    push!(edge_lists, bfs_edges); push!(edge_score_lists, fill(0.5, length(bfs_edges)))
                end
                if !isempty(bfs_nodes)
                    push!(node_lists, bfs_nodes); push!(node_score_lists, fill(0.5, length(bfs_nodes)))
                end
            end
        end
    end

    final_edges = EntityEdge[]
    final_edge_scores = Float64[]
    if !isempty(edge_lists)
        if reranker == RRF
            final_edges, final_edge_scores = rrf_rerank(edge_lists, edge_score_lists)
        elseif reranker == MMR
            all_edges = _unique_preserve(vcat(edge_lists...))
            embs = Vector{Float64}[e.fact_embedding !== nothing ? e.fact_embedding :
                                    embed(client.embedder, e.fact) for e in all_edges]
            final_edges, final_edge_scores = mmr_rerank(query_embedding, all_edges, embs;
                lambda = config.mmr_lambda, limit = config.limit)
        else
            final_edges, final_edge_scores = _combine_ranked_items(edge_lists, edge_score_lists)
        end
        n = min(config.limit, length(final_edges))
        final_edges = final_edges[1:n]
        final_edge_scores = final_edge_scores[1:n]
    end

    final_nodes = EntityNode[]
    final_node_scores = Float64[]
    if !isempty(node_lists)
        if reranker == RRF
            final_nodes, final_node_scores = rrf_rerank(node_lists, node_score_lists)
        elseif reranker == MMR
            all_nodes = _unique_preserve(vcat(node_lists...))
            embs = Vector{Float64}[n.name_embedding !== nothing ? n.name_embedding :
                                    embed(client.embedder, isempty(n.summary) ? n.name : "$(n.name): $(n.summary)")
                                   for n in all_nodes]
            final_nodes, final_node_scores = mmr_rerank(query_embedding, all_nodes, embs;
                lambda = config.mmr_lambda, limit = config.limit)
        else
            final_nodes, final_node_scores = _combine_ranked_items(node_lists, node_score_lists)
        end
        k = min(config.limit, length(final_nodes))
        final_nodes = final_nodes[1:k]
        final_node_scores = final_node_scores[1:k]
    end

    # ── Community cosine search ───────────────────────────────────────────────
    final_communities = CommunityNode[]
    final_community_scores = Float64[]
    if config.include_communities
        comms, cscores = cosine_search_communities(
            client.driver, query_embedding, config.limit;
            group_id = group_id, min_score = config.sim_min_score)
        final_communities = comms
        final_community_scores = cscores
    end

    # ── Episode cosine search ─────────────────────────────────────────────────
    final_episodes = EpisodicNode[]
    final_episode_scores = Float64[]
    if config.include_episodes
        eps, escores = cosine_search_episodes(
            client.driver, query_embedding, config.limit;
            group_id = group_id, min_score = config.sim_min_score)
        final_episodes = eps
        final_episode_scores = escores
    end

    # ── Optional cross-encoder rerank ─────────────────────────────────────────
    if config.cross_encoder !== nothing
        if !isempty(final_edges)
            ce_scores = rerank(config.cross_encoder, query, [e.fact for e in final_edges])
            order = sortperm(ce_scores; rev = true)
            final_edges = final_edges[order]
            final_edge_scores = ce_scores[order]
        end
        if !isempty(final_nodes)
            ce_scores = rerank(config.cross_encoder, query,
                [isempty(n.summary) ? n.name : "$(n.name): $(n.summary)" for n in final_nodes])
            order = sortperm(ce_scores; rev = true)
            final_nodes = final_nodes[order]
            final_node_scores = ce_scores[order]
        end
    elseif reranker == CROSS_ENCODER
        @warn "SearchConfig.reranker=CROSS_ENCODER requires config.cross_encoder; keeping pre-reranked order."
    end

    return SearchResults(
        edges = final_edges, edge_scores = final_edge_scores,
        nodes = final_nodes, node_scores = final_node_scores,
        episodes = final_episodes, episode_scores = final_episode_scores,
        communities = final_communities, community_scores = final_community_scores,
    )
end

function build_context_string(results::SearchResults)::String
    parts = String[]

    if !isempty(results.edges)
        push!(parts, "Facts:")
        for (e, _s) in zip(results.edges, results.edge_scores)
            line = "- $(e.fact)"
            e.valid_at !== nothing && (line *= " [valid from $(e.valid_at)]")
            e.invalid_at !== nothing && (line *= " [superseded at $(e.invalid_at)]")
            push!(parts, line)
        end
    end

    if !isempty(results.nodes)
        push!(parts, "\nEntities:")
        for n in results.nodes
            line = "- $(n.name)"
            !isempty(n.summary) && (line *= ": $(n.summary)")
            push!(parts, line)
        end
    end

    if !isempty(results.communities)
        push!(parts, "\nCommunities:")
        for c in results.communities
            push!(parts, "- $(c.name): $(c.summary)")
        end
    end

    if !isempty(results.episodes)
        push!(parts, "\nEpisodes:")
        for ep in results.episodes
            push!(parts, "- $(ep.name): $(ep.content)")
        end
    end

    return join(parts, "\n")
end
