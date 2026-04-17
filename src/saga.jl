"""Saga (episode-group) node management and summarization."""

"""
    add_saga!(client, name; group_id) -> SagaNode

Create and persist a new `SagaNode` with the given `name`.
"""
function add_saga!(
    client::GraphitiClient,
    name::String;
    group_id::String = "",
)::SagaNode
    saga = SagaNode(name = name, group_id = group_id)
    save_node!(client.driver, saga)
    return saga
end

"""
    assign_episode_to_saga!(driver, episode, saga_uuid)

Set `episode.saga_uuid` and persist the updated node.
"""
function assign_episode_to_saga!(
    driver::AbstractGraphDriver,
    episode::EpisodicNode,
    saga_uuid::String,
)::EpisodicNode
    episode.saga_uuid = saga_uuid
    save_node!(driver, episode)
    return episode
end

"""
    summarize_saga!(client, saga_uuid) -> SagaNode

Fetch all `EpisodicNode`s whose `saga_uuid` matches, concatenate their
contents (truncated to ≤ 2000 chars), call the LLM to produce a 2-3 sentence
narrative summary, store it in `SagaNode.summary`, and persist.

Returns the updated `SagaNode`, or `nothing` if the saga UUID is not found.
"""
function summarize_saga!(
    client::GraphitiClient,
    saga_uuid::String;
    group_id::String = "",
)::Union{Nothing, SagaNode}
    saga = get_node(client.driver, saga_uuid)
    (saga === nothing || !(saga isa SagaNode)) && return nothing

    episodes = get_episodic_nodes(client.driver, group_id)
    members = filter(ep -> ep.saga_uuid == saga_uuid, episodes)
    sort!(members; by = ep -> ep.valid_at)

    if isempty(members)
        @warn "summarize_saga!: no episodes found for saga $(saga_uuid)"
        return saga
    end

    raw_text = join([ep.content for ep in members], "\n\n")
    truncated = length(raw_text) > 2000 ? raw_text[1:2000] * "…" : raw_text

    messages = [
        Dict("role" => "system", "content" => SUMMARIZE_SAGA_SYSTEM),
        Dict("role" => "user", "content" => format_prompt(
            SUMMARIZE_SAGA_USER;
            episode_contents = truncated,
        )),
    ]

    response = try
        _complete_json!(client, messages)
    catch e
        @warn "Saga summarization LLM call failed: $e"
        Dict{String, Any}()
    end

    saga.summary = string(get(response, "summary", ""))
    saga.last_updated = now(UTC)
    save_node!(client.driver, saga)
    return saga
end
