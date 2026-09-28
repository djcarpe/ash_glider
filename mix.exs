defmodule AshGlider.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_glider,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "An Ash data layer for glider, an embeddable property-graph database.",
      package: [licenses: ["MIT"], files: ~w(lib mix.exs README.md LICENSE)]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:glider_ex, path: "../glider_ex"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
