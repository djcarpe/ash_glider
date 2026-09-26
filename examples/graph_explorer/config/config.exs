import Config

config :ash, default_string_length_count: :mixed
config :explorer, ash_domains: [Explorer.Directory]

config :explorer, ExplorerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: ExplorerWeb.ErrorHTML], layout: false],
  pubsub_server: Explorer.PubSub,
  live_view: [signing_salt: "gl1d3r-explorer"]

config :phoenix, :json_library, Jason
config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
