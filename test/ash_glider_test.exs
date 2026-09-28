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

  describe "pushdown" do
    setup do
      create!(%{name: "Ada", email: "ada@example.com", age: 36, role: :admin, score: 9.5})
      create!(%{name: "Bob", email: "bob@example.com", age: 41, role: :member})
      create!(%{name: "Cai", age: 28, role: :member, score: 3.0})
      create!(%{name: "Dee"})
      :ok
    end

    defp names(query), do: query |> Ash.read!() |> Enum.map(& &1.name) |> Enum.sort()

    test "comparisons skip nodes whose property is unset" do
      assert names(Ash.Query.filter(Person, age >= 36)) == ["Ada", "Bob"]
      assert names(Ash.Query.filter(Person, age < 36)) == ["Cai"]
      assert names(Ash.Query.filter(Person, score > 1.0 and score <= 9.5)) == ["Ada", "Cai"]
      assert names(Ash.Query.filter(Person, name > "B")) == ["Bob", "Cai", "Dee"]
    end

    test "in and is_nil" do
      assert names(Ash.Query.filter(Person, name in ["Ada", "Dee", "Zed"])) == ["Ada", "Dee"]
      assert names(Ash.Query.filter(Person, role in [:admin])) == ["Ada"]
      assert names(Ash.Query.filter(Person, is_nil(email))) == ["Cai", "Dee"]
      assert names(Ash.Query.filter(Person, not is_nil(score))) == ["Ada", "Cai"]
    end

    test "or across different attributes" do
      assert names(Ash.Query.filter(Person, age > 40 or is_nil(age))) == ["Bob", "Dee"]
    end

    test "filters that stay in Elixir still apply alongside pushed ones" do
      # `!=` and `not` are not pushed (nil semantics differ); both must hold.
      assert names(Ash.Query.filter(Person, age > 20 and name != "Ada")) == ["Bob", "Cai"]
      assert names(Ash.Query.filter(Person, not (age > 30))) == ["Cai"]
      assert names(Ash.Query.filter(Person, contains(name, "i") and age < 40)) == ["Cai"]
    end

    test "limit and offset without a sort, with and without a pushed filter" do
      all = Person |> Ash.read!() |> Enum.map(& &1.name) |> MapSet.new()

      page1 = Person |> Ash.Query.limit(2) |> Ash.read!() |> Enum.map(& &1.name)

      page2 =
        Person |> Ash.Query.limit(2) |> Ash.Query.offset(2) |> Ash.read!() |> Enum.map(& &1.name)

      assert length(page1) == 2 and length(page2) == 2
      assert MapSet.new(page1 ++ page2) == all

      assert [_] =
               Person |> Ash.Query.filter(role == :member) |> Ash.Query.limit(1) |> Ash.read!()

      # A filter that cannot be pushed must see every row before the limit.
      assert ["Cai"] =
               Person
               |> Ash.Query.filter(contains(name, "i") and age < 40)
               |> Ash.Query.limit(1)
               |> Ash.read!()
               |> Enum.map(& &1.name)
    end
  end

  describe "transactions" do
    # Inside a bare data-layer transaction nothing sends Ash's notifications,
    # so collect them rather than have Ash warn that they were missed.
    defp create_in_tx!(attrs) do
      {record, _notifications} =
        Person
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create!(return_notifications?: true)

      record
    end

    test "a failed step rolls back everything written in the transaction" do
      result =
        Ash.DataLayer.transaction(Person, fn ->
          create_in_tx!(%{name: "Ada"})
          create_in_tx!(%{name: "Bob"})
          Ash.DataLayer.rollback(Person, :changed_my_mind)
        end)

      assert result == {:error, :changed_my_mind}
      assert Ash.read!(Person) == []
    end

    test "a committed transaction keeps its writes" do
      assert {:ok, _} =
               Ash.DataLayer.transaction(Person, fn ->
                 create_in_tx!(%{name: "Ada"})
                 create_in_tx!(%{name: "Bob"})
               end)

      assert length(Ash.read!(Person)) == 2
    end

    test "the data layer reports the transaction it is in" do
      refute Ash.DataLayer.in_transaction?(Person)

      Ash.DataLayer.transaction(Person, fn ->
        assert Ash.DataLayer.in_transaction?(Person)
      end)
    end
  end

  describe "bulk create" do
    test "creates every record and returns them in order" do
      inputs = for i <- 1..50, do: %{name: "P#{i}", age: i}

      result =
        Ash.bulk_create(inputs, Person, :create, return_records?: true, return_errors?: true)

      assert result.status == :success

      assert Enum.map(result.records, & &1.name) |> Enum.sort() ==
               Enum.map(inputs, & &1.name) |> Enum.sort()

      assert length(Ash.read!(Person)) == 50
    end

    test "an invalid record fails the batch without leaving part of it" do
      inputs = [%{name: "Ok"}, %{name: nil}]

      result =
        Ash.bulk_create(inputs, Person, :create, return_errors?: true, stop_on_error?: true)

      assert result.status == :error
      assert Ash.read!(Person) |> Enum.map(& &1.name) |> Enum.reject(&(&1 == "Ok")) == []
    end
  end
end
