defmodule ForgeReleases.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_releases,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ForgeReleases.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      # TODO(upstream): gsmlg-opt/ex_storage_service#17
      {:ex_storage_service, "== 0.6.4"}
    ]
  end
end
