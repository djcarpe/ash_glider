defmodule Explorer.MixProject do
  use Mix.Project

  def project do
    [
      app: :explorer,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [mod: {Explorer.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The library this app demonstrates. It pulls in glider_ex (the NIF) from
      # ../glider_ex relative to itself, so building needs `cargo` on the PATH.
      {:ash_glider, path: "../.."},
      {:ash, "~> 3.0"},
      {:ash_phoenix, "~> 2.3"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"],
      "explorer.reset": ["run -e 'Explorer.Seeds.reset!()'"]
    ]
  end
end
