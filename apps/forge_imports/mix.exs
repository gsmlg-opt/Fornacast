defmodule ForgeImports.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_imports,
      version: "0.2.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {ForgeImports.Application, []}]
  end

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:forge_accounts, in_umbrella: true},
      {:forge_issues, in_umbrella: true},
      {:forge_pulls, in_umbrella: true},
      {:forge_repos, in_umbrella: true},
      {:git_core, in_umbrella: true},
      {:ecto, "~> 3.14"},
      {:mint, "~> 1.9"},
      {:req, "~> 0.7"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
