defmodule AshGlider.DataLayer do
  @behaviour Ash.DataLayer

  @graph_section %Spark.Dsl.Section{
    name: :graph,
    describe: """
    Configure how this resource is stored in a glider graph.
    """,
    examples: [
      """
      graph do
        graph MyApp.Graph
        label :Person
      end
      """
    ],
    schema: [
      graph: [
        type: {:behaviour, AshGlider.Graph},
        required: true,
        doc: "The `AshGlider.Graph` module holding the connection."
      ],
      label: [
        type: :atom,
        doc: """
        The node label for this resource. Defaults to the last segment of the
        resource module name, so `MyApp.Person` becomes `:Person`.
        """
      ],
      index: [
        type: {:list, :atom},
        default: [],
        doc: """
        Attributes to build a glider index on when the resource is first used.

        The planner uses an index when a pattern supplies a literal for that
        label/property pair, which turns a point lookup from a label scan into
        a seek. The primary key is always indexed; list anything else you
        filter on by equality.
        """
      ]
    ]
  }

  @moduledoc """
  An Ash data layer backed by [glider](https://github.com/example/glider).

  Each record is a node. Attributes are properties. The resource's label groups
  them:

      defmodule MyApp.Person do
        use Ash.Resource, domain: MyApp.Domain, data_layer: AshGlider.DataLayer

        graph do
          graph MyApp.Graph
          label :Person
          index [:email]
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string, public?: true
          attribute :email, :string, public?: true
        end
      end

  ## What is pushed down, and what is not

  Simple equality on an attribute becomes part of the `MATCH` pattern, so an
  indexed attribute is a seek rather than a scan. Everything else — `or`,
  comparisons, expressions, relationship filters — is evaluated in Elixir by
  `Ash.Filter.Runtime`, the same way the ETS and Mnesia data layers work.

  That is an honest trade rather than a limitation to work around. glider is
  memory-resident and reads never touch disk, so a label scan is a walk over
  memory, not IO. Pushing the whole of Ash's expression language into Cypher
  would buy little and be wrong in more places.

  The consequence worth knowing: **cost is proportional to the number of nodes
  carrying the label**, not to the number of rows returned. Index the
  attributes you filter on by equality.

  ## Graph-native work

  This layer stores records as nodes so that `AshGlider.Edge` can connect them
  and glider's algorithms can run over the result. See that module for edges,
  traversal, and `pagerank`/`components`/and the rest.
  """

  use Spark.Dsl.Extension, sections: [@graph_section]

  alias AshGlider.{Info, Type}
  alias Ash.Actions.Sort

  defmodule Query do
    @moduledoc false
    defstruct [
      :resource,
      :domain,
      :filter,
      :limit,
      :tenant,
      sort: [],
      offset: 0,
      context: %{},
      aggregates: [],
      calculations: [],
      relationships: %{}
    ]
  end

  # ------------------------------------------------------------ capabilities

  @doc false
  @impl true
  def can?(_, :read), do: true
  def can?(_, :create), do: true
  def can?(_, :update), do: true
  def can?(_, :destroy), do: true
  def can?(_, :sort), do: true
  def can?(_, :filter), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, :nested_expressions), do: true
  def can?(_, :bulk_create), do: true
  def can?(_, :composite_primary_key), do: true
  def can?(_, :expression_calculation), do: true
  def can?(_, :calculate), do: true
  def can?(_, {:filter_relationship, _}), do: true
  def can?(_, {:filter_expr, _}), do: true
  def can?(_, {:sort, _}), do: true
  def can?(_, {:aggregate, :count}), do: true
  def can?(_, {:aggregate, :first}), do: true
  def can?(_, {:aggregate, :sum}), do: true
  def can?(_, {:aggregate, :list}), do: true
  def can?(_, {:aggregate, :max}), do: true
  def can?(_, {:aggregate, :min}), do: true
  def can?(_, {:aggregate, :avg}), do: true
  def can?(_, {:aggregate, :exists}), do: true
  def can?(resource, {:query_aggregate, kind}), do: can?(resource, {:aggregate, kind})
  def can?(_, {:aggregate_relationship, _}), do: true
  def can?(_, {:join, _}), do: true
  def can?(_, :aggregate_filter), do: true
  def can?(_, :aggregate_sort), do: true

  # glider has BEGIN/COMMIT, but a rollback that must also undo in-memory state
  # is not something this layer can honestly promise yet. Saying `false` makes
  # Ash run actions without a transaction rather than trusting one that would
  # not hold.
  def can?(_, :transact), do: false

  def can?(_, _), do: false

  # ------------------------------------------------------------------- query

  @doc false
  @impl true
  def resource_to_query(resource, domain), do: %Query{resource: resource, domain: domain}

  @doc false
  @impl true
  def limit(query, limit, _), do: {:ok, %{query | limit: limit}}

  @doc false
  @impl true
  def offset(query, offset, _), do: {:ok, %{query | offset: offset}}

  @doc false
  @impl true
  def filter(query, filter, _resource) do
    if query.filter do
      {:ok, %{query | filter: Ash.Filter.add_to_filter!(query.filter, filter)}}
    else
      {:ok, %{query | filter: filter}}
    end
  end

  @doc false
  @impl true
  def sort(query, sort, _resource), do: {:ok, %{query | sort: sort}}

  @doc false
  @impl true
  def add_aggregates(query, aggregates, _),
    do: {:ok, %{query | aggregates: query.aggregates ++ aggregates}}

  @doc false
  @impl true
  def add_calculations(query, calculations, _),
    do: {:ok, %{query | calculations: query.calculations ++ calculations}}

  @doc false
  @impl true
  def set_tenant(_resource, query, tenant), do: {:ok, %{query | tenant: tenant}}

  @doc false
  @impl true
  def set_context(_resource, query, context), do: {:ok, %{query | context: context}}

  @doc false
  @impl true
  def in_transaction?(_), do: false

  @doc false
  @impl true
  def source(resource), do: resource |> Info.label() |> to_string()

  # ------------------------------------------------------------------ read

  @doc false
  @impl true
  def run_query(%Query{} = query, resource) do
    %Query{
      domain: domain,
      filter: filter,
      sort: sort,
      limit: limit,
      offset: offset,
      tenant: tenant,
      context: context,
      aggregates: aggregates,
      calculations: calculations
    } = query

    with {:ok, records} <- fetch(resource, filter),
         {:ok, filtered} <-
           filter_matches(records, filter, domain, tenant, context[:private][:actor]),
         sorted <- filtered |> Sort.runtime_sort(sort, domain: domain) |> Enum.drop(offset || 0),
         limited <- apply_limit(sorted, limit),
         {:ok, with_aggs} <-
           Ash.DataLayer.Ets.do_add_aggregates(limited, domain, resource, aggregates),
         {:ok, with_calcs} <-
           Ash.DataLayer.Ets.do_add_calculations(with_aggs, resource, calculations, domain) do
      {:ok, with_calcs}
    else
      {:error, error} -> {:error, Ash.Error.to_ash_error(error)}
    end
  end

  @doc false
  @impl true
  def run_aggregate_query(%Query{domain: domain} = query, aggregates, resource) do
    case run_query(query, resource) do
      {:ok, results} ->
        Enum.reduce_while(aggregates, {:ok, %{}}, fn agg, {:ok, acc} ->
          %{kind: kind, name: name, field: field, uniq?: uniq?} = agg

          matches =
            case filter_matches(
                   results,
                   Map.get(agg.query || %{}, :filter),
                   domain,
                   query.tenant,
                   query.context[:private][:actor]
                 ) do
              {:ok, m} -> m
              _ -> results
            end

          field = field || Enum.at(Ash.Resource.Info.primary_key(resource), 0)

          value =
            Ash.DataLayer.Ets.aggregate_value(
              matches,
              kind,
              field,
              uniq?,
              Map.get(agg, :include_nil?, false),
              Map.get(agg, :default_value)
            )

          {:cont, {:ok, Map.put(acc, name, value)}}
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  defp apply_limit(records, nil), do: records
  defp apply_limit(records, limit), do: Enum.take(records, limit)

  defp filter_matches(records, nil, _domain, _tenant, _actor), do: {:ok, records}

  defp filter_matches(records, filter, domain, tenant, actor) do
    Ash.Filter.Runtime.filter_matches(domain, records, filter, tenant: tenant, actor: actor)
  end

  # ---------------------------------------------------------------- storage

  # Read the nodes for a resource, pushing simple equality down into the MATCH
  # pattern where we can. See the moduledoc on what is and is not pushed down.
  defp fetch(resource, filter) do
    label = Info.label(resource)
    handle = Info.handle(resource)
    ensure_indexes(resource, handle, label)

    pattern =
      case pushdown(filter, resource) do
        [] -> "(n:#{label})"
        pairs -> "(n:#{label} {#{Enum.map_join(pairs, ", ", fn {k, v} -> "#{k}: #{v}" end)}})"
      end

    case Glider.query(handle, "MATCH #{pattern} RETURN n") do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [%Glider.Node{props: props}] -> props end)
        |> cast_all(resource)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only top-level `attribute == literal` conjuncts are pushed down. Anything
  # else stays for the runtime filter, which is always applied afterwards — so
  # a missed pushdown costs speed, never correctness.
  defp pushdown(nil, _resource), do: []

  defp pushdown(%Ash.Filter{expression: expression}, resource),
    do: pushdown_expr(expression, resource)

  defp pushdown(_, _resource), do: []

  defp pushdown_expr(%Ash.Query.BooleanExpression{op: :and, left: left, right: right}, resource),
    do: pushdown_expr(left, resource) ++ pushdown_expr(right, resource)

  defp pushdown_expr(
         %Ash.Query.Operator.Eq{
           left: %Ash.Query.Ref{attribute: attr, relationship_path: []},
           right: value
         },
         resource
       )
       when not is_struct(value, Ash.Query.Ref) do
    with %{name: name, type: type, constraints: constraints} <- attribute(resource, attr),
         {:ok, dumped} <- Ash.Type.dump_to_native(type, value, constraints),
         encoded when not is_nil(encoded) <- Type.encode(dumped),
         {:ok, literal} <- cypher_literal(encoded) do
      [{name, literal}]
    else
      _ -> []
    end
  end

  defp pushdown_expr(_, _resource), do: []

  defp attribute(_resource, %{name: _} = attr), do: attr

  defp attribute(resource, name) when is_atom(name),
    do: Ash.Resource.Info.attribute(resource, name)

  defp attribute(_, _), do: nil

  defp cypher_literal(v) when is_integer(v) or is_float(v), do: {:ok, to_string(v)}
  defp cypher_literal(true), do: {:ok, "true"}
  defp cypher_literal(false), do: {:ok, "false"}
  defp cypher_literal(v) when is_binary(v), do: {:ok, quote_string(v)}
  defp cypher_literal(_), do: :error

  @doc false
  def quote_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  defp cast_all(prop_maps, resource) do
    attributes = Ash.Resource.Info.attributes(resource)

    prop_maps
    |> Enum.map(fn props ->
      Map.new(attributes, fn attr ->
        {attr.name,
         props
         |> Map.get(to_string(attr.name))
         |> Type.decode(attr.type, attr.constraints)}
      end)
    end)
    |> Ash.DataLayer.Ets.cast_records(resource)
  end

  # -------------------------------------------------------------- mutations

  @doc false
  @impl true
  def create(resource, changeset) do
    with {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
         {:ok, props} <- dump(record, resource),
         :ok <- do_create(resource, props) do
      {:ok, set_loaded(record, resource)}
    end
  end

  defp do_create(resource, props) do
    handle = Info.handle(resource)
    label = Info.label(resource)
    ensure_indexes(resource, handle, label)

    case Glider.query(handle, "CREATE (n:#{label} {#{property_literals(props)}})") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Ash.Error.to_ash_error(reason)}
    end
  end

  @doc false
  @impl true
  def update(resource, changeset) do
    with {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
         {:ok, props} <- dump(record, resource),
         {:ok, match} <- pk_match(changeset.data, resource) do
      handle = Info.handle(resource)
      label = Info.label(resource)

      sets =
        props
        |> Enum.map(fn {k, v} -> "n.#{k} = #{literal_or_null(v)}" end)
        |> Enum.join(", ")

      case Glider.query(handle, "MATCH (n:#{label} {#{match}}) SET #{sets}") do
        {:ok, %{touched: 0}} -> {:error, not_found(changeset.data, resource)}
        {:ok, _} -> {:ok, set_loaded(record, resource)}
        {:error, reason} -> {:error, Ash.Error.to_ash_error(reason)}
      end
    end
  end

  @doc false
  @impl true
  def destroy(resource, %{data: record}) do
    with {:ok, match} <- pk_match(record, resource) do
      handle = Info.handle(resource)
      label = Info.label(resource)

      # DETACH so a node's edges go with it; leaving dangling relationships
      # behind would corrupt every traversal through this node.
      case Glider.query(handle, "MATCH (n:#{label} {#{match}}) DETACH DELETE n") do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, Ash.Error.to_ash_error(reason)}
      end
    end
  end

  defp dump(record, resource) do
    attributes = Ash.Resource.Info.attributes(resource)

    case Ash.DataLayer.Ets.dump_to_native(record, attributes) do
      {:ok, native} ->
        {:ok, Map.new(native, fn {k, v} -> {k, Type.encode(v)} end)}

      {:error, error} ->
        {:error, Ash.Error.to_ash_error(error)}
    end
  end

  # A nil property is simply absent from the node, which is how glider
  # represents "unset" — writing an explicit null would make `IS NULL` and
  # `keys()` disagree.
  defp property_literals(props) do
    props
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{value_literal(v)}" end)
  end

  defp literal_or_null(nil), do: "null"
  defp literal_or_null(v), do: value_literal(v)

  defp value_literal(v) when is_binary(v), do: quote_string(v)
  defp value_literal(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp value_literal(true), do: "true"
  defp value_literal(false), do: "false"

  defp value_literal(v) when is_list(v),
    do: "[" <> Enum.map_join(v, ", ", &value_literal/1) <> "]"

  defp value_literal(nil), do: "null"

  defp pk_match(record, resource) do
    pk = Ash.Resource.Info.primary_key(resource)

    pairs =
      Enum.reduce_while(pk, {:ok, []}, fn key, {:ok, acc} ->
        attr = Ash.Resource.Info.attribute(resource, key)

        case Ash.Type.dump_to_native(attr.type, Map.get(record, key), attr.constraints) do
          {:ok, dumped} -> {:cont, {:ok, [{key, Type.encode(dumped)} | acc]}}
          _ -> {:halt, {:error, "could not encode primary key #{key}"}}
        end
      end)

    case pairs do
      {:ok, pairs} ->
        {:ok, Enum.map_join(pairs, ", ", fn {k, v} -> "#{k}: #{value_literal(v)}" end)}

      {:error, reason} ->
        {:error, Ash.Error.to_ash_error(reason)}
    end
  end

  defp not_found(record, resource) do
    Ash.Error.Changes.StaleRecord.exception(
      resource: resource,
      filter: Map.take(record, Ash.Resource.Info.primary_key(resource))
    )
  end

  defp set_loaded(record, resource) do
    %{record | __meta__: %Ecto.Schema.Metadata{state: :loaded, schema: resource}}
  end

  # Indexes are created lazily on first use and recorded in glider's log, so
  # this is a no-op after the first call. Doing it here rather than in a
  # migration keeps the extension free of setup steps.
  defp ensure_indexes(resource, handle, label) do
    key = {__MODULE__, :indexed, resource}

    if :persistent_term.get(key, false) do
      :ok
    else
      pk = Ash.Resource.Info.primary_key(resource)

      for attr <- Enum.uniq(pk ++ Info.index(resource)) do
        Glider.query(handle, "INDEX ON :#{label}(#{attr})")
      end

      :persistent_term.put(key, true)
      :ok
    end
  end
end
