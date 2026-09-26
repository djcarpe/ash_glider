defmodule ExplorerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :explorer

  @session_options [
    store: :cookie,
    key: "_explorer_key",
    signing_salt: "gl1d3r-sess",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # No bundler: the app's own JS and CSS are plain files, and the Phoenix and
  # LiveView clients are served straight out of their packages.
  plug Plug.Static, at: "/", from: :explorer, gzip: false, only: ExplorerWeb.static_paths()

  plug Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor/lv",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ExplorerWeb.Router
end
