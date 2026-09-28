defmodule AshGlider.Tenant do
  @moduledoc """
  The tenant of the data-layer operation in progress.

  Ash hands the tenant to `run_query/2` and to the changeset of every write,
  but not to `transaction/4`, `rollback/2` or the helpers underneath them, so
  the data layer notes it here, in the process, as each operation begins.
  `AshGlider.Graph.handle/1` implementations receive it; a graph with one
  database ignores it.
  """

  @key {AshGlider, :tenant}

  @doc "Records the tenant for the rest of this process's operation."
  @spec put(term()) :: :ok
  def put(tenant) do
    Process.put(@key, tenant)
    :ok
  end

  @doc "The tenant of the operation in progress, or nil."
  @spec current() :: term()
  def current, do: Process.get(@key)
end
