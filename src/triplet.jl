"""Direct triplet insertion (bypasses LLM extraction)."""

function _get_or_create_entity(client::GraphitiClient, name::String, group_id::String)::EntityNode
    existing = get_entity_nodes(client.driver, group_id)
    idx = findfirst(n -> lowercase(n.name) == lowercase(name), existing)
    if idx !== nothing
        return existing[idx]
    end
    node = EntityNode(name = name, group_id = group_id)
    node.name_embedding = embed(client.embedder, name)
    save_node!(client.driver, node)
    return node
end

function add_triplet(
    client::GraphitiClient,
    source_name::String,
    relation::String,
    target_name::String,
    fact::String;
    group_id::String = "",
    valid_at::Union{Nothing, DateTime} = nothing,
)::Tuple{EntityNode, EntityEdge, EntityNode}
    source_node = _get_or_create_entity(client, source_name, group_id)
    target_node = _get_or_create_entity(client, target_name, group_id)

    edge = EntityEdge(
        source_node_uuid = source_node.uuid,
        target_node_uuid = target_node.uuid,
        name = relation,
        fact = fact,
        group_id = group_id,
        valid_at = valid_at,
        reference_time = now(UTC),
    )
    edge.fact_embedding = embed(client.embedder, fact)
    save_edge!(client.driver, edge)

    return source_node, edge, target_node
end
