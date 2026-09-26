import Config

if config_env() == :prod do
  config :explorer, Explorer.Graph,
    path: System.get_env("GRAPH_PATH", "priv/graph/explorer.gldb"),
    sync: :normal

  config :explorer, seed_on_boot: true

  config :explorer, ExplorerWeb.Endpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
