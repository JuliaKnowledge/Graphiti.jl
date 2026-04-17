"""Prompt templates for entity/edge extraction, dedup, and temporal reasoning."""

function format_prompt(template::String; kwargs...)::String
    result = template
    for (k, v) in pairs(kwargs)
        result = replace(result, "{$(k)}" => string(v))
    end
    return result
end

const EXTRACT_ENTITIES_SYSTEM = """You are an entity extraction specialist.
Extract all distinct named entities from the user's text. An entity is any person,
organization, product, place, event, or concept mentioned by name.

Return JSON: {"extracted_entities": [{"name": "EntityName", "summary": "Brief description"}]}
"""

const EXTRACT_ENTITIES_USER = """Extract all named entities from the following text:

{episode_content}

Return JSON with key "extracted_entities" containing a list of objects with "name" and "summary" fields."""

const EXTRACT_EDGES_SYSTEM = """You are a relationship extraction specialist.
Given a passage of text and a list of extracted entities, identify the relationships
between those entities that are stated or strongly implied.

Return JSON: {"edges": [{"source_entity_name": "...", "target_entity_name": "...", "relation_type": "WORKS_AT", "fact": "...", "valid_at": null, "invalid_at": null}]}
"""

const EXTRACT_EDGES_USER = """Extract relationships between entities from the following text.
Entities present: {entity_names}
Text: {episode_content}
Return JSON with key "edges"."""

const DEDUPE_ENTITIES_SYSTEM = """You are an entity resolution specialist.
Determine if two entity descriptions refer to the same real-world entity.
Return JSON: {"is_duplicate": true/false, "reason": "..."}"""

const DEDUPE_ENTITIES_USER = """Are these two entities the same?
Entity A: {entity_a}
Entity B: {entity_b}
Return JSON."""

const INVALIDATION_SYSTEM = """You are a temporal fact consistency checker.
Determine if the new fact contradicts or supersedes the existing fact.
Return JSON: {"contradicts": true/false, "reason": "..."}"""

const INVALIDATION_USER = """Does the new fact contradict the existing fact?
Existing fact: {existing_fact}
New fact: {new_fact}
Return JSON."""
