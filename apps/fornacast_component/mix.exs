defmodule FornacastComponent.MixProject do
  use Mix.Project

  def project do
    [
      app: :fornacast_component,
      version: "0.7.4",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: []

  defp deps do
    [
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_duskmoon, "~> 9.16.11"},
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end
end
