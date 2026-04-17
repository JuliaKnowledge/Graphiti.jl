using Test
using Graphiti
using Dates
using JSON3

@testset "Phase 6: Productionization" begin

    # ── Item 1: OpenAI / Azure OpenAI LLM + embedder ──────────────────────────
    @testset "OpenAI LLM client" begin
        captured = Ref{Dict{String, Any}}(Dict{String, Any}())
        fake = function (url, headers, body)
            captured[] = Dict("url" => url, "headers" => headers, "body" => body)
            resp = Dict(
                "choices" => [Dict("message" => Dict("content" => "hello world"))],
                "usage" => Dict("prompt_tokens" => 7, "completion_tokens" => 3,
                    "total_tokens" => 10),
            )
            return (200, JSON3.write(resp))
        end

        llm = OpenAILLMClient(api_key = "sk-test", model = "gpt-4o-mini",
            _request_fn = fake)
        @test complete(llm, [Dict("role" => "user", "content" => "hi")]) == "hello world"
        @test occursin("/chat/completions", captured[]["url"])
        @test any(h -> h[1] == "Authorization" && occursin("sk-test", h[2]), captured[]["headers"])
        @test llm.usage.prompt_tokens == 7
        @test llm.usage.completion_tokens == 3
        @test llm.usage.total_tokens == 10

        # complete_json
        json_fake = function (url, headers, body)
            resp = Dict(
                "choices" => [Dict("message" =>
                    Dict("content" => "{\"answer\": 42}"))],
                "usage" => Dict("prompt_tokens" => 2, "completion_tokens" => 1,
                    "total_tokens" => 3),
            )
            return (200, JSON3.write(resp))
        end
        llm2 = OpenAILLMClient(api_key = "k", _request_fn = json_fake)
        d = complete_json(llm2, [Dict("role" => "user", "content" => "?")])
        @test d["answer"] == 42
        @test llm2.usage.total_tokens == 3
    end

    @testset "AzureOpenAILLMClient URL + header" begin
        captured = Ref{Dict{String, Any}}(Dict{String, Any}())
        fake = function (url, headers, body)
            captured[] = Dict("url" => url, "headers" => headers)
            return (200, JSON3.write(Dict(
                "choices" => [Dict("message" => Dict("content" => "ok"))],
                "usage" => Dict("prompt_tokens" => 1, "completion_tokens" => 1,
                    "total_tokens" => 2),
            )))
        end
        llm = AzureOpenAILLMClient(
            api_key = "az-key", endpoint = "https://my-aoai.openai.azure.com",
            deployment = "gpt4o", api_version = "2024-06-01",
            _request_fn = fake,
        )
        complete(llm, [Dict("role" => "user", "content" => "x")])
        @test occursin("openai/deployments/gpt4o/chat/completions", captured[]["url"])
        @test occursin("api-version=2024-06-01", captured[]["url"])
        @test any(h -> h[1] == "api-key" && h[2] == "az-key", captured[]["headers"])
    end

    @testset "OpenAIEmbedder" begin
        captured = Ref{Dict{String, Any}}(Dict{String, Any}())
        fake = function (url, headers, body)
            captured[] = Dict("url" => url, "headers" => headers, "body" => body)
            resp = Dict("data" => [Dict("embedding" => [0.1, 0.2, 0.3])])
            return (200, JSON3.write(resp))
        end
        emb = OpenAIEmbedder(api_key = "k", _request_fn = fake)
        v = embed(emb, "hello")
        @test v == [0.1, 0.2, 0.3]
        @test occursin("/embeddings", captured[]["url"])
        @test any(h -> h[1] == "Authorization", captured[]["headers"])
    end

    @testset "AzureOpenAIEmbedder" begin
        captured = Ref{Dict{String, Any}}(Dict{String, Any}())
        fake = function (url, headers, body)
            captured[] = Dict("url" => url, "headers" => headers)
            return (200, JSON3.write(Dict("data" => [Dict("embedding" => [1.0, 0.0])])))
        end
        emb = AzureOpenAIEmbedder(api_key = "az", endpoint = "https://x.openai.azure.com",
            deployment = "text-embed", api_version = "2024-06-01", _request_fn = fake)
        v = embed(emb, "foo")
        @test v == [1.0, 0.0]
        @test occursin("openai/deployments/text-embed/embeddings", captured[]["url"])
        @test any(h -> h[1] == "api-key", captured[]["headers"])
    end

    # ── Item 2: Token tracking through add_episode ────────────────────────────
    @testset "Token tracking through add_episode" begin
        driver = MemoryDriver()
        llm = EchoLLMClient()
        # Enqueue responses for: extract_entities, extract_edges, no invalidation
        enqueue_response!(llm, Dict{String, Any}(
            "extracted_entities" => [Dict("name" => "Alice", "summary" => "person")],
        ))
        enqueue_response!(llm, Dict{String, Any}("edges" => Any[]))
        embedder = DeterministicEmbedder(4)
        client = GraphitiClient(driver, llm, embedder)
        @test client.usage.total_tokens == 0
        add_episode(client, "ep1", "Alice is a person."; group_id = "g")
        @test client.usage.total_tokens > 0
        @test client.usage.prompt_tokens > 0
        @test client.usage.completion_tokens > 0
    end

    # ── Item 3: Neo4j community / saga / episodes-for-saga ────────────────────
    @testset "Neo4j: save SagaNode, get communities/sagas/episodes-for-saga" begin
        captured = Ref{Vector{Dict{String, Any}}}(Dict{String, Any}[])
        make_resp(rows::Vector{<:Dict}) = begin
            cols = isempty(rows) ? String[] : collect(keys(rows[1]))
            data = [Dict("row" => [r[c] for c in cols]) for r in rows]
            body = Dict("results" => [Dict("columns" => cols, "data" => data)], "errors" => Any[])
            return JSON3.write(body)
        end

        # save SagaNode
        fake_save = function (url, headers, body)
            push!(captured[], Dict("body" => body))
            return (200, make_resp(Dict{String, Any}[Dict("uuid" => "s1")]))
        end
        d = Neo4jDriver(url = "http://n", user = "u", password = "p",
            database = "neo4j", _request_fn = fake_save)
        s = SagaNode(uuid = "s1", name = "S", summary = "desc", group_id = "g")
        save_node!(d, s)
        @test occursin("MERGE (n:Saga", captured[][end]["body"])
        @test occursin("\"uuid\":\"s1\"", captured[][end]["body"])

        # get_community_nodes (with group_id)
        captured[] = Dict{String, Any}[]
        fake_comm = function (url, headers, body)
            push!(captured[], Dict("body" => body))
            return (200, make_resp(Dict{String, Any}[
                Dict("uuid" => "c1", "name" => "C", "summary" => "s", "group_id" => "g"),
            ]))
        end
        d2 = Neo4jDriver(url = "http://n", user = "u", password = "p",
            database = "neo4j", _request_fn = fake_comm)
        comms = get_community_nodes(d2, "g")
        @test length(comms) == 1
        @test comms[1].uuid == "c1"
        @test comms[1].group_id == "g"
        @test occursin("MATCH (n:Community", captured[][end]["body"])

        # get_community_edges
        captured[] = Dict{String, Any}[]
        fake_ce = function (url, headers, body)
            push!(captured[], Dict("body" => body))
            return (200, make_resp(Dict{String, Any}[
                Dict("uuid" => "e1", "src" => "c1", "tgt" => "n1", "group_id" => "g"),
            ]))
        end
        d3 = Neo4jDriver(url = "http://n", user = "u", password = "p",
            database = "neo4j", _request_fn = fake_ce)
        ces = get_community_edges(d3, "c1")
        @test length(ces) == 1
        @test ces[1].source_node_uuid == "c1"
        @test ces[1].target_node_uuid == "n1"

        # get_saga_nodes (no group_id)
        fake_sg = function (url, headers, body)
            return (200, make_resp(Dict{String, Any}[
                Dict("uuid" => "s1", "name" => "S", "summary" => "desc", "group_id" => "g"),
            ]))
        end
        d4 = Neo4jDriver(url = "http://n", user = "u", password = "p",
            database = "neo4j", _request_fn = fake_sg)
        sgs = get_saga_nodes(d4, "")
        @test length(sgs) == 1
        @test sgs[1].uuid == "s1"

        # get_episodes_for_saga
        captured[] = Dict{String, Any}[]
        fake_es = function (url, headers, body)
            push!(captured[], Dict("body" => body))
            return (200, make_resp(Dict{String, Any}[
                Dict("uuid" => "ep1", "name" => "E1", "content" => "C", "group_id" => "g"),
            ]))
        end
        d5 = Neo4jDriver(url = "http://n", user = "u", password = "p",
            database = "neo4j", _request_fn = fake_es)
        eps = get_episodes_for_saga(d5, "s1")
        @test length(eps) == 1
        @test eps[1].uuid == "ep1"
        @test occursin("saga_uuid", captured[][end]["body"])
    end

    @testset "MemoryDriver: get_episodes_for_saga" begin
        d = MemoryDriver()
        ep1 = EpisodicNode(name = "e1", content = "a", saga_uuid = "S1", group_id = "g")
        ep2 = EpisodicNode(name = "e2", content = "b", saga_uuid = "S2", group_id = "g")
        ep3 = EpisodicNode(name = "e3", content = "c", saga_uuid = "S1", group_id = "g")
        save_node!(d, ep1); save_node!(d, ep2); save_node!(d, ep3)
        found = get_episodes_for_saga(d, "S1")
        @test length(found) == 2
        @test Set([e.uuid for e in found]) == Set([ep1.uuid, ep3.uuid])
    end

    # ── Item 4: include_episodes search ───────────────────────────────────────
    @testset "search with include_episodes=true" begin
        driver = MemoryDriver()
        embedder = DeterministicEmbedder(8)
        llm = EchoLLMClient()
        client = GraphitiClient(driver, llm, embedder)

        ep = EpisodicNode(name = "meeting", content = "Alice met Bob", group_id = "g")
        ep.content_embedding = embed(embedder, ep.content)
        save_node!(driver, ep)

        cfg = SearchConfig(include_episodes = true, include_nodes = false,
            include_edges = false)
        results = search(client, "Alice met Bob"; config = cfg, group_id = "g")
        @test length(results.episodes) == 1
        @test results.episodes[1].uuid == ep.uuid
        @test results.episode_scores[1] > 0.99

        # build_context_string includes episodes
        ctx = build_context_string(results)
        @test occursin("Episodes:", ctx)
        @test occursin("Alice met Bob", ctx)
    end

    @testset "add_episode populates content_embedding" begin
        driver = MemoryDriver()
        llm = EchoLLMClient()
        enqueue_response!(llm, Dict{String, Any}("extracted_entities" => Any[]))
        enqueue_response!(llm, Dict{String, Any}("edges" => Any[]))
        embedder = DeterministicEmbedder(4)
        client = GraphitiClient(driver, llm, embedder)
        r = add_episode(client, "ep", "hello world"; group_id = "g")
        @test r.episode.content_embedding !== nothing
        @test length(r.episode.content_embedding) == 4
    end

    # ── Item 5: CrossEncoder reranker ─────────────────────────────────────────
    @testset "DummyCrossEncoder" begin
        enc = DummyCrossEncoder(123)
        scores = rerank(enc, "q", ["a", "b", "c"])
        @test length(scores) == 3
        @test all(0.0 .<= scores .<= 1.0)
        # deterministic by seed
        enc2 = DummyCrossEncoder(123)
        @test rerank(enc2, "q", ["a", "b", "c"]) == scores
    end

    @testset "LLMCrossEncoder with EchoLLMClient" begin
        llm = EchoLLMClient()
        enqueue_response!(llm, Dict{String, Any}("score" => 0.9))
        enqueue_response!(llm, Dict{String, Any}("score" => 0.2))
        enc = LLMCrossEncoder(llm)
        scores = rerank(enc, "q", ["doc1", "doc2"])
        @test scores[1] ≈ 0.9 atol=1e-6
        @test scores[2] ≈ 0.2 atol=1e-6
    end

    @testset "search() applies cross_encoder" begin
        driver = MemoryDriver()
        embedder = DeterministicEmbedder(8)
        llm = EchoLLMClient()
        client = GraphitiClient(driver, llm, embedder)

        # Add a few nodes
        n1 = EntityNode(name = "alpha", summary = "", group_id = "g")
        n2 = EntityNode(name = "beta",  summary = "", group_id = "g")
        n1.name_embedding = embed(embedder, n1.name)
        n2.name_embedding = embed(embedder, n2.name)
        save_node!(driver, n1); save_node!(driver, n2)

        # Use dummy cross-encoder with fixed-seed rng
        enc = DummyCrossEncoder(7)
        cfg = SearchConfig(
            search_methods = SearchMethod[COSINE_SIMILARITY],
            include_edges = false, include_nodes = true,
            cross_encoder = enc,
        )
        results = search(client, "alpha"; config = cfg, group_id = "g")
        @test length(results.nodes) >= 1
        # Scores came from the cross-encoder (between 0 and 1)
        @test all(0.0 .<= results.node_scores .<= 1.0)
    end

    # ── Item 6: MCP server ────────────────────────────────────────────────────
    @testset "MCP: initialize + tools/list" begin
        driver = MemoryDriver()
        llm = EchoLLMClient()
        embedder = DeterministicEmbedder(4)
        client = GraphitiClient(driver, llm, embedder)

        inp = IOBuffer()
        out = IOBuffer()
        # Write two requests
        write(inp, JSON3.write(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize")))
        write(inp, "\n")
        write(inp, JSON3.write(Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tools/list")))
        write(inp, "\n")
        seekstart(inp)
        Graphiti.mcp_serve(client; input = inp, output = out)

        responses = [JSON3.read(l, Dict) for l in split(strip(String(take!(out))), "\n")]
        @test length(responses) == 2
        @test responses[1]["id"] == 1
        @test haskey(responses[1]["result"], "protocolVersion")
        @test responses[2]["id"] == 2
        tools = responses[2]["result"]["tools"]
        @test length(tools) == 4
        @test Set([t["name"] for t in tools]) ==
            Set(["search", "add_episode", "get_entity", "get_edge"])
    end

    @testset "MCP: add_episode + search + get_entity + errors" begin
        driver = MemoryDriver()
        llm = EchoLLMClient()
        # add_episode will pop extract_entities, extract_edges
        enqueue_response!(llm, Dict{String, Any}(
            "extracted_entities" => [Dict("name" => "Carol", "summary" => "person")],
        ))
        enqueue_response!(llm, Dict{String, Any}("edges" => Any[]))
        embedder = DeterministicEmbedder(8)
        client = GraphitiClient(driver, llm, embedder)

        inp = IOBuffer()
        out = IOBuffer()
        write(inp, JSON3.write(Dict("jsonrpc" => "2.0", "id" => 10, "method" => "tools/call",
            "params" => Dict("name" => "add_episode",
                "arguments" => Dict("name" => "ep1",
                    "content" => "Carol works here", "group_id" => "g")))))
        write(inp, "\n")
        write(inp, JSON3.write(Dict("jsonrpc" => "2.0", "id" => 11, "method" => "tools/call",
            "params" => Dict("name" => "search",
                "arguments" => Dict("query" => "Carol", "group_id" => "g")))))
        write(inp, "\n")
        write(inp, JSON3.write(Dict("jsonrpc" => "2.0", "id" => 12, "method" => "tools/call",
            "params" => Dict("name" => "get_entity",
                "arguments" => Dict("uuid" => "does-not-exist")))))
        write(inp, "\n")
        write(inp, JSON3.write(Dict("jsonrpc" => "2.0", "id" => 13, "method" => "bogus")))
        write(inp, "\n")
        seekstart(inp)
        Graphiti.mcp_serve(client; input = inp, output = out)

        lines = split(strip(String(take!(out))), "\n")
        @test length(lines) == 4
        r_add    = JSON3.read(lines[1], Dict)
        r_search = JSON3.read(lines[2], Dict)
        r_ge     = JSON3.read(lines[3], Dict)
        r_bogus  = JSON3.read(lines[4], Dict)

        @test occursin("Added episode", r_add["result"]["content"][1]["text"])
        @test haskey(r_search, "result")
        @test haskey(r_ge, "error")
        @test r_ge["error"]["code"] == -32602
        @test haskey(r_bogus, "error")
        @test r_bogus["error"]["code"] == -32601
    end

    @testset "MCP: parse error" begin
        driver = MemoryDriver()
        client = GraphitiClient(driver, EchoLLMClient(), DeterministicEmbedder(4))
        inp = IOBuffer()
        out = IOBuffer()
        write(inp, "not valid json\n")
        seekstart(inp)
        Graphiti.mcp_serve(client; input = inp, output = out)
        resp = JSON3.read(strip(String(take!(out))), Dict)
        @test haskey(resp, "error")
        @test resp["error"]["code"] == -32700
    end
end
