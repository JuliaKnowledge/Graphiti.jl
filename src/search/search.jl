"""Search configuration and result containers."""

Base.@kwdef struct SearchConfig
    search_methods::Vector{SearchMethod} = SearchMethod[COSINE_SIMILARITY, BM25_SEARCH]
    reranker::RerankerMethod = RRF
    limit::Int = 10
    sim_min_score::Float64 = 0.0
    mmr_lambda::Float64 = 0.5
    bfs_max_depth::Int = 2
    include_nodes::Bool = true
    include_edges::Bool = true
    include_episodes::Bool = false
    include_communities::Bool = false
    cross_encoder::Union{Nothing, AbstractCrossEncoder} = nothing
end

Base.@kwdef mutable struct SearchResults
    edges::Vector{EntityEdge} = EntityEdge[]
    edge_scores::Vector{Float64} = Float64[]
    nodes::Vector{EntityNode} = EntityNode[]
    node_scores::Vector{Float64} = Float64[]
    episodes::Vector{EpisodicNode} = EpisodicNode[]
    episode_scores::Vector{Float64} = Float64[]
    communities::Vector{CommunityNode} = CommunityNode[]
    community_scores::Vector{Float64} = Float64[]
end
