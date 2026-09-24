defmodule ForgeReleases.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_releases,
      version: "0.7.1",
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
      mod: {ForgeReleases.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:forge_accounts, in_umbrella: true},
      {:forge_blobs, in_umbrella: true},
      {:forge_repos, in_umbrella: true},
      {:git_core, in_umbrella: true},
      {:ecto, "~> 3.14"}
    ]
  end
end
