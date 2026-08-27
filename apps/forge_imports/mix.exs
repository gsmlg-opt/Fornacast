defmodule ForgeImports.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_imports,
      version: "0.2.0",
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
    [extra_applications: [:logger, :crypto], mod: {ForgeImports.Application, []}]
  end

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:forge_accounts, in_umbrella: true},
      {:forge_repos, in_umbrella: true},
      {:git_core, in_umbrella: true},
      {:ecto, "~> 3.14"},
      {:mint, "~> 1.9"},
      {:req, "~> 0.7"}
    ]
  end
end
