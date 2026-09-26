defmodule AshGlider.Graph do
  @moduledoc """
  Owns a glider graph and its lifecycle.

      defmodule MyApp.Graph do
        use AshGlider.Graph, otp_app: :my_app
      end

  Then in your supervision tree:

      children = [MyApp.Graph]

  Configure the file (or leave it out for an in-memory graph):

      config :my_app, MyApp.Graph,
        path: "priv/graph/my_app.gldb",
        sync: :normal

  ## Why a process, when the handle is already safe to share

  Two reasons, and neither is serialisation.

  A glider handle is a NIF resource: safe to call from any process, and already
  serialised internally by a mutex. Routing every call through a `GenServer`
  mailbox would add a full copy of every result set and buy nothing.

  So this process *owns* the handle — opening it on start, closing it on
  terminate, so the file lock is tied to a supervised lifecycle — but hands the
  handle out through `handle/1`. Callers then invoke the NIF directly. The
  handle is cached in `:persistent_term` so a lookup is a read, not a message.
  """

  @type t :: module()

  @doc "Fetch the graph handle. Raises if the process has not started."
  @callback handle() :: term()

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour AshGlider.Graph

      @otp_app opts[:otp_app] ||
                 raise(ArgumentError, "use AshGlider.Graph requires :otp_app")

      def child_spec(arg) do
        %{
          id: __MODULE__,
          start: {AshGlider.Graph.Server, :start_link, [{__MODULE__, @otp_app, arg}]},
          type: :worker
        }
      end

      @impl AshGlider.Graph
      def handle, do: AshGlider.Graph.handle(__MODULE__)

      @doc "This graph's configuration, from the application environment."
      def config, do: Application.get_env(@otp_app, __MODULE__, [])

      @doc "Start outside a supervision tree. Useful in tests and scripts."
      def start_link(opts \\ []) do
        AshGlider.Graph.Server.start_link({__MODULE__, @otp_app, opts})
      end
    end
  end

  @key_prefix {__MODULE__, :handle}

  @doc """
  The handle for a graph module.

  Raises with an actionable message rather than returning nil, because every
  caller is in the middle of a data-layer operation that cannot proceed.
  """
  @spec handle(module()) :: term()
  def handle(graph) do
    case :persistent_term.get({@key_prefix, graph}, nil) do
      nil ->
        raise """
        #{inspect(graph)} is not running.

        Add it to your supervision tree:

            children = [#{inspect(graph)}]

        or start it directly with #{inspect(graph)}.start_link/1.
        """

      handle ->
        handle
    end
  end

  @doc false
  def put_handle(graph, handle), do: :persistent_term.put({@key_prefix, graph}, handle)

  @doc false
  def delete_handle(graph), do: :persistent_term.erase({@key_prefix, graph})
end

defmodule AshGlider.Graph.Server do
  @moduledoc false
  use GenServer

  def start_link({module, _otp_app, _opts} = arg) do
    GenServer.start_link(__MODULE__, arg, name: module)
  end

  @impl true
  def init({module, otp_app, opts}) do
    # Closing the graph on shutdown releases glider's file lock, so a
    # supervisor restart can reopen the same path instead of colliding with a
    # handle nobody holds any more.
    Process.flag(:trap_exit, true)

    config =
      Application.get_env(otp_app, module, [])
      |> Keyword.merge(List.wrap(if(is_list(opts), do: opts, else: [])))

    case open(config) do
      {:ok, handle} ->
        AshGlider.Graph.put_handle(module, handle)
        {:ok, %{module: module, handle: handle, config: config}}

      {:error, reason} ->
        {:stop, {:glider_open_failed, reason}}
    end
  end

  defp open(config) do
    case Keyword.get(config, :path) do
      nil -> Glider.open()
      path -> Glider.open(path, Keyword.get(config, :sync, :normal))
    end
  end

  @impl true
  def handle_call(:handle, _from, state), do: {:reply, state.handle, state}

  def handle_call(:checkpoint, _from, state) do
    {:reply, Glider.checkpoint(state.handle), state}
  end

  def handle_call(:compact, _from, state) do
    {:reply, Glider.compact(state.handle), state}
  end

  @impl true
  def terminate(_reason, state) do
    AshGlider.Graph.delete_handle(state.module)
    Glider.close(state.handle)
    :ok
  end
end
