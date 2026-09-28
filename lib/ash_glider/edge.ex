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

  require Glider.Query, as: Q

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
    with {:ok, a} <- node_pattern(from, :a),
         {:ok, b} <- node_pattern(to, :b) do
      props =
        props
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new(fn {k, v} -> {k, Type.encode(v)} end)

      q =
        a
        |> Q.match()
        |> Q.match(b)
        |> Q.create(Q.edge(:a, to_string(type), :b, props))

      case Glider.query(handle(from), q) do
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
    with {:ok, a} <- node_pattern(from, :a),
         {:ok, b} <- node_pattern(to, :b) do
      q =
        path_pattern(a, "-[r:" <> Q.ident(to_string(type)) <> "]->", b)
        |> Q.match()
        |> Q.delete(:r)

      case Glider.query(handle(from), q) do
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
    destination = Keyword.get(opts, :destination, record.__struct__)

    with {:ok, a} <- node_pattern(record, :a) do
      {left, right} =
        case Keyword.get(opts, :direction, :out) do
          :out -> {"-", "->"}
          :in -> {"<-", "-"}
          :both -> {"-", "-"}
        end

      hop =
        left <>
          "[:" <> Q.ident(to_string(type)) <> hop_spec(Keyword.get(opts, :depth)) <> "]" <> right

      q =
        path_pattern(a, hop, Q.vertex(:b, to_string(Info.label(destination))))
        |> Q.match()
        |> Q.return(b)
        |> Q.distinct()

      q =
        case Keyword.get(opts, :limit) do
          nil -> q
          n when is_integer(n) and n >= 0 -> Q.limit(q, ^n)
        end

      case Glider.query(handle(record), q) do
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
    with {:ok, a} <- node_pattern(from, :a),
         {:ok, b} <- node_pattern(to, :b) do
      q = path_pattern(a, "-[r]->", b) |> Q.match() |> Q.return(r)

      case Glider.query(handle(from), q) do
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
      args =
        [from: from_id, to: to_id] ++
          case Keyword.get(opts, :type) do
            nil -> []
            t -> [type: to_string(t)]
          end

      case Glider.query(handle(from), Q.call(:shortestpath, args)) do
        {:ok, %{rows: rows}} ->
          # shortestpath returns step/id/node columns; the ids are what we need
          # in order to load the records back through the data layer.
          ids = Enum.map(rows, fn row -> Enum.at(row, 1) end)
          load_by_internal_ids(handle(from), ids, Keyword.get(opts, :destination, resource))

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
    args =
      Enum.map(args, fn {k, v} ->
        {k, if(is_atom(v) and not is_boolean(v), do: to_string(v), else: v)}
      end)

    case Glider.query(Info.handle(resource), Q.call(name, args)) do
      {:ok, result} -> {:ok, result.rows}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------ private

  # A record read under a tenant remembers it, so its edges go to that
  # tenant's database.
  defp handle(record), do: Info.handle(record.__struct__, record.__metadata__[:tenant])

  defp hop_spec(nil), do: ""
  defp hop_spec(first..last//_), do: "*#{first}..#{last}"
  defp hop_spec(n) when is_integer(n), do: "*#{n}..#{n}"

  # `(a:Label {pk: $param})` for one record.
  defp node_pattern(record, binding) do
    resource = record.__struct__

    case DataLayer.pk_props(record, resource) do
      {:ok, pk} -> {:ok, Q.vertex(binding, to_string(Info.label(resource)), pk)}
      {:error, _} -> {:error, {:bad_primary_key, Ash.Resource.Info.primary_key(resource)}}
    end
  end

  # Two node patterns joined by a relationship pattern, as one fragment.
  defp path_pattern(%Q.Fragment{parts: a}, hop, %Q.Fragment{parts: b}),
    do: %Q.Fragment{parts: a ++ [hop] ++ b}

  # glider's internal node id, needed by the algorithms that take ids.
  defp node_id(record) do
    with {:ok, n} <- node_pattern(record, :n) do
      case Glider.query(handle(record), n |> Q.match() |> Q.return(id(n))) do
        {:ok, %{rows: [[id] | _]}} -> {:ok, id}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp load_by_internal_ids(_handle, [], _resource), do: {:ok, []}

  defp load_by_internal_ids(handle, ids, resource) do
    q =
      Q.vertex(:n, to_string(Info.label(resource)))
      |> Q.match()
      |> Q.where_fragment(["id(n) IN ", {:param, ids}])
      |> Q.return([id(n), n])

    case Glider.query(handle, q) do
      {:ok, %{rows: rows}} ->
        # One query for the whole path, then back into path order: a path is
        # only meaningful in sequence.
        by_id = Map.new(rows, fn [id, node] -> {id, node} end)
        ids |> Enum.flat_map(&List.wrap(by_id[&1])) |> Enum.map(&[&1]) |> load_nodes(resource)

      {:error, reason} ->
        {:error, reason}
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
