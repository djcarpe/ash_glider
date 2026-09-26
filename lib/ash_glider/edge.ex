defmodule AshGlider.Edge do
  @moduledoc """
  Relationships as real graph edges, and the traversals that follow from them.

  ## Why this is separate from Ash relationships

  An Ash `belongs_to` / `has_many` is defined by attributes: the destination
  carries a foreign key, and a join reads it. That works on this data layer —
  records are nodes, foreign keys are properties — and you should keep using it
  for ordinary parent/child modelling.

  What it cannot express is the thing a graph database is for: an edge with its
  own properties, traversed to arbitrary depth, in either direction, without a
  join per hop. `MyApp.Person -[:KNOWS {since: 2019}]-> MyApp.Person` has no
  foreign key to hang off, and "everyone within three hops of Ada" is not a
  query the attribute model expresses at all.

  So edges live here, addressed by the records they connect:

      AshGlider.Edge.relate(ada, :KNOWS, bob, %{since: 2019})
      {:ok, friends}  = AshGlider.Edge.related(ada, :KNOWS)
      {:ok, extended} = AshGlider.Edge.related(ada, :KNOWS, depth: 1..3)

  Everything here goes through the same graph as the data layer, so an edge
  created in Elixir is visible in `glider browser` and vice versa.
  """

  alias AshGlider.{DataLayer, Info, Type}

  @type record :: Ash.Resource.record()
  @type rel_type :: atom() | String.t()

  @doc """
  Create an edge from one record to another.

  `type` is the relationship type, `props` an optional map of edge properties.
  Returns `:ok`, or `{:error, reason}` if either endpoint is missing.

      AshGlider.Edge.relate(ada, :KNOWS, bob, %{since: 2019})
  """
  @spec relate(record(), rel_type(), record(), map()) :: :ok | {:error, term()}
  def relate(from, type, to, props \\ %{}) do
    with {:ok, from_pattern} <- node_pattern(from, "a"),
         {:ok, to_pattern} <- node_pattern(to, "b") do
      handle = Info.handle(from.__struct__)
      prop_text = edge_props(props)

      query = """
      MATCH #{from_pattern}, #{to_pattern} \
      CREATE (a)-[:#{type}#{prop_text}]->(b)\
      """

      case Glider.query(handle, query) do
        {:ok, %{touched: 0}} -> {:error, :endpoint_not_found}
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Remove edges of `type` between two records. Returns the number removed.
  """
  @spec unrelate(record(), rel_type(), record()) :: {:ok, non_neg_integer()} | {:error, term()}
  def unrelate(from, type, to) do
    with {:ok, from_pattern} <- node_pattern(from, "a"),
         {:ok, to_pattern} <- node_pattern(to, "b") do
      handle = Info.handle(from.__struct__)

      query = """
      MATCH #{from_pattern}-[r:#{type}]->#{to_pattern} DELETE r\
      """

      case Glider.query(handle, query) do
        {:ok, %{touched: n}} -> {:ok, n}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Records reachable from `record` along `type`.

  ## Options

    * `:depth` — a range such as `1..3` for a variable-length traversal.
      Defaults to one hop.
    * `:direction` — `:out` (default), `:in`, or `:both`.
    * `:destination` — the resource to load results as. Defaults to the same
      resource as `record`, which is what a self-referential edge like `:KNOWS`
      wants; set it when the edge crosses resources.
    * `:limit` — cap the number of results.

      {:ok, friends}  = AshGlider.Edge.related(ada, :KNOWS)
      {:ok, network}  = AshGlider.Edge.related(ada, :KNOWS, depth: 1..3)
      {:ok, admirers} = AshGlider.Edge.related(bob, :KNOWS, direction: :in)
  """
  @spec related(record(), rel_type(), keyword()) :: {:ok, [record()]} | {:error, term()}
  def related(record, type, opts \\ []) do
    resource = record.__struct__
    destination = Keyword.get(opts, :destination, resource)

    with {:ok, pattern} <- node_pattern(record, "a") do
      handle = Info.handle(resource)
      hops = hop_spec(Keyword.get(opts, :depth))
      dest_label = Info.label(destination)

      {left, right} =
        case Keyword.get(opts, :direction, :out) do
          :out -> {"-", "->"}
          :in -> {"<-", "-"}
          :both -> {"-", "-"}
        end

      limit =
        case Keyword.get(opts, :limit) do
          nil -> ""
          n when is_integer(n) -> " LIMIT #{n}"
        end

      query =
        "MATCH #{pattern}#{left}[:#{type}#{hops}]#{right}(b:#{dest_label}) RETURN DISTINCT b#{limit}"

      case Glider.query(handle, query) do
        {:ok, %{rows: rows}} -> load_nodes(rows, destination)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  The edges between two records, as maps of `{type, props}`.

      {:ok, [%{type: "KNOWS", props: %{"since" => 2019}}]} =
        AshGlider.Edge.edges_between(ada, bob)
  """
  @spec edges_between(record(), record()) :: {:ok, [map()]} | {:error, term()}
  def edges_between(from, to) do
    with {:ok, from_pattern} <- node_pattern(from, "a"),
         {:ok, to_pattern} <- node_pattern(to, "b") do
      handle = Info.handle(from.__struct__)

      case Glider.query(handle, "MATCH #{from_pattern}-[r]->#{to_pattern} RETURN r") do
        {:ok, %{rows: rows}} ->
          {:ok, Enum.map(rows, fn [%Glider.Rel{type: t, props: p}] -> %{type: t, props: p} end)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Shortest path between two records, as a list of records.

  Returns `{:ok, []}` when no path exists.
  """
  @spec path(record(), record(), keyword()) :: {:ok, [record()]} | {:error, term()}
  def path(from, to, opts \\ []) do
    resource = from.__struct__

    with {:ok, from_id} <- node_id(from),
         {:ok, to_id} <- node_id(to) do
      handle = Info.handle(resource)

      type_arg =
        case Keyword.get(opts, :type) do
          nil -> ""
          t -> ~s|, type: "#{t}"|
        end

      case Glider.query(handle, "CALL shortestpath(from: #{from_id}, to: #{to_id}#{type_arg})") do
        {:ok, %{rows: rows}} ->
          # shortestpath returns step/id/node columns; the ids are what we need
          # in order to load the records back through the data layer.
          ids = Enum.map(rows, fn row -> Enum.at(row, 1) end)
          load_by_internal_ids(handle, ids, Keyword.get(opts, :destination, resource))

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Run one of glider's graph algorithms and return the raw rows.

  This is deliberately thin: the algorithms return scores and rankings rather
  than records, and pretending otherwise would lose information.

      {:ok, rows} = AshGlider.Edge.algorithm(MyApp.Person, :pagerank, iterations: 20, top: 10)

  Writing a score back onto the nodes makes it readable as an ordinary
  attribute afterwards:

      AshGlider.Edge.algorithm(MyApp.Person, :pagerank, write: "rank")
  """
  @spec algorithm(Ash.Resource.t(), atom(), keyword()) :: {:ok, list()} | {:error, term()}
  def algorithm(resource, name, args \\ []) do
    handle = Info.handle(resource)

    arg_text =
      args
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{arg_literal(v)}" end)

    case Glider.query(handle, "CALL #{name}(#{arg_text})") do
      {:ok, result} -> {:ok, result.rows}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------ private

  defp arg_literal(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp arg_literal(true), do: "true"
  defp arg_literal(false), do: "false"
  defp arg_literal(v) when is_binary(v), do: DataLayer.quote_string(v)
  defp arg_literal(v) when is_atom(v), do: DataLayer.quote_string(Atom.to_string(v))

  defp hop_spec(nil), do: ""
  defp hop_spec(first..last//_), do: "*#{first}..#{last}"
  defp hop_spec(n) when is_integer(n), do: "*#{n}..#{n}"

  defp edge_props(props) when props == %{}, do: ""

  defp edge_props(props) do
    text =
      props
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{literal(Type.encode(v))}" end)

    " {" <> text <> "}"
  end

  defp literal(v) when is_binary(v), do: DataLayer.quote_string(v)
  defp literal(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp literal(true), do: "true"
  defp literal(false), do: "false"
  defp literal(v) when is_list(v), do: "[" <> Enum.map_join(v, ", ", &literal/1) <> "]"
  defp literal(nil), do: "null"

  # `(a:Label {pk: value})` for one record.
  defp node_pattern(record, binding) do
    resource = record.__struct__
    label = Info.label(resource)

    case pk_pairs(record, resource) do
      {:ok, pairs} ->
        text = Enum.map_join(pairs, ", ", fn {k, v} -> "#{k}: #{literal(v)}" end)
        {:ok, "(#{binding}:#{label} {#{text}})"}

      error ->
        error
    end
  end

  defp pk_pairs(record, resource) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      attr = Ash.Resource.Info.attribute(resource, key)

      case Ash.Type.dump_to_native(attr.type, Map.get(record, key), attr.constraints) do
        {:ok, dumped} -> {:cont, {:ok, [{key, Type.encode(dumped)} | acc]}}
        _ -> {:halt, {:error, {:bad_primary_key, key}}}
      end
    end)
  end

  # glider's internal node id, needed by the algorithms that take ids.
  defp node_id(record) do
    resource = record.__struct__

    with {:ok, pattern} <- node_pattern(record, "n") do
      handle = Info.handle(resource)

      case Glider.query(handle, "MATCH #{pattern} RETURN id(n)") do
        {:ok, %{rows: [[id] | _]}} -> {:ok, id}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp load_by_internal_ids(_handle, [], _resource), do: {:ok, []}

  defp load_by_internal_ids(handle, ids, resource) do
    label = Info.label(resource)

    # Preserve path order: glider returns rows in whatever order the pattern
    # yields, but a path is only meaningful in sequence.
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Glider.query(handle, "MATCH (n:#{label}) WHERE id(n) = #{id} RETURN n") do
        {:ok, %{rows: [[node] | _]}} -> {:cont, {:ok, [node | acc]}}
        {:ok, %{rows: []}} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, nodes} -> load_nodes(Enum.map(Enum.reverse(nodes), &[&1]), resource)
      error -> error
    end
  end

  defp load_nodes(rows, resource) do
    attributes = Ash.Resource.Info.attributes(resource)

    rows
    |> Enum.map(fn [%Glider.Node{props: props}] ->
      Map.new(attributes, fn attr ->
        {attr.name,
         props |> Map.get(to_string(attr.name)) |> Type.decode(attr.type, attr.constraints)}
      end)
    end)
    |> Ash.DataLayer.Ets.cast_records(resource)
  end
end
