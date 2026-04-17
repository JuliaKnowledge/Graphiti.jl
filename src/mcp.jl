"""Minimal MCP (Model Context Protocol) server over JSON-RPC 2.0 / stdio.

Exposes four tools on the Graphiti knowledge graph:

- `search`        — semantic search (returns context string)
- `add_episode`   — ingest a new episode
- `get_entity`    — fetch an entity node by UUID
- `get_edge`      — fetch an edge by UUID
"""

const MCP_PROTOCOL_VERSION = "2024-11-05"

function _mcp_response(id, result)
    return JSON3.write(Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
end

function _mcp_error(id, code::Int, message::String)
    return JSON3.write(Dict("jsonrpc" => "2.0", "id" => id,
        "error" => Dict("code" => code, "message" => message)))
end

const MCP_TOOLS = [
    Dict(
        "name" => "search",
        "description" => "Search the Graphiti knowledge graph",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "query" => Dict("type" => "string", "description" => "Search query"),
                "group_id" => Dict("type" => "string", "description" => "Optional group ID"),
            ),
            "required" => ["query"],
        ),
    ),
    Dict(
        "name" => "add_episode",
        "description" => "Add an episode to the knowledge graph",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "name" => Dict("type" => "string"),
                "content" => Dict("type" => "string"),
                "group_id" => Dict("type" => "string"),
            ),
            "required" => ["name", "content"],
        ),
    ),
    Dict(
        "name" => "get_entity",
        "description" => "Get an entity node by UUID",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict("uuid" => Dict("type" => "string")),
            "required" => ["uuid"],
        ),
    ),
    Dict(
        "name" => "get_edge",
        "description" => "Get an edge by UUID",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict("uuid" => Dict("type" => "string")),
            "required" => ["uuid"],
        ),
    ),
]

function _handle_request(client::GraphitiClient, request::AbstractDict)
    method = string(get(request, "method", ""))
    id = get(request, "id", nothing)
    params = get(request, "params", Dict())

    if method == "initialize"
        result = Dict(
            "protocolVersion" => MCP_PROTOCOL_VERSION,
            "capabilities" => Dict("tools" => Dict()),
            "serverInfo" => Dict("name" => "graphiti-mcp", "version" => "0.1.0"),
        )
        return _mcp_response(id, result)

    elseif method == "tools/list"
        return _mcp_response(id, Dict("tools" => MCP_TOOLS))

    elseif method == "tools/call"
        tool_name = string(get(params, "name", ""))
        args = get(params, "arguments", Dict())

        if tool_name == "search"
            query = string(get(args, "query", ""))
            gid = string(get(args, "group_id", ""))
            results = search(client, query; group_id = gid)
            ctx = build_context_string(results)
            return _mcp_response(id, Dict("content" => [Dict("type" => "text", "text" => ctx)]))

        elseif tool_name == "add_episode"
            name = string(get(args, "name", ""))
            content = string(get(args, "content", ""))
            gid = string(get(args, "group_id", ""))
            r = add_episode(client, name, content; group_id = gid)
            return _mcp_response(id, Dict("content" => [Dict("type" => "text",
                "text" => "Added episode $(r.episode.uuid)")]))

        elseif tool_name == "get_entity"
            uuid = string(get(args, "uuid", ""))
            node = get_node(client.driver, uuid)
            if node === nothing || !(node isa EntityNode)
                return _mcp_error(id, -32602, "Entity not found: $uuid")
            end
            payload = JSON3.write(Dict("uuid" => node.uuid, "name" => node.name,
                "summary" => node.summary, "group_id" => node.group_id))
            return _mcp_response(id, Dict("content" => [Dict("type" => "text", "text" => payload)]))

        elseif tool_name == "get_edge"
            uuid = string(get(args, "uuid", ""))
            edge = get_edge(client.driver, uuid)
            if edge === nothing
                return _mcp_error(id, -32602, "Edge not found: $uuid")
            end
            payload = JSON3.write(Dict("uuid" => edge.uuid,
                "source_node_uuid" => getfield(edge, :source_node_uuid),
                "target_node_uuid" => getfield(edge, :target_node_uuid)))
            return _mcp_response(id, Dict("content" => [Dict("type" => "text", "text" => payload)]))

        else
            return _mcp_error(id, -32601, "Unknown tool: $tool_name")
        end

    else
        return _mcp_error(id, -32601, "Method not found: $method")
    end
end

"""
    mcp_serve(client; input=stdin, output=stdout)

Run a JSON-RPC loop over the given I/O streams.  One JSON object per line.
Each line on `input` is parsed as a JSON-RPC request and a JSON-RPC response
is written to `output`.
"""
function mcp_serve(client::GraphitiClient; input::IO = stdin, output::IO = stdout)
    while !eof(input)
        line = readline(input; keep = false)
        isempty(strip(line)) && continue
        request = try
            Dict{String, Any}(JSON3.read(line, Dict))
        catch e
            println(output, _mcp_error(nothing, -32700, "Parse error: $e"))
            flush(output)
            continue
        end
        response = try
            _handle_request(client, request)
        catch e
            println(output, _mcp_error(get(request, "id", nothing), -32603, "Internal error: $e"))
            flush(output)
            continue
        end
        println(output, response)
        flush(output)
    end
end
