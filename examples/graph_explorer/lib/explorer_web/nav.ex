defmodule ExplorerWeb.Nav do
  @moduledoc """
  Shared LiveView plumbing: the sidebar's per-label counts, which nav item is
  active, and navigation when a node on any graph canvas is clicked.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> refresh_counts()
      |> attach_hook(:active_nav, :handle_params, fn _params, uri, socket ->
        {:cont, assign(socket, :current_path, URI.parse(uri).path)}
      end)
      |> attach_hook(:graph_click, :handle_event, fn
        "graph_click", %{"href" => href}, socket when is_binary(href) ->
          {:halt, push_navigate(socket, to: href)}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  @doc "Re-read the sidebar counts after anything that adds or removes nodes."
  def refresh_counts(socket), do: assign(socket, :counts, Explorer.GraphOps.label_counts())
end
