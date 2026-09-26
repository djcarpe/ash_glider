defmodule Explorer.Seeds do
  @moduledoc """
  A small, deterministic demo graph: people who know each other, the companies
  they work at, the projects they contribute to, and how those projects depend
  on and are funded by one another.

  Every record goes through an Ash create action; every edge through
  `AshGlider.Edge.relate/4` (via `Explorer.GraphOps.create_edge/4`).
  """

  require Logger
  alias Explorer.{Directory, GraphOps}

  @people [
    {"Ada Lovelace", :researcher, "London", 36, ~w(math compilers)},
    {"Grace Hopper", :engineer, "New York", 45, ~w(compilers cobol)},
    {"Alan Turing", :researcher, "Manchester", 41, ~w(math crypto)},
    {"Katherine Johnson", :researcher, "Hampton", 50, ~w(math orbital)},
    {"Linus Torvalds", :engineer, "Portland", 54, ~w(c kernels git)},
    {"Margaret Hamilton", :manager, "Boston", 60, ~w(apollo reliability)},
    {"José Valim", :founder, "Kraków", 40, ~w(elixir erlang)},
    {"Joe Armstrong", :researcher, "Stockholm", 68, ~w(erlang distributed)},
    {"Chris McCord", :engineer, "Charlotte", 38, ~w(elixir phoenix)},
    {"Zach Daniel", :engineer, "Seattle", 33, ~w(elixir ash)},
    {"Barbara Liskov", :researcher, "Boston", 84, ~w(types distributed)},
    {"Radia Perlman", :engineer, "Seattle", 72, ~w(networking)},
    {"Guido van Rossum", :engineer, "San Francisco", 68, ~w(python)},
    {"Yukihiro Matsumoto", :founder, "Matsue", 59, ~w(ruby)},
    {"Anders Hejlsberg", :engineer, "Seattle", 63, ~w(typescript csharp)},
    {"Hedy Lamarr", :designer, "Vienna", 45, ~w(radio design)},
    {"Frances Allen", :researcher, "New York", 60, ~w(compilers optimization)},
    {"Ken Thompson", :engineer, "San Francisco", 80, ~w(unix go)},
    {"Rob Pike", :engineer, "Sydney", 67, ~w(go plan9)},
    {"Sophie Wilson", :designer, "Cambridge", 66, ~w(arm cpu)},
    {"Tim Berners-Lee", :founder, "London", 69, ~w(web http)},
    {"Mitchell Hashimoto", :founder, "Los Angeles", 34, ~w(zig terminals)},
    {"Andrew Kelley", :engineer, "Portland", 36, ~w(zig)},
    {"Evan You", :designer, "Singapore", 36, ~w(vue javascript)}
  ]

  @companies [
    {"Analytical Engines", "hardware", "London", 1843, false},
    {"Dashbit", "software", "Kraków", 2019, false},
    {"Ericsson", "telecom", "Stockholm", 1876, true},
    {"Bell Labs", "research", "Murray Hill", 1925, false},
    {"NASA", "aerospace", "Washington", 1958, false},
    {"Alembic", "software", "Seattle", 2021, false},
    {"Acorn", "hardware", "Cambridge", 1978, true}
  ]

  @projects [
    {"Elixir", "A dynamic, functional language for maintainable applications", "Elixir", :active,
     24000},
    {"Erlang/OTP", "Build massively scalable soft real-time systems", "Erlang", :maintained,
     11000},
    {"Phoenix", "Peace of mind from prototype to production", "Elixir", :active, 21000},
    {"Ash", "A declarative, resource-oriented application framework", "Elixir", :active, 1800},
    {"glider", "An embeddable property-graph database", "Rust", :active, 120},
    {"Linux", "The operating system kernel", "C", :active, 180_000},
    {"Git", "Distributed version control", "C", :maintained, 52000},
    {"Go", "A language for simple, reliable software", "Go", :active, 122_000},
    {"Python", "The Python programming language", "Python", :active, 62000},
    {"TypeScript", "JavaScript with syntax for types", "TypeScript", :active, 100_000},
    {"Zig", "General-purpose language and toolchain", "Zig", :active, 34000},
    {"COBOL", "Common business-oriented language", "COBOL", :archived, 40}
  ]

  @knows [
    {"Ada Lovelace", "Alan Turing", 1936},
    {"Alan Turing", "Grace Hopper", 1946},
    {"Grace Hopper", "Frances Allen", 1957},
    {"Frances Allen", "Barbara Liskov", 1968},
    {"Barbara Liskov", "Radia Perlman", 1980},
    {"Radia Perlman", "Linus Torvalds", 1995},
    {"Katherine Johnson", "Margaret Hamilton", 1966},
    {"Margaret Hamilton", "Grace Hopper", 1970},
    {"Ken Thompson", "Rob Pike", 1980},
    {"Rob Pike", "Linus Torvalds", 2005},
    {"Ken Thompson", "Linus Torvalds", 1998},
    {"Joe Armstrong", "José Valim", 2011},
    {"José Valim", "Chris McCord", 2014},
    {"José Valim", "Zach Daniel", 2019},
    {"Chris McCord", "Zach Daniel", 2020},
    {"Joe Armstrong", "Barbara Liskov", 1990},
    {"Guido van Rossum", "Anders Hejlsberg", 2010},
    {"Anders Hejlsberg", "Evan You", 2016},
    {"Yukihiro Matsumoto", "José Valim", 2008},
    {"Mitchell Hashimoto", "Andrew Kelley", 2022},
    {"Andrew Kelley", "Linus Torvalds", 2019},
    {"Sophie Wilson", "Tim Berners-Lee", 1989},
    {"Tim Berners-Lee", "Ada Lovelace", 2015},
    {"Hedy Lamarr", "Radia Perlman", 1997},
    {"Evan You", "Chris McCord", 2021}
  ]

  @works_at [
    {"Ada Lovelace", "Analytical Engines", "Mathematician", 1842},
    {"José Valim", "Dashbit", "Founder", 2019},
    {"Joe Armstrong", "Ericsson", "Engineer", 1986},
    {"Ken Thompson", "Bell Labs", "Researcher", 1966},
    {"Rob Pike", "Bell Labs", "Researcher", 1980},
    {"Katherine Johnson", "NASA", "Mathematician", 1953},
    {"Margaret Hamilton", "NASA", "Director", 1965},
    {"Zach Daniel", "Alembic", "Engineer", 2022},
    {"Sophie Wilson", "Acorn", "Designer", 1978},
    {"Frances Allen", "Bell Labs", "Fellow", 1970}
  ]

  @contributes [
    {"José Valim", "Elixir", 12000},
    {"Chris McCord", "Elixir", 300},
    {"Joe Armstrong", "Erlang/OTP", 5000},
    {"Chris McCord", "Phoenix", 8000},
    {"José Valim", "Phoenix", 1500},
    {"Zach Daniel", "Ash", 9000},
    {"Zach Daniel", "Phoenix", 120},
    {"Linus Torvalds", "Linux", 30000},
    {"Linus Torvalds", "Git", 1200},
    {"Radia Perlman", "Linux", 40},
    {"Ken Thompson", "Go", 900},
    {"Rob Pike", "Go", 4000},
    {"Guido van Rossum", "Python", 11000},
    {"Anders Hejlsberg", "TypeScript", 6000},
    {"Andrew Kelley", "Zig", 15000},
    {"Mitchell Hashimoto", "Zig", 300},
    {"Grace Hopper", "COBOL", 2000},
    {"Ada Lovelace", "glider", 42}
  ]

  @sponsors [
    {"Dashbit", "Elixir", 50000},
    {"Dashbit", "Phoenix", 20000},
    {"Ericsson", "Erlang/OTP", 250_000},
    {"Alembic", "Ash", 40000},
    {"Bell Labs", "Go", 10000},
    {"Analytical Engines", "glider", 1000}
  ]

  @depends_on [
    {"Elixir", "Erlang/OTP"},
    {"Phoenix", "Elixir"},
    {"Ash", "Elixir"},
    {"Ash", "glider"},
    {"Git", "Linux"},
    {"Zig", "Linux"},
    {"TypeScript", "Python"}
  ]

  @doc "Seed if the graph holds no people yet. Returns :seeded or :skipped."
  def seed_if_empty do
    if Map.get(GraphOps.label_counts(), "Person", 0) == 0 do
      run!()
      :seeded
    else
      :skipped
    end
  end

  @doc "Wipe everything and seed again."
  def reset! do
    GraphOps.wipe!()
    run!()
  end

  def run! do
    people =
      Map.new(@people, fn {name, role, city, age, skills} ->
        # Strip accents first, so "José" becomes "jose" rather than "jos".
        email =
          name
          |> :unicode.characters_to_nfd_binary()
          |> String.replace(~r/\p{Mn}/u, "")
          |> String.downcase()
          |> String.replace(~r/[^a-z]+/, ".")
          |> Kernel.<>("@example.com")

        {name,
         Directory.create_person!(%{
           name: name,
           email: email,
           role: role,
           city: city,
           age: age,
           skills: skills
         })}
      end)

    companies =
      Map.new(@companies, fn {name, industry, city, founded, listed} ->
        {name,
         Directory.create_company!(%{
           name: name,
           industry: industry,
           city: city,
           founded: founded,
           listed: listed
         })}
      end)

    projects =
      Map.new(@projects, fn {name, description, language, status, stars} ->
        {name,
         Directory.create_project!(%{
           name: name,
           description: description,
           language: language,
           status: status,
           stars: stars
         })}
      end)

    for {a, b, since} <- @knows, do: edge!(people[a], "KNOWS", people[b], %{since: since})

    for {p, c, title, since} <- @works_at,
        do: edge!(people[p], "WORKS_AT", companies[c], %{title: title, since: since})

    for {p, pr, commits} <- @contributes,
        do: edge!(people[p], "CONTRIBUTES_TO", projects[pr], %{commits: commits})

    for {c, pr, amount} <- @sponsors,
        do: edge!(companies[c], "SPONSORS", projects[pr], %{amount: amount})

    for {a, b} <- @depends_on, do: edge!(projects[a], "DEPENDS_ON", projects[b], %{})

    # Store PageRank as each node's `rank`, so it can be sorted on through Ash.
    {:ok, _} = GraphOps.algorithm("pagerank", write: true)

    Logger.info(
      "Seeded #{map_size(people)} people, #{map_size(companies)} companies, #{map_size(projects)} projects"
    )

    :ok
  end

  defp edge!(from, type, to, props) do
    :ok = GraphOps.create_edge(from, type, to, props)
  end
end
