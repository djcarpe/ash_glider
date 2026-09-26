defmodule Explorer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # glider creates the file but not its directory.
    if path = Explorer.Graph.config()[:path], do: File.mkdir_p!(Path.dirname(path))

    children = [
      # The graph must start before anything reads through the data layer.
      Explorer.Graph,
      {Phoenix.PubSub, name: Explorer.PubSub},
      ExplorerWeb.Endpoint
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Explorer.Supervisor) do
      if Application.get_env(:explorer, :seed_on_boot, false), do: Explorer.Seeds.seed_if_empty()
      {:ok, pid}
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ExplorerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
