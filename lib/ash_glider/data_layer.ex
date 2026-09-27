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

  glider stores the graph in pages on disk, so work the engine can skip is
  IO that never happens. The filter is pushed into the query where the
  translation is exact:

    * `attr == value` joins the `MATCH` pattern, so an indexed attribute is a
      seek rather than a scan
    * `<`, `<=`, `>`, `>=` on integer, float and string attributes, `in` and
      `is_nil` become `WHERE` conditions
    * `or` is pushed when both sides are

  Every value travels as a query parameter, never as spliced text. Anything
  else — `not`, `!=`, expressions, relationship paths, types whose stored form
  does not compare like the original (case-insensitive strings, maps,
  datetimes) — is left to `Ash.Filter.Runtime`, which is applied to the rows
  afterwards in any case. A missed pushdown costs speed, never correctness.

  When the whole filter is pushed down and the query is not sorted, `limit`
  and `offset` are pushed too, so reading ten records reads ten nodes.

  Index the attributes you filter on by equality.

  ## Transactions

  Ash actions run inside glider transactions: a failed action rolls back
  everything it wrote, and a transaction belongs to the process that opened
  it, so concurrent requests never see each other's half-finished work.

  ## Graph-native work

  This layer stores records as nodes so that `AshGlider.Edge` can connect them
  and glider's algorithms can run over the result. See that module for edges,
  traversal, and `pagerank`/`components`/and the rest.
  """

  use Spark.Dsl.Extension, sections: [@graph_section]

  require Glider.Query, as: Q

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

  def can?(_, :transact), do: true

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
  def transaction(resource, fun, _timeout, _reason) do
    Glider.transaction(Info.handle(resource), fun)
  end

  @doc false
  @impl true
  def rollback(resource, value), do: Glider.rollback(Info.handle(resource), value)

  @doc false
  @impl true
  def in_transaction?(resource), do: Glider.in_transaction?(Info.handle(resource))

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

    page = if sort in [nil, []], do: {offset || 0, limit}, else: nil

    with {:ok, records, paged?} <- fetch(resource, filter, page),
         {offset, limit} = if(paged?, do: {0, nil}, else: {offset, limit}),
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

  # Read the nodes for a resource, pushing as much of the filter into the
  # query as translates exactly. `page` is {offset, limit} when the caller
  # would slice an unsorted result; it is pushed down only when the whole
  # filter was, and the third element says whether it was.
  defp fetch(resource, filter, page) do
    label = Info.label(resource)
    handle = Info.handle(resource)
    ensure_indexes(resource, handle, label)

    {eq, conds, complete?} = pushdown(filter, resource)

    q =
      Q.vertex(:n, to_string(label), eq)
      |> Q.match()
      |> then(&Enum.reduce(conds, &1, fn parts, q -> Q.where_fragment(q, parts) end))
      |> Q.return(n)

    {q, paged?} =
      case page do
        {offset, limit} when complete? ->
          q = if offset > 0, do: Q.skip(q, ^offset), else: q
          {if(limit, do: Q.limit(q, ^limit), else: q), true}

        _ ->
          {q, false}
      end

    case Glider.query(handle, q) do
      {:ok, %{rows: rows}} ->
        with {:ok, records} <-
               rows
               |> Enum.map(fn [%Glider.Node{props: props}] -> props end)
               |> cast_all(resource) do
          {:ok, records, paged?}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -> {equality props for the pattern, [where parts], every conjunct pushed?}
  defp pushdown(nil, _resource), do: {%{}, [], true}

  defp pushdown(%Ash.Filter{expression: expression}, resource) do
    expression
    |> conjuncts()
    |> Enum.reduce({%{}, [], true}, fn expr, {eq, conds, complete?} ->
      case pushdown_eq(expr, resource) do
        {:ok, {name, value}} when not is_map_key(eq, name) ->
          {Map.put(eq, name, value), conds, complete?}

        _ ->
          case condition(expr, resource) do
            {:ok, parts} -> {eq, conds ++ [parts], complete?}
            :error -> {eq, conds, false}
          end
      end
    end)
  end

  defp pushdown(_, _resource), do: {%{}, [], false}

  defp conjuncts(%Ash.Query.BooleanExpression{op: :and, left: l, right: r}),
    do: conjuncts(l) ++ conjuncts(r)

  defp conjuncts(nil), do: []
  defp conjuncts(expr), do: [expr]

  defp pushdown_eq(%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{} = ref, right: value}, resource)
       when not is_struct(value, Ash.Query.Ref) do
    with {:ok, attr} <- plain_attribute(ref, resource),
         true <- attr_kind(attr) in [:ordered, :exact],
         {:ok, encoded} <- encode_value(attr, value) do
      {:ok, {attr.name, encoded}}
    else
      _ -> :error
    end
  end

  defp pushdown_eq(_, _resource), do: :error

  @comparisons %{
    Ash.Query.Operator.GreaterThan => " > ",
    Ash.Query.Operator.GreaterThanOrEqual => " >= ",
    Ash.Query.Operator.LessThan => " < ",
    Ash.Query.Operator.LessThanOrEqual => " <= "
  }

  # A WHERE condition, as Cypher parts, or :error when it does not translate
  # exactly.
  defp condition(%Ash.Query.BooleanExpression{op: op, left: l, right: r}, resource) do
    with {:ok, lp} <- condition(l, resource),
         {:ok, rp} <- condition(r, resource) do
      kw = if op == :and, do: ") AND (", else: ") OR ("
      {:ok, ["("] ++ lp ++ [kw] ++ rp ++ [")"]}
    end
  end

  defp condition(%Ash.Query.Operator.Eq{left: %Ash.Query.Ref{}} = expr, resource) do
    with {:ok, {name, value}} <- pushdown_eq(expr, resource),
         do: {:ok, [prop(name), " = ", {:param, value}]}
  end

  defp condition(%mod{left: %Ash.Query.Ref{} = ref, right: value}, resource)
       when is_map_key(@comparisons, mod) and not is_struct(value, Ash.Query.Ref) do
    with {:ok, attr} <- plain_attribute(ref, resource),
         :ordered <- attr_kind(attr),
         {:ok, encoded} <- encode_value(attr, value) do
      {:ok, [prop(attr.name), @comparisons[mod], {:param, encoded}]}
    else
      _ -> :error
    end
  end

  defp condition(%Ash.Query.Operator.In{left: %Ash.Query.Ref{} = ref, right: values}, resource) do
    with {:ok, attr} <- plain_attribute(ref, resource),
         true <- attr_kind(attr) in [:ordered, :exact],
         list when is_list(list) <- values |> Enum.to_list() |> encode_all(attr) do
      {:ok, [prop(attr.name), " IN ", {:param, list}]}
    else
      _ -> :error
    end
  end

  defp condition(%Ash.Query.Operator.IsNil{left: %Ash.Query.Ref{} = ref, right: nil?}, resource)
       when is_boolean(nil?) do
    with {:ok, attr} <- plain_attribute(ref, resource) do
      {:ok, [prop(attr.name), if(nil?, do: " IS NULL", else: " IS NOT NULL")]}
    end
  end

  defp condition(_, _resource), do: :error

  defp prop(name), do: "n." <> Q.ident(name)

  defp plain_attribute(%Ash.Query.Ref{attribute: attr, relationship_path: []}, resource) do
    case attr do
      %Ash.Resource.Attribute{} = a -> {:ok, a}
      name when is_atom(name) -> wrap_attr(Ash.Resource.Info.attribute(resource, name))
      _ -> :error
    end
  end

  defp plain_attribute(_, _resource), do: :error

  defp wrap_attr(nil), do: :error
  defp wrap_attr(attr), do: {:ok, attr}

  # How an attribute's stored form compares. :ordered - equality and order
  # both match the original (numbers, text); :exact - equality only (the
  # encoding is one-to-one); anything else is not pushed down.
  defp attr_kind(%{type: type}) do
    case Ash.Type.get_type(type) do
      t when t in [Ash.Type.Integer, Ash.Type.Float, Ash.Type.String] -> :ordered
      t when t in [Ash.Type.Boolean, Ash.Type.Atom, Ash.Type.UUID, Ash.Type.UUIDv7, Ash.Type.Date] -> :exact
      _ -> :other
    end
  end

  defp encode_value(attr, value) do
    with {:ok, dumped} <- Ash.Type.dump_to_native(attr.type, value, attr.constraints),
         encoded when not is_nil(encoded) and not is_list(encoded) <- Type.encode(dumped) do
      {:ok, encoded}
    else
      _ -> :error
    end
  end

  defp encode_all(values, attr) do
    Enum.reduce_while(values, [], fn v, acc ->
      case encode_value(attr, v) do
        {:ok, e} -> {:cont, [e | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      list -> Enum.reverse(list)
    end
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

  @doc false
  @impl true
  def bulk_create(resource, stream, options) do
    handle = Info.handle(resource)

    # One transaction for the batch: a failure part-way leaves nothing behind,
    # and glider commits the whole batch to its log at once.
    result =
      Glider.transaction(handle, fn ->
        Enum.map(stream, fn changeset ->
          with {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
               {:ok, props} <- dump(record, resource),
               :ok <- do_create(resource, props) do
            record
            |> set_loaded(resource)
            |> Ash.Actions.Helpers.Bulk.put_metadata(changeset)
          else
            {:error, error} -> Glider.rollback(handle, error)
          end
        end)
      end)

    case result do
      {:ok, records} -> if options[:return_records?], do: {:ok, records}, else: :ok
      {:error, error} -> {:error, Ash.Error.to_ash_error(error)}
    end
  end

  defp do_create(resource, props) do
    handle = Info.handle(resource)
    label = Info.label(resource)
    ensure_indexes(resource, handle, label)

    # A nil property is simply absent from the node, which is how glider
    # represents "unset" — writing an explicit null would make `IS NULL` and
    # `keys()` disagree.
    props = props |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    case Glider.query(handle, Q.create(Q.vertex(:n, to_string(label), props))) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Ash.Error.to_ash_error(reason)}
    end
  end

  @doc false
  @impl true
  def update(resource, changeset) do
    with {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
         {:ok, props} <- dump(record, resource),
         {:ok, pk} <- pk_props(changeset.data, resource) do
      q =
        Q.vertex(:n, to_string(Info.label(resource)), pk)
        |> Q.match()
        |> Q.set_props(:n, props)

      case Glider.query(Info.handle(resource), q) do
        {:ok, %{touched: 0}} -> {:error, not_found(changeset.data, resource)}
        {:ok, _} -> {:ok, set_loaded(record, resource)}
        {:error, reason} -> {:error, Ash.Error.to_ash_error(reason)}
      end
    end
  end

  @doc false
  @impl true
  def destroy(resource, %{data: record}) do
    with {:ok, pk} <- pk_props(record, resource) do
      # DETACH so a node's edges go with it; leaving dangling relationships
      # behind would corrupt every traversal through this node.
      q =
        Q.vertex(:n, to_string(Info.label(resource)), pk)
        |> Q.match()
        |> Q.delete(:n, detach: true)

      case Glider.query(Info.handle(resource), q) do
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

  @doc false
  # The record's primary key as encoded properties, for a MATCH pattern.
  def pk_props(record, resource) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, acc} ->
      attr = Ash.Resource.Info.attribute(resource, key)

      case Ash.Type.dump_to_native(attr.type, Map.get(record, key), attr.constraints) do
        {:ok, dumped} when not is_nil(dumped) -> {:cont, {:ok, Map.put(acc, key, Type.encode(dumped))}}
        _ -> {:halt, {:error, Ash.Error.to_ash_error("could not encode primary key #{key}")}}
      end
    end)
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

  # Indexes are created lazily on first use and stored in the database, so
  # this is a no-op after the first call. Doing it here rather than in a
  # migration keeps the extension free of setup steps. Inside a transaction it
  # waits: a rollback would take the index with it.
  defp ensure_indexes(resource, handle, label) do
    key = {__MODULE__, :indexed, resource}

    cond do
      :persistent_term.get(key, false) ->
        :ok

      Glider.in_transaction?(handle) ->
        :ok

      true ->
        pk = Ash.Resource.Info.primary_key(resource)

        for attr <- Enum.uniq(pk ++ Info.index(resource)) do
          Glider.query(handle, "INDEX ON :#{Q.ident(to_string(label))}(#{Q.ident(attr)})")
        end

        :persistent_term.put(key, true)
        :ok
    end
  end
end
