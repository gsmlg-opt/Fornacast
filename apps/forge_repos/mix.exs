defmodule ForgeRepos.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_repos,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ForgeRepos.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:forge_accounts, in_umbrella: true},
      {:git_core, in_umbrella: true},
      {:ecto, "~> 3.14"}
    ]
  end
end
