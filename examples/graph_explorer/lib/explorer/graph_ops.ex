defmodule Explorer.GraphOps do
  @moduledoc """
  Graph-native operations for the explorer.

  Records are created, read, updated and destroyed through Ash like any other
  resource. This module covers what Ash's relational model cannot express and
  `AshGlider.Edge` exists for: edges with properties, neighbourhoods,
  traversal, shortest paths across resource types, graph algorithms, and raw
  Cypher.
  """

  alias AshGlider.DataLayer
  alias Explorer.Catalog

  @algorithms ~w(pagerank degree betweenness closeness components communities kcore triangles)

  def algorithms, do: @algorithms
  def handle, do: Explorer.Graph.handle()

  # ------------------------------------------------------------- overview

  @doc "Totals plus per-label and per-edge-type counts."
  def overview do
    {:ok, stats} = Glider.stats(handle())
    {:ok, schema} = Glider.schema(handle())

    %{
      nodes: stats["nodes"],
      edges: stats["edges"],
      labels: schema.labels,
      edge_types: schema.edge_types,
      indexes: schema.indexes
    }
  end

  def label_counts do
    {:ok, schema} = Glider.schema(handle())
    Map.new(schema.labels, &{&1.name, &1.count})
  end

  @doc "The whole graph (capped), for the dashboard canvas."
  def whole_graph(limit \\ 400) do
    {:ok, nodes} = Glider.query(handle(), "MATCH (n) RETURN n LIMIT #{limit}")
    {:ok, edges} = Glider.query(handle(), "MATCH (a)-[r]->(b) RETURN r LIMIT #{limit * 4}")
    ids = MapSet.new(nodes.rows, fn [n] -> n.id end)

    viz(%{
      nodes: Enum.map(nodes.rows, &hd/1),
      edges:
        Enum.filter(
          edges.graph.edges,
          &(MapSet.member?(ids, &1.from) and MapSet.member?(ids, &1.to))
        )
    })
  end

  # ------------------------------------------------------------ one record

  @doc """
  Every edge touching a record, in both directions, with the node at the
  other end. Any edge type, including ones created outside the catalog.
  """
  def edges_of(record) do
    pattern = node_pattern(record)

    out = query_rows!("MATCH #{pattern}-[r]->(b) RETURN r, b")
    inc = query_rows!("MATCH #{pattern}<-[r]-(b) RETURN r, b")

    (Enum.map(out, &edge_row(&1, :out)) ++ Enum.map(inc, &edge_row(&1, :in)))
    |> Enum.sort_by(&{&1.type, &1.direction, &1.other.name})
  end

  defp edge_row([%Glider.Rel{} = r, %Glider.Node{} = b], direction) do
    %{
      id: r.id,
      type: r.type,
      props: r.props,
      direction: direction,
      other: %{
        label: List.first(b.labels),
        name: b.props["name"] || "##{b.id}",
        path: Catalog.node_path(b)
      }
    }
  end

  @doc "A record's neighbourhood to `depth` hops (1 or 2), as canvas data."
  def neighborhood(record, depth \\ 1) do
    pattern = node_pattern(record)

    {:ok, one} = Glider.query(handle(), "MATCH #{pattern}-[r]-(b) RETURN a, r, b LIMIT 500")

    graph =
      if depth >= 2 do
        {:ok, two} =
          Glider.query(
            handle(),
            "MATCH #{pattern}-[r1]-(b)-[r2]-(c) RETURN a, r1, b, r2, c LIMIT 2000"
          )

        merge_graphs(one.graph, two.graph)
      else
        one.graph
      end

    # A record with no edges still deserves a dot on the canvas.
    graph =
      if graph.nodes == [] do
        {:ok, self} = Glider.query(handle(), "MATCH #{pattern} RETURN a")
        %{graph | nodes: Enum.map(self.rows, &hd/1)}
      else
        graph
      end

    viz(graph, internal_id(record))
  end

  # ---------------------------------------------------------------- edges

  @doc """
  Create a catalogued edge. Validates the type and both endpoints' resources
  against the catalog, and casts the properties to their declared types.
  """
  def create_edge(from, type, to, raw_props \\ %{}) do
    with %{} = spec <- Catalog.edge_type(type) || {:error, "unknown edge type #{inspect(type)}"},
         :ok <- check_endpoints(spec, from, to),
         {:ok, props} <- cast_props(spec, raw_props) do
      AshGlider.Edge.relate(from, spec.type, to, props)
    end
  end

  defp check_endpoints(spec, %from{}, %to{}) do
    if spec.from == from and spec.to == to,
      do: :ok,
      else: {:error, "#{spec.type} connects #{label(spec.from)} to #{label(spec.to)}"}
  end

  @doc "Replace a catalogued edge's properties. Unknown keys are refused."
  def update_edge(edge_id, raw_props) when is_integer(edge_id) do
    with {:ok, %Glider.Rel{type: type}} <- fetch_edge(edge_id),
         %{} = spec <- Catalog.edge_type(type) || {:error, "#{type} is not an editable edge type"},
         {:ok, props} <- cast_props(spec, raw_props) do
      sets =
        Enum.map_join(spec.props, ", ", fn {key, _} ->
          "r.#{key} = #{literal(Map.get(props, key))}"
        end)

      if sets == "" do
        :ok
      else
        case Glider.query(handle(), "MATCH (a)-[r]->(b) WHERE id(r) = #{edge_id} SET #{sets}") do
          {:ok, _} -> :ok
          error -> error
        end
      end
    end
  end

  def delete_edge(edge_id) when is_integer(edge_id) do
    case Glider.query(handle(), "MATCH (a)-[r]->(b) WHERE id(r) = #{edge_id} DELETE r") do
      {:ok, %{touched: 0}} -> {:error, :not_found}
      {:ok, _} -> :ok
      error -> error
    end
  end

  def fetch_edge(edge_id) do
    case Glider.query(handle(), "MATCH (a)-[r]->(b) WHERE id(r) = #{edge_id} RETURN r") do
      {:ok, %{rows: [[rel]]}} -> {:ok, rel}
      {:ok, _} -> {:error, :not_found}
      error -> error
    end
  end

  defp cast_props(spec, raw) do
    Enum.reduce_while(spec.props, {:ok, %{}}, fn {key, type}, {:ok, acc} ->
      value = Map.get(raw, key, Map.get(raw, to_string(key)))

      case cast_prop(type, value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, v} -> {:cont, {:ok, Map.put(acc, key, v)}}
        :error -> {:halt, {:error, "#{key} must be #{type}"}}
      end
    end)
  end

  defp cast_prop(_type, v) when v in [nil, ""], do: {:ok, nil}
  defp cast_prop(:integer, v) when is_integer(v), do: {:ok, v}

  defp cast_prop(:integer, v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp cast_prop(:string, v) when is_binary(v), do: {:ok, v}
  defp cast_prop(_, _), do: :error

  # ------------------------------------------------------------- traversal

  @doc """
  Records reachable along one catalogued edge type, via `AshGlider.Edge.related/3`.

  The destination resource follows from the edge spec and the direction, so
  cross-resource edges such as WORKS_AT load as the right struct.
  """
  def traverse(%resource{} = record, type, direction, min_depth, max_depth) do
    spec = Catalog.edge_type(type) || raise ArgumentError, "unknown edge type"

    destination =
      case direction do
        :out -> spec.to
        :in -> spec.from
        :both -> if spec.from == resource, do: spec.to, else: spec.from
      end

    AshGlider.Edge.related(record, spec.type,
      depth: min_depth..max_depth,
      direction: direction,
      destination: destination
    )
  end

  @doc """
  Shortest path between any two records, whatever their resources.

  `AshGlider.Edge.path/3` loads every step as one resource; a path from a
  person through a company to a project needs each step resolved by its own
  label, so this walks glider's `shortestpath` rows directly.
  """
  def path(from, to, opts \\ []) do
    dir = Keyword.get(opts, :dir, "both")
    from_id = internal_id(from)
    to_id = internal_id(to)

    case Glider.query(
           handle(),
           ~s|CALL shortestpath(from: #{from_id}, to: #{to_id}, dir: "#{dir}")|
         ) do
      {:ok, %{rows: rows}} ->
        ids = Enum.map(rows, &Enum.at(&1, 1))
        nodes = nodes_by_id(ids)

        steps =
          for id <- ids, node = nodes[id], node != nil do
            %{
              name: node.props["name"],
              label: List.first(node.labels),
              path: Catalog.node_path(node),
              id: id
            }
          end

        {:ok, steps}

      error ->
        error
    end
  end

  # ------------------------------------------------------------- algorithms

  @doc """
  Run a whitelisted glider algorithm. Rows come back with the node resolved
  to its label, name and page, so they can be linked.

  `write: true` stores each node's score in its `rank` property, which the
  resources declare as a read-only attribute — so the score is then sortable
  and filterable through ordinary Ash queries.
  """
  def algorithm(name, opts \\ []) when name in @algorithms do
    args =
      [
        top: Keyword.get(opts, :top),
        type: Keyword.get(opts, :type),
        dir: Keyword.get(opts, :dir),
        write: if(Keyword.get(opts, :write), do: "rank")
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    {micros, result} =
      :timer.tc(fn ->
        AshGlider.Edge.algorithm(Explorer.Directory.Person, String.to_atom(name), args)
      end)

    with {:ok, rows} <- result do
      nodes = rows |> Enum.map(&hd/1) |> nodes_by_id()

      resolved =
        Enum.map(rows, fn [id, _name, value | _] ->
          node = nodes[id]

          %{
            id: id,
            name: node && node.props["name"],
            label: node && List.first(node.labels),
            path: node && Catalog.node_path(node),
            value: value
          }
        end)

      {:ok, %{rows: resolved, micros: micros}}
    end
  end

  # ------------------------------------------------------------------ cypher

  @doc "Run raw Cypher against the graph, timed."
  def cypher(text) do
    {micros, result} = :timer.tc(fn -> Glider.query(handle(), text) end)

    case result do
      {:ok, r} -> {:ok, r, micros}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Remove every node and edge. Indexes survive, as they live in the schema."
  def wipe! do
    {:ok, _} = Glider.query(handle(), "MATCH (n) DETACH DELETE n")
    :ok
  end

  # ------------------------------------------------------------------ canvas

  @doc "Turn a glider `%{nodes, edges}` projection into JSON for the canvas hook."
  def viz(%{nodes: nodes, edges: edges}, focus \\ nil) do
    %{
      nodes:
        Enum.map(nodes, fn n ->
          label = List.first(n.labels) || "?"

          %{
            id: n.id,
            name: n.props["name"] || "##{n.id}",
            group: label,
            color: Catalog.color(label),
            href: Catalog.node_path(n),
            focus: n.id == focus
          }
        end),
      edges: Enum.map(edges, &%{id: &1.id, from: &1.from, to: &1.to, type: &1.type})
    }
  end

  def merge_graphs(a, b) do
    %{
      nodes: Enum.uniq_by(a.nodes ++ b.nodes, & &1.id),
      edges: Enum.uniq_by(a.edges ++ b.edges, & &1.id)
    }
  end

  # ------------------------------------------------------------------ helpers

  @doc "glider's own node id for a record."
  def internal_id(record) do
    case query_rows!("MATCH #{node_pattern(record, "n")} RETURN id(n)") do
      [[id] | _] -> id
      [] -> nil
    end
  end

  defp nodes_by_id([]), do: %{}

  defp nodes_by_id(ids) do
    list = ids |> Enum.uniq() |> Enum.join(", ")

    "MATCH (n) WHERE id(n) IN [#{list}] RETURN n"
    |> query_rows!()
    |> Map.new(fn [n] -> {n.id, n} end)
  end

  defp node_pattern(%resource{id: id}, binding \\ "a") do
    "(#{binding}:#{AshGlider.Info.label(resource)} {id: #{DataLayer.quote_string(id)}})"
  end

  defp query_rows!(q) do
    case Glider.query(handle(), q) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> raise "glider query failed: #{reason}\n#{q}"
    end
  end

  defp literal(nil), do: "null"
  defp literal(v) when is_integer(v), do: Integer.to_string(v)
  defp literal(v) when is_binary(v), do: DataLayer.quote_string(v)

  defp label(resource), do: Catalog.by_resource(resource).label
end
