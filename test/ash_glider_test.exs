defmodule AshGliderTest do
  # Not async: every test shares one in-memory graph, started fresh per test.
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshGlider.Edge
  alias AshGlider.Test.{Company, Graph, Person}

  setup do
    start_supervised!(Graph)
    :ok
  end

  defp create!(attrs) do
    Person
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  defp company!(attrs) do
    Company
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  describe "create and read" do
    test "a record round-trips through the graph" do
      created = create!(%{name: "Ada", email: "ada@example.com", age: 36})

      assert [found] = Ash.read!(Person)
      assert found.id == created.id
      assert found.name == "Ada"
      assert found.email == "ada@example.com"
      assert found.age == 36
      # Defaults are applied by Ash and must survive the round trip.
      assert found.active == true
    end

    test "every supported attribute type survives the round trip" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      create!(%{
        name: "Typed",
        age: 41,
        active: false,
        score: 1.5,
        role: :admin,
        tags: ["a", "b"],
        settings: %{"theme" => "dark", "n" => 3},
        joined_at: now
      })

      assert [p] = Ash.read!(Person)
      assert p.age == 41
      assert p.active == false
      assert p.score == 1.5
      assert p.role == :admin
      assert p.tags == ["a", "b"]
      assert p.settings == %{"theme" => "dark", "n" => 3}
      assert DateTime.compare(p.joined_at, now) == :eq
    end

    test "nil attributes come back as nil" do
      create!(%{name: "Sparse"})

      assert [p] = Ash.read!(Person)
      assert p.email == nil
      assert p.age == nil
      assert p.tags == nil
    end

    test "resources with different labels do not see each other" do
      create!(%{name: "Ada"})
      company!(%{name: "Acme"})

      assert [%Person{name: "Ada"}] = Ash.read!(Person)
      assert [%Company{name: "Acme"}] = Ash.read!(Company)
    end
  end

  describe "filtering" do
    setup do
      create!(%{name: "Ada", email: "ada@example.com", age: 36, role: :admin})
      create!(%{name: "Bob", email: "bob@example.com", age: 41, role: :member})
      create!(%{name: "Cai", email: "cai@example.com", age: 28, role: :member})
      :ok
    end

    test "equality is pushed into the MATCH pattern" do
      assert [%{name: "Ada"}] = Person |> Ash.Query.filter(name == "Ada") |> Ash.read!()
    end

    test "equality on an indexed attribute" do
      assert [%{name: "Bob"}] =
               Person |> Ash.Query.filter(email == "bob@example.com") |> Ash.read!()
    end

    test "comparisons fall back to the runtime filter" do
      names =
        Person
        |> Ash.Query.filter(age > 30)
        |> Ash.read!()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["Ada", "Bob"]
    end

    test "boolean combinations" do
      names =
        Person
        |> Ash.Query.filter(age > 30 and role == :admin)
        |> Ash.read!()
        |> Enum.map(& &1.name)

      assert names == ["Ada"]

      names =
        Person
        |> Ash.Query.filter(name == "Ada" or name == "Cai")
        |> Ash.read!()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["Ada", "Cai"]
    end

    test "a pushed-down filter and a runtime filter together" do
      # `role` is pushed into the pattern, `age` is not; both must apply.
      names =
        Person
        |> Ash.Query.filter(role == :member and age < 30)
        |> Ash.read!()
        |> Enum.map(& &1.name)

      assert names == ["Cai"]
    end

    test "a filter matching nothing returns nothing" do
      assert [] = Person |> Ash.Query.filter(name == "Nobody") |> Ash.read!()
    end

    test "a value containing quotes does not break the generated query" do
      # The pushdown builds Cypher by hand, so this is the injection guard.
      hostile = ~S|Ro"bert; MATCH (n) DETACH DELETE n //|
      create!(%{name: hostile})

      assert [found] = Person |> Ash.Query.filter(name == ^hostile) |> Ash.read!()
      assert found.name == hostile
      # And nothing was deleted.
      assert length(Ash.read!(Person)) == 4
    end
  end

  describe "sort, limit, offset" do
    setup do
      for {n, a} <- [{"Ada", 36}, {"Bob", 41}, {"Cai", 28}], do: create!(%{name: n, age: a})
      :ok
    end

    test "sorting" do
      assert ["Cai", "Ada", "Bob"] =
               Person |> Ash.Query.sort(age: :asc) |> Ash.read!() |> Enum.map(& &1.name)

      assert ["Bob", "Ada", "Cai"] =
               Person |> Ash.Query.sort(age: :desc) |> Ash.read!() |> Enum.map(& &1.name)
    end

    test "limit and offset" do
      assert ["Cai", "Ada"] =
               Person
               |> Ash.Query.sort(age: :asc)
               |> Ash.Query.limit(2)
               |> Ash.read!()
               |> Enum.map(& &1.name)

      assert ["Ada", "Bob"] =
               Person
               |> Ash.Query.sort(age: :asc)
               |> Ash.Query.offset(1)
               |> Ash.read!()
               |> Enum.map(& &1.name)
    end
  end

  describe "update and destroy" do
    test "update changes the stored node" do
      ada = create!(%{name: "Ada", age: 36})

      updated =
        ada
        |> Ash.Changeset.for_update(:update, %{age: 37, email: "new@example.com"})
        |> Ash.update!()

      assert updated.age == 37
      assert [found] = Ash.read!(Person)
      assert found.age == 37
      assert found.email == "new@example.com"
      assert found.id == ada.id
    end

    test "update can set an attribute back to nil" do
      ada = create!(%{name: "Ada", email: "ada@example.com"})

      ada
      |> Ash.Changeset.for_update(:update, %{email: nil})
      |> Ash.update!()

      assert [%{email: nil}] = Ash.read!(Person)
    end

    test "destroy removes the node" do
      ada = create!(%{name: "Ada"})
      create!(%{name: "Bob"})

      :ok = Ash.destroy!(ada)

      assert [%{name: "Bob"}] = Ash.read!(Person)
    end

    test "destroy takes the node's edges with it" do
      ada = create!(%{name: "Ada"})
      bob = create!(%{name: "Bob"})
      :ok = Edge.relate(ada, :KNOWS, bob)

      :ok = Ash.destroy!(bob)

      # A dangling edge would corrupt every traversal through this node.
      assert {:ok, []} = Edge.related(ada, :KNOWS)
    end
  end

  describe "aggregates" do
    test "count through the data layer" do
      for n <- ["Ada", "Bob", "Cai"], do: create!(%{name: n})

      assert 3 = Person |> Ash.Query.filter(not is_nil(name)) |> Ash.count!()
    end
  end

  describe "edges" do
    setup do
      ada = create!(%{name: "Ada"})
      bob = create!(%{name: "Bob"})
      cai = create!(%{name: "Cai"})
      %{ada: ada, bob: bob, cai: cai}
    end

    test "relate and traverse one hop", %{ada: ada, bob: bob} do
      :ok = Edge.relate(ada, :KNOWS, bob, %{since: 2019})

      assert {:ok, [found]} = Edge.related(ada, :KNOWS)
      assert found.id == bob.id
    end

    test "edge properties are stored", %{ada: ada, bob: bob} do
      :ok = Edge.relate(ada, :KNOWS, bob, %{since: 2019})

      assert {:ok, [%{type: "KNOWS", props: %{"since" => 2019}}]} = Edge.edges_between(ada, bob)
    end

    test "direction matters", %{ada: ada, bob: bob} do
      :ok = Edge.relate(ada, :KNOWS, bob)

      assert {:ok, []} = Edge.related(bob, :KNOWS)
      assert {:ok, [found]} = Edge.related(bob, :KNOWS, direction: :in)
      assert found.id == ada.id

      assert {:ok, [_]} = Edge.related(bob, :KNOWS, direction: :both)
    end

    test "variable-length traversal", %{ada: ada, bob: bob, cai: cai} do
      :ok = Edge.relate(ada, :KNOWS, bob)
      :ok = Edge.relate(bob, :KNOWS, cai)

      # One hop reaches Bob only.
      assert {:ok, [one]} = Edge.related(ada, :KNOWS)
      assert one.id == bob.id

      # Up to three reaches both — the thing a foreign key cannot express.
      assert {:ok, reached} = Edge.related(ada, :KNOWS, depth: 1..3)
      assert Enum.sort(Enum.map(reached, & &1.id)) == Enum.sort([bob.id, cai.id])
    end

    test "unrelate removes the edge", %{ada: ada, bob: bob} do
      :ok = Edge.relate(ada, :KNOWS, bob)
      assert {:ok, 1} = Edge.unrelate(ada, :KNOWS, bob)
      assert {:ok, []} = Edge.related(ada, :KNOWS)
    end

    test "relating across resources", %{ada: ada} do
      acme = company!(%{name: "Acme"})
      :ok = Edge.relate(ada, :WORKS_AT, acme)

      assert {:ok, [found]} = Edge.related(ada, :WORKS_AT, destination: Company)
      assert found.id == acme.id
      assert %Company{} = found
    end

    test "shortest path", %{ada: ada, bob: bob, cai: cai} do
      :ok = Edge.relate(ada, :KNOWS, bob)
      :ok = Edge.relate(bob, :KNOWS, cai)

      assert {:ok, path} = Edge.path(ada, cai)
      assert Enum.map(path, & &1.id) == [ada.id, bob.id, cai.id]
    end

    test "relating a record that is not stored is an error", %{ada: ada} do
      ghost = %Person{id: Ash.UUID.generate(), name: "Ghost"}
      assert {:error, :endpoint_not_found} = Edge.relate(ada, :KNOWS, ghost)
    end
  end

  describe "algorithms" do
    test "pagerank runs over the stored graph and can write back" do
      ada = create!(%{name: "Ada"})
      bob = create!(%{name: "Bob"})
      cai = create!(%{name: "Cai"})

      :ok = Edge.relate(ada, :KNOWS, bob)
      :ok = Edge.relate(cai, :KNOWS, bob)

      assert {:ok, rows} = Edge.algorithm(Person, :pagerank, iterations: 20, top: 3)
      assert length(rows) == 3

      # Written back as an ordinary property, readable by anything.
      assert {:ok, _} = Edge.algorithm(Person, :pagerank, iterations: 20, write: "rank")

      handle = AshGlider.Info.handle(Person)
      {:ok, result} = Glider.query(handle, "MATCH (n:Person) RETURN n.name, n.rank")
      assert Enum.all?(result.rows, fn [_name, rank] -> is_float(rank) end)

      # Bob is pointed at twice, so he must outrank the others.
      [[top_name, _] | _] = Enum.sort_by(result.rows, fn [_n, r] -> r end, :desc)
      assert top_name == "Bob"
    end

    test "components" do
      ada = create!(%{name: "Ada"})
      bob = create!(%{name: "Bob"})
      _isolated = create!(%{name: "Loner"})
      :ok = Edge.relate(ada, :KNOWS, bob)

      assert {:ok, rows} = Edge.algorithm(Person, :components, top: 5)
      assert is_list(rows)
    end
  end

  describe "introspection" do
    test "label defaults to the last module segment" do
      assert AshGlider.Info.label(Company) == :Company
      assert AshGlider.Info.label(Person) == :Person
    end

    test "source/1 reports the label" do
      assert AshGlider.DataLayer.source(Person) == "Person"
    end
  end
end
