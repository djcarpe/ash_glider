defmodule Explorer.GraphOpsTest do
  use ExplorerWeb.ConnCase

  test "the seed graph has every label and edge type" do
    o = GraphOps.overview()
    assert o.nodes == 24 + 7 + 12
    assert Enum.map(o.labels, & &1.name) |> Enum.sort() == ~w(Company Person Project)

    assert Enum.map(o.edge_types, & &1.name) |> Enum.sort() ==
             ~w(CONTRIBUTES_TO DEPENDS_ON KNOWS SPONSORS WORKS_AT)
  end

  test "edges_of lists both directions with the other end resolved" do
    jose = person!("José Valim")
    edges = GraphOps.edges_of(jose)

    assert Enum.find(
             edges,
             &(&1.type == "KNOWS" and &1.direction == :in and &1.other.name == "Joe Armstrong")
           )

    assert %{
             direction: :out,
             props: %{"title" => "Founder"},
             other: %{path: "/r/companies/" <> _}
           } =
             Enum.find(edges, &(&1.type == "WORKS_AT"))
  end

  test "create, update and delete an edge" do
    ada = person!("Ada Lovelace")
    elixir = project!("Elixir")

    assert :ok = GraphOps.create_edge(ada, "CONTRIBUTES_TO", elixir, %{"commits" => "7"})
    edge = Enum.find(GraphOps.edges_of(ada), &(&1.other.name == "Elixir"))
    assert edge.props == %{"commits" => 7}

    assert :ok = GraphOps.update_edge(edge.id, %{"commits" => "9"})
    assert {:ok, %Glider.Rel{props: %{"commits" => 9}}} = GraphOps.fetch_edge(edge.id)

    assert :ok = GraphOps.delete_edge(edge.id)
    refute Enum.any?(GraphOps.edges_of(ada), &(&1.other.name == "Elixir"))
  end

  test "create_edge refuses unknown types, wrong endpoints and bad props" do
    ada = person!("Ada Lovelace")
    elixir = project!("Elixir")

    assert {:error, "unknown edge type" <> _} = GraphOps.create_edge(ada, "PWNS", elixir)

    assert {:error, "KNOWS connects Person to Person"} =
             GraphOps.create_edge(ada, "KNOWS", elixir)

    assert {:error, "commits must be integer"} =
             GraphOps.create_edge(ada, "CONTRIBUTES_TO", elixir, %{"commits" => "lots"})
  end

  test "traverse follows an edge type to depth, into the right resource" do
    joe = person!("Joe Armstrong")

    {:ok, one} = GraphOps.traverse(joe, "KNOWS", :out, 1, 1)
    {:ok, two} = GraphOps.traverse(joe, "KNOWS", :out, 1, 2)
    assert Enum.map(one, & &1.name) |> Enum.sort() == ["Barbara Liskov", "José Valim"]
    assert "Zach Daniel" in Enum.map(two, & &1.name)

    {:ok, [company]} = GraphOps.traverse(joe, "WORKS_AT", :out, 1, 1)
    assert %Explorer.Directory.Company{name: "Ericsson"} = company
  end

  test "path crosses resource types" do
    {:ok, steps} = GraphOps.path(person!("Zach Daniel"), project!("Erlang/OTP"))
    labels = Enum.map(steps, & &1.label)
    assert hd(steps).name == "Zach Daniel"
    assert List.last(steps).name == "Erlang/OTP"
    assert "Project" in labels and "Person" in labels
  end

  test "pagerank writes rank, readable through Ash" do
    Explorer.Directory.Person |> Ash.read!() |> Enum.each(&assert(is_float(&1.rank)))
    {:ok, %{rows: rows}} = GraphOps.algorithm("pagerank", top: 3)
    assert length(rows) == 3
    assert Enum.all?(rows, &(&1.path && &1.name))
  end

  test "destroying a record removes its edges" do
    jose = person!("José Valim")
    before = GraphOps.overview().edges
    n = length(GraphOps.edges_of(jose))
    Ash.destroy!(jose)
    assert GraphOps.overview().edges == before - n
  end
end
