defmodule Explorer.QueryBuilderTest do
  use ExplorerWeb.ConnCase
  alias Explorer.QueryBuilder

  test "equality is pushed down, the rest runs in Elixir" do
    {:ok, r} =
      QueryBuilder.run(
        Person,
        [
          %{"field" => "city", "op" => "eq", "value" => "Seattle"},
          %{"field" => "age", "op" => "gt", "value" => "40"}
        ],
        :name,
        "asc",
        nil
      )

    assert Enum.map(r.records, & &1.name) == ["Anders Hejlsberg", "Radia Perlman"]
    assert r.plan.cypher == ~S|MATCH (n:Person {city: "Seattle"}) RETURN n|
    assert [%{op: "eq"}] = r.plan.pushed
    assert [%{op: "gt"}] = r.plan.runtime
    assert r.code =~ ~S|Ash.Query.filter(city == "Seattle" and age > 40)|
  end

  test "contains, in, has, and present" do
    run = fn conds -> QueryBuilder.run(Person, conds, :name, "asc", nil) end

    {:ok, r} = run.([%{"field" => "name", "op" => "contains", "value" => "valim"}])
    assert Enum.map(r.records, & &1.name) == ["José Valim"]

    {:ok, r} = run.([%{"field" => "role", "op" => "in", "value" => "founder, designer"}])
    assert r.records != []
    assert Enum.all?(r.records, &(&1.role in [:founder, :designer]))

    {:ok, r} = run.([%{"field" => "skills", "op" => "has", "value" => "zig"}])
    assert Enum.map(r.records, & &1.name) == ["Andrew Kelley", "Mitchell Hashimoto"]

    {:ok, r} = run.([%{"field" => "rank", "op" => "present", "value" => ""}])
    assert length(r.records) == 24
  end

  test "bad values are reported, not raised" do
    assert {:error, msg} =
             QueryBuilder.run(
               Person,
               [%{"field" => "age", "op" => "gt", "value" => "old"}],
               :name,
               "asc",
               nil
             )

    assert msg =~ "not a valid age"
  end
end
