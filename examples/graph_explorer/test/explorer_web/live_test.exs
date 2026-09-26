defmodule ExplorerWeb.LiveTest do
  use ExplorerWeb.ConnCase

  defp first_column(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody tr td:first-child a")
    |> Enum.map(&LazyHTML.text/1)
  end

  test "overview renders counts and the canvas", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Overview"
    assert has_element?(view, "#overview-graph[phx-hook=Graph]")
    assert html =~ "Most central"
  end

  test "browse, search, sort and paginate", %{conn: conn} do
    {:ok, view, _} = live(conn, "/r/people")
    assert has_element?(view, "td a", "Ada Lovelace")
    assert render(view) =~ "Page 1 of 2"

    html = view |> form("form.search", q: "valim") |> render_change()
    assert_patch(view, "/r/people?q=valim")
    assert html =~ "José Valim"
    refute html =~ "Ada Lovelace"

    {:ok, view, _} = live(conn, "/r/people?sort=age&dir=desc")
    assert hd(first_column(view)) == "Barbara Liskov"

    {:ok, view, _} = live(conn, "/r/people?page=2")
    assert render(view) =~ "Page 2 of 2"
    assert length(first_column(view)) == 24 - 15
  end

  test "create a record with validation", %{conn: conn} do
    {:ok, view, _} = live(conn, "/r/projects/new")

    html = view |> form("#record-form", record: %{name: ""}) |> render_submit()
    assert html =~ "is required"

    {:ok, _view, html} =
      view
      |> form("#record-form",
        record: %{name: "Gleam", language: "Gleam", stars: "18000", status: "active"}
      )
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Created Gleam"
    assert project!("Gleam").stars == 18000
  end

  test "edit a record, including an array attribute", %{conn: conn} do
    ada = person!("Ada Lovelace")
    {:ok, view, _} = live(conn, "/r/people/#{ada.id}/edit")

    view
    |> form("#record-form", record: %{city: "Cambridge", skills: "math, poetry"})
    |> render_submit()

    assert_patch(view, "/r/people/#{ada.id}")
    ada = person!("Ada Lovelace")
    assert ada.city == "Cambridge"
    assert ada.skills == ["math", "poetry"]
  end

  test "delete a record", %{conn: conn} do
    grace = person!("Grace Hopper")
    {:ok, view, _} = live(conn, "/r/people/#{grace.id}")
    {:ok, _, html} = view |> render_click("delete_record") |> follow_redirect(conn)
    assert html =~ "Deleted Grace Hopper"
    assert nil == person!("Grace Hopper")
  end

  test "add, edit and remove an edge from the record page", %{conn: conn} do
    ada = person!("Ada Lovelace")
    dashbit = company!("Dashbit")
    {:ok, view, _} = live(conn, "/r/people/#{ada.id}")

    view |> form("#new-edge", edge: %{choice: "out:WORKS_AT"}) |> render_change()

    html =
      view
      |> form("#new-edge",
        edge: %{
          choice: "out:WORKS_AT",
          target: dashbit.id,
          props: %{title: "Advisor", since: "2024"}
        }
      )
      |> render_submit()

    assert html =~ "Ada Lovelace -[:WORKS_AT]-&gt; Dashbit"
    edge = Enum.find(GraphOps.edges_of(ada), &(&1.other.name == "Dashbit"))
    assert edge.props == %{"title" => "Advisor", "since" => 2024}

    render_click(view, "edge_edit", %{"id" => to_string(edge.id)})
    view |> form("#edge-form-#{edge.id}", props: %{title: "Chair"}) |> render_submit()
    assert {:ok, %{props: %{"title" => "Chair"}}} = GraphOps.fetch_edge(edge.id)

    render_click(view, "edge_delete", %{"id" => edge.id})
    refute has_element?(view, "#edge-#{edge.id}")
  end

  test "incoming edges can be created from the target's page", %{conn: conn} do
    elixir = project!("Elixir")
    ada = person!("Ada Lovelace")
    {:ok, view, _} = live(conn, "/r/projects/#{elixir.id}")

    view |> form("#new-edge", edge: %{choice: "in:CONTRIBUTES_TO"}) |> render_change()

    view
    |> form("#new-edge",
      edge: %{choice: "in:CONTRIBUTES_TO", target: ada.id, props: %{commits: "3"}}
    )
    |> render_submit()

    assert Enum.any?(
             GraphOps.edges_of(ada),
             &(&1.type == "CONTRIBUTES_TO" and &1.other.name == "Elixir")
           )
  end

  test "traverse and shortest path panels", %{conn: conn} do
    joe = person!("Joe Armstrong")
    {:ok, view, _} = live(conn, "/r/people/#{joe.id}")

    html =
      view
      |> form("#traverse", traverse: %{type: "KNOWS", direction: "out", min: "1", max: "3"})
      |> render_submit()

    assert html =~ "Zach Daniel"
    assert html =~ "depth: 1..3"

    view |> form("#path", path: %{resource: "projects"}) |> render_change()

    html =
      view
      |> form("#path", path: %{resource: "projects", target: project!("Ash").id})
      |> render_submit()

    assert html =~ "hops"
    assert html =~ ~s|<ol class="path">|
  end

  test "neighbourhood depth toggle", %{conn: conn} do
    joe = person!("Joe Armstrong")
    {:ok, view, _} = live(conn, "/r/people/#{joe.id}")
    one = view |> element("#neighbourhood") |> render()
    view |> form("form.seg", depth: "2") |> render_change()
    two = view |> element("#neighbourhood") |> render()
    assert byte_size(two) > byte_size(one)
  end

  test "graph clicks navigate", %{conn: conn} do
    ada = person!("Ada Lovelace")
    {:ok, view, _} = live(conn, "/")

    assert {:error, {:live_redirect, %{to: to}}} =
             render_hook(view, "graph_click", %{"href" => Catalog.path(ada)})

    assert to == Catalog.path(ada)
  end

  test "query builder: presets, conditions and plan", %{conn: conn} do
    {:ok, view, html} = live(conn, "/query")
    assert html =~ "MATCH (n:Person {city: &quot;Seattle&quot;}) RETURN n"

    html = render_click(view, "preset", %{"i" => "2"})
    assert html =~ "in Elixir"
    assert html =~ "Frances Allen"
    refute html =~ "Grace Hopper"

    html = render_click(view, "add_condition", %{})
    assert html =~ "cond-2"
  end

  test "cypher tab renders rows, graph and errors", %{conn: conn} do
    {:ok, view, _} = live(conn, "/query?tab=cypher")

    html =
      view
      |> form("#cypher-form", cypher: "MATCH (p:Person)-[r:WORKS_AT]->(c:Company) RETURN p, r, c")
      |> render_submit()

    assert html =~ "10 rows"
    assert has_element?(view, "#cypher-graph")

    html = view |> form("#cypher-form", cypher: "MATCH (n RETURN n") |> render_submit()
    assert html =~ "glider: expected"
  end

  test "algorithms tab", %{conn: conn} do
    {:ok, view, _} = live(conn, "/query?tab=algorithms")
    html = view |> form("#algo-form", algo: %{name: "degree", top: "5"}) |> render_submit()
    assert html =~ "degree"
    assert html =~ "José Valim"
  end
end
