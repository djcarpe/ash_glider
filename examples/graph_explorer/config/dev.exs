import Config

# The graph lives in one file. Delete it (or run `mix explorer.reset`) to start
# over; the app seeds demo data whenever it boots onto an empty graph.
config :explorer, Explorer.Graph,
  path: Path.expand("../priv/graph/explorer.gldb", __DIR__),
  sync: :normal

config :explorer, seed_on_boot: true

config :explorer, ExplorerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-dev-only-secret-key-base-dev-only-secret-key"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, debug_heex_annotations: true
