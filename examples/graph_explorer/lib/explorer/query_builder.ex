defmodule Explorer.QueryBuilder do
  @moduledoc """
  Turns the query page's form state into an `Ash.Query`, plus two views of it:
  the Elixir you would write by hand, and what the glider data layer pushes
  into its `MATCH` pattern versus what `Ash.Filter.Runtime` evaluates.
  """

  require Ash.Query
  import Ash.Expr

  alias AshGlider.DataLayer

  @ops %{
    "eq" => "==",
    "not_eq" => "!=",
    "gt" => ">",
    "gte" => ">=",
    "lt" => "<",
    "lte" => "<=",
    "contains" => "contains",
    "in" => "in",
    "has" => "has",
    "is_nil" => "is nil",
    "present" => "is present"
  }

  def op_label(op), do: @ops[op]

  @doc "The operators that make sense for an attribute's type."
  def ops_for(%{type: {:array, _}}), do: ~w(has is_nil present)
  def ops_for(%{type: Ash.Type.String}), do: ~w(eq not_eq contains in is_nil present)
  def ops_for(%{type: Ash.Type.Boolean}), do: ~w(eq is_nil present)
  def ops_for(%{type: Ash.Type.Atom}), do: ~w(eq not_eq in is_nil present)
  def ops_for(%{type: Ash.Type.UUID}), do: ~w(eq in)
  def ops_for(_), do: ~w(eq not_eq gt gte lt lte in is_nil present)

  @doc """
  Build and run. `conditions` is a list of `%{"field", "op", "value"}`.
  Returns `{:ok, %{records, micros, code, plan}}` or `{:error, message}`.
  """
  def run(resource, conditions, sort_field, sort_dir, limit) do
    with {:ok, compiled} <- compile(resource, conditions) do
      query =
        Enum.reduce(compiled, Ash.Query.new(resource), fn c, q ->
          Ash.Query.do_filter(q, c.expr)
        end)

      query =
        if sort_field,
          do: Ash.Query.sort(query, [{sort_field, sort_order(sort_dir)}]),
          else: query

      query = if limit, do: Ash.Query.limit(query, limit), else: query

      {micros, result} = :timer.tc(fn -> Ash.read(query) end)

      case result do
        {:ok, records} ->
          {:ok,
           %{
             records: records,
             micros: micros,
             code: code(resource, compiled, sort_field, sort_dir, limit),
             plan: plan(resource, compiled)
           }}

        {:error, error} ->
          {:error, Exception.message(error)}
      end
    end
  end

  @doc "Nils last in both directions, so unranked records never lead."
  def sort_order("desc"), do: :desc_nils_last
  def sort_order(_), do: :asc_nils_last

  defp compile(resource, conditions) do
    Enum.reduce_while(conditions, {:ok, []}, fn c, {:ok, acc} ->
      case compile_one(resource, c) do
        {:ok, compiled} -> {:cont, {:ok, acc ++ [compiled]}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp compile_one(resource, %{"field" => field, "op" => op} = c) do
    attr =
      Enum.find(Ash.Resource.Info.public_attributes(resource), &(to_string(&1.name) == field))

    raw = String.trim(c["value"] || "")

    cond do
      is_nil(attr) ->
        {:error, "unknown attribute #{field}"}

      op not in ops_for(attr) ->
        {:error, "#{op_label(op)} does not apply to #{field}"}

      op == "is_nil" ->
        {:ok, %{attr: attr, op: op, value: nil, expr: expr(is_nil(^ref(attr.name)))}}

      op == "present" ->
        {:ok, %{attr: attr, op: op, value: nil, expr: expr(not is_nil(^ref(attr.name)))}}

      op == "contains" ->
        needle = String.downcase(raw)

        {:ok,
         %{
           attr: attr,
           op: op,
           value: raw,
           expr: expr(contains(string_downcase(^ref(attr.name)), ^needle))
         }}

      op == "has" ->
        {:ok, %{attr: attr, op: op, value: raw, expr: expr(^raw in ^ref(attr.name))}}

      op == "in" ->
        values = raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        with {:ok, cast} <- cast_all(attr, values) do
          {:ok, %{attr: attr, op: op, value: cast, expr: expr(^ref(attr.name) in ^cast)}}
        end

      true ->
        with {:ok, value} <- cast(attr, raw) do
          e =
            case op do
              "eq" -> expr(^ref(attr.name) == ^value)
              "not_eq" -> expr(^ref(attr.name) != ^value)
              "gt" -> expr(^ref(attr.name) > ^value)
              "gte" -> expr(^ref(attr.name) >= ^value)
              "lt" -> expr(^ref(attr.name) < ^value)
              "lte" -> expr(^ref(attr.name) <= ^value)
            end

          {:ok, %{attr: attr, op: op, value: value, expr: e}}
        end
    end
  end

  defp cast(attr, raw) do
    case Ash.Type.cast_input(attr.type, raw, attr.constraints) do
      {:ok, nil} -> {:error, "#{attr.name} needs a value"}
      {:ok, v} -> {:ok, v}
      _ -> {:error, "#{inspect(raw)} is not a valid #{attr.name}"}
    end
  end

  defp cast_all(attr, values) do
    Enum.reduce_while(values, {:ok, []}, fn v, {:ok, acc} ->
      case cast(attr, v) do
        {:ok, c} -> {:cont, {:ok, acc ++ [c]}}
        error -> {:halt, error}
      end
    end)
  end

  # ------------------------------------------------------------------- views

  @doc "The Elixir you would write to run the same query."
  def code(resource, compiled, sort_field, sort_dir, limit) do
    filter =
      case compiled do
        [] -> nil
        list -> "|> Ash.Query.filter(" <> Enum.map_join(list, " and ", &expr_text/1) <> ")"
      end

    [
      "require Ash.Query",
      "",
      inspect(resource),
      filter,
      sort_field && "|> Ash.Query.sort(#{sort_field}: :#{sort_dir})",
      limit && "|> Ash.Query.limit(#{limit})",
      "|> Ash.read!()"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp expr_text(%{attr: %{name: n}, op: "is_nil"}), do: "is_nil(#{n})"
  defp expr_text(%{attr: %{name: n}, op: "present"}), do: "not is_nil(#{n})"

  defp expr_text(%{attr: %{name: n}, op: "contains", value: v}),
    do: "contains(string_downcase(#{n}), #{inspect(String.downcase(v))})"

  defp expr_text(%{attr: %{name: n}, op: "has", value: v}), do: "#{inspect(v)} in #{n}"
  defp expr_text(%{attr: %{name: n}, op: op, value: v}), do: "#{n} #{@ops[op]} #{inspect(v)}"

  @doc """
  How the data layer will execute it: which conditions become part of the
  glider `MATCH` pattern (and whether an index serves them), and which are
  left for Ash to evaluate in Elixir.
  """
  def plan(resource, compiled) do
    label = AshGlider.Info.label(resource)
    indexed = Ash.Resource.Info.primary_key(resource) ++ AshGlider.Info.index(resource)
    {pushed, runtime} = Enum.split_with(compiled, &(&1.op == "eq"))

    props =
      Enum.map_join(pushed, ", ", fn %{attr: attr, value: v} ->
        {:ok, dumped} = Ash.Type.dump_to_native(attr.type, v, attr.constraints)

        literal =
          case AshGlider.Type.encode(dumped) do
            s when is_binary(s) -> DataLayer.quote_string(s)
            other -> to_string(other)
          end

        "#{attr.name}: #{literal}"
      end)

    cypher =
      if props == "",
        do: "MATCH (n:#{label}) RETURN n",
        else: "MATCH (n:#{label} {#{props}}) RETURN n"

    %{
      cypher: cypher,
      pushed: pushed,
      runtime: runtime,
      seek: Enum.any?(pushed, &(&1.attr.name in indexed)),
      indexed: indexed
    }
  end

  def describe(c), do: expr_text(c)
end
