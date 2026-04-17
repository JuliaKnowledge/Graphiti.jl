"""Simple BM25-style full-text search over nodes and edges."""

const BM25_K1 = 1.5
const BM25_B = 0.75

function tokenize(text::String)::Vector{String}
    tokens = split(lowercase(text), r"[^a-z0-9]+")
    return String[t for t in tokens if !isempty(t)]
end

function bm25_score(query_tokens::Vector{String}, doc_tokens::Vector{String}, avg_dl::Float64)::Float64
    doc_len = length(doc_tokens)
    doc_len == 0 && return 0.0
    tf_map = Dict{String, Int}()
    for t in doc_tokens
        tf_map[t] = get(tf_map, t, 0) + 1
    end

    score = 0.0
    for q in query_tokens
        tf = get(tf_map, q, 0)
        tf == 0 && continue
        idf = log(1.0 + 1.0 / (tf / doc_len + 0.001))
        tf_norm = tf * (BM25_K1 + 1) / (tf + BM25_K1 * (1 - BM25_B + BM25_B * doc_len / avg_dl))
        score += idf * tf_norm
    end
    return score
end

function bm25_search_edges(
    driver::AbstractGraphDriver,
    query::String,
    limit::Int;
    group_id::String = "",
)::Tuple{Vector{EntityEdge}, Vector{Float64}}
    edges = isempty(group_id) ? _all_entity_edges(driver) : get_entity_edges(driver, group_id)
    isempty(edges) && return EntityEdge[], Float64[]

    query_tokens = tokenize(query)
    isempty(query_tokens) && return EntityEdge[], Float64[]

    all_doc_tokens = [tokenize(e.fact) for e in edges]
    avg_dl = sum(length.(all_doc_tokens)) / length(edges)
    avg_dl == 0 && (avg_dl = 1.0)

    scored = [(e, bm25_score(query_tokens, toks, avg_dl)) for (e, toks) in zip(edges, all_doc_tokens)]
    filter!(x -> x[2] > 0.0, scored)
    sort!(scored; by = x -> x[2], rev = true)
    n = min(limit, length(scored))
    return [x[1] for x in scored[1:n]], [x[2] for x in scored[1:n]]
end

function bm25_search_nodes(
    driver::AbstractGraphDriver,
    query::String,
    limit::Int;
    group_id::String = "",
)::Tuple{Vector{EntityNode}, Vector{Float64}}
    nodes = isempty(group_id) ? _all_entity_nodes(driver) : get_entity_nodes(driver, group_id)
    isempty(nodes) && return EntityNode[], Float64[]

    query_tokens = tokenize(query)
    isempty(query_tokens) && return EntityNode[], Float64[]

    all_doc_tokens = [tokenize(string(n.name, " ", n.summary)) for n in nodes]
    avg_dl = sum(length.(all_doc_tokens)) / length(nodes)
    avg_dl == 0 && (avg_dl = 1.0)

    scored = [(n, bm25_score(query_tokens, toks, avg_dl)) for (n, toks) in zip(nodes, all_doc_tokens)]
    filter!(x -> x[2] > 0.0, scored)
    sort!(scored; by = x -> x[2], rev = true)
    k = min(limit, length(scored))
    return [x[1] for x in scored[1:k]], [x[2] for x in scored[1:k]]
end
