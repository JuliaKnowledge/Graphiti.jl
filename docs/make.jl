using Documenter
using Graphiti

makedocs(
    sitename  = "Graphiti.jl",
    modules   = [Graphiti],
    doctest   = false,
    warnonly  = true,
    format    = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
    ),
    pages = [
        "Home"      => "index.md",
        "Guides"    => [
            "Concepts"        => "guide/concepts.md",
            "Ingestion"       => "guide/ingestion.md",
            "Search"          => "guide/search.md",
            "Communities"     => "guide/communities.md",
            "Agent Memory"    => "guide/agent_memory.md",
        ],
        "API Reference" => "api.md",
    ],
)

deploydocs(
    repo   = "github.com/your-org/Graphiti.jl.git",
    branch = "gh-pages",
    devbranch = "master",
)
