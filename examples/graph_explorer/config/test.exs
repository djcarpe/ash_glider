import Config

# No :path, so every test run gets a fresh in-memory graph.
config :explorer, Explorer.Graph, []
config :explorer, seed_on_boot: false

config :explorer, ExplorerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-test-only-secret-key-base-test-only-secret",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
