defmodule ForgeGitHub.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_github,
      version: "0.2.2",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ForgeGitHub.Application, []},
      extra_applications: [:inets, :logger, :public_key]
    ]
  end

  defp deps do
    [
      {:forge_mirrors, in_umbrella: true},
      {:mint, "~> 1.9"},
      {:plug, "~> 1.19"},
      {:req, "~> 0.7"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
