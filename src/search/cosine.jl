"""Cosine-similarity search over node name embeddings and edge fact embeddings."""

_all_entity_edges(d::MemoryDriver) = collect(values(d.entity_edges))
_all_entity_edges(d::AbstractGraphDriver) = get_entity_edges(d, "")

_all_entity_nodes(d::MemoryDriver) = collect(values(d.entity_nodes))
_all_entity_nodes(d::AbstractGraphDriver) = get_entity_nodes(d, "")

_all_community_nodes(d::MemoryDriver) = collect(values(d.community_nodes))
_all_community_nodes(d::AbstractGraphDriver) = get_community_nodes(d, "")

function cosine_search_edges(
    driver::AbstractGraphDriver,
    query_embedding::Vector{Float64},
    limit::Int;
    group_id::String = "",
    min_score::Float64 = 0.0,
)::Tuple{Vector{EntityEdge}, Vector{Float64}}
    edges = isempty(group_id) ? _all_entity_edges(driver) : get_entity_edges(driver, group_id)

    scored = Tuple{EntityEdge, Float64}[]
    for e in edges
        e.fact_embedding === nothing && continue
        s = cosine_similarity(query_embedding, e.fact_embedding)
        s >= min_score && push!(scored, (e, s))
    end
    sort!(scored; by = x -> x[2], rev = true)
    n = min(limit, length(scored))
    return [x[1] for x in scored[1:n]], [x[2] for x in scored[1:n]]
end

function cosine_search_nodes(
    driver::AbstractGraphDriver,
    query_embedding::Vector{Float64},
    limit::Int;
    group_id::String = "",
    min_score::Float64 = 0.0,
)::Tuple{Vector{EntityNode}, Vector{Float64}}
    nodes = isempty(group_id) ? _all_entity_nodes(driver) : get_entity_nodes(driver, group_id)

    scored = Tuple{EntityNode, Float64}[]
    for n in nodes
        n.name_embedding === nothing && continue
        s = cosine_similarity(query_embedding, n.name_embedding)
        s >= min_score && push!(scored, (n, s))
    end
    sort!(scored; by = x -> x[2], rev = true)
    k = min(limit, length(scored))
    return [x[1] for x in scored[1:k]], [x[2] for x in scored[1:k]]
end

"""
    cosine_search_communities(driver, query_embedding, limit; group_id, min_score)

Return `CommunityNode`s ranked by cosine similarity of their `name_embedding`
to `query_embedding`.  Nodes without an embedding are skipped.
"""
function cosine_search_communities(
    driver::AbstractGraphDriver,
    query_embedding::Vector{Float64},
    limit::Int;
    group_id::String = "",
    min_score::Float64 = 0.0,
)::Tuple{Vector{CommunityNode}, Vector{Float64}}
    cnodes = isempty(group_id) ? _all_community_nodes(driver) : get_community_nodes(driver, group_id)

    scored = Tuple{CommunityNode, Float64}[]
    for c in cnodes
        c.name_embedding === nothing && continue
        s = cosine_similarity(query_embedding, c.name_embedding)
        s >= min_score && push!(scored, (c, s))
    end
    sort!(scored; by = x -> x[2], rev = true)
    k = min(limit, length(scored))
    return [x[1] for x in scored[1:k]], [x[2] for x in scored[1:k]]
end
