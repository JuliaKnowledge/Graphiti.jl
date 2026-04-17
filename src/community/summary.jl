"""LLM-based community summarization."""

"""
    summarize_community!(client, cn, members)

Call the LLM to produce a canonical `name` and `summary` for `cn` given its
`members` (a `Vector{EntityNode}`).  Populates `cn.name`, `cn.summary`, and
`cn.name_embedding` in-place and persists the updated node.
"""
function summarize_community!(
    client::GraphitiClient,
    cn::CommunityNode,
    members::Vector{EntityNode},
)::CommunityNode
    isempty(members) && return cn

    entity_names = join([m.name for m in members], ", ")
    entity_summaries = join(
        ["- $(m.name): $(m.summary)" for m in members if !isempty(m.summary)],
        "\n",
    )

    messages = [
        Dict("role" => "system", "content" => SUMMARIZE_COMMUNITY_SYSTEM),
        Dict("role" => "user", "content" => format_prompt(
            SUMMARIZE_COMMUNITY_USER;
            entity_names = entity_names,
            entity_summaries = isempty(entity_summaries) ? entity_names : entity_summaries,
        )),
    ]

    response = try
        _complete_json!(client, messages)
    catch e
        @warn "Community summarization LLM call failed: $e"
        Dict{String, Any}()
    end

    name = string(get(response, "name", entity_names))
    summary = string(get(response, "summary", ""))

    cn.name = isempty(name) ? entity_names : name
    cn.summary = summary
    cn.name_embedding = embed(client.embedder, cn.name)

    save_node!(client.driver, cn)
    return cn
end
