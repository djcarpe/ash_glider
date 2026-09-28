defmodule AshGlider.Info do
  @moduledoc """
  Introspection for the `graph` DSL section.
  """

  use Spark.InfoGenerator, extension: AshGlider.DataLayer, sections: [:graph]

  @doc """
  The node label for a resource.

  Defaults to the last segment of the module name, so `MyApp.Person` becomes
  `:Person` — which is also what a reader of the raw graph would expect to see.
  """
  @spec label(Ash.Resource.t()) :: atom()
  def label(resource) do
    case graph_label(resource) do
      {:ok, label} when not is_nil(label) ->
        label

      _ ->
        resource
        |> Module.split()
        |> List.last()
        |> String.to_atom()
    end
  end

  @doc "The configured `AshGlider.Graph` module."
  @spec graph(Ash.Resource.t()) :: module()
  def graph(resource) do
    case graph_graph(resource) do
      {:ok, graph} when not is_nil(graph) ->
        graph

      _ ->
        raise """
        #{inspect(resource)} has no graph configured.

            graph do
              graph MyApp.Graph
            end
        """
    end
  end

  @doc "Attributes to index, from the `index` option."
  @spec index(Ash.Resource.t()) :: [atom()]
  def index(resource) do
    case graph_index(resource) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  The live glider handle backing a resource, for the tenant of the operation
  in progress (see `AshGlider.Tenant`), or the graph's one handle when the
  graph does not distinguish tenants.
  """
  @spec handle(Ash.Resource.t()) :: term()
  def handle(resource), do: handle(resource, AshGlider.Tenant.current())

  @doc "The live glider handle backing a resource for one tenant."
  @spec handle(Ash.Resource.t(), term()) :: term()
  def handle(resource, tenant), do: resource |> graph() |> then(& &1.handle(tenant))
end
