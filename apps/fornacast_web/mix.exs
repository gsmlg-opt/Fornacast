defmodule FornacastWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :fornacast_web,
      version: "0.7.3",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {FornacastWeb.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:fornacast_component, in_umbrella: true},
      {:forge_accounts, in_umbrella: true},
      {:forge_github, in_umbrella: true},
      {:forge_imports, in_umbrella: true},
      {:forge_issues, in_umbrella: true},
      {:forge_pulls, in_umbrella: true},
      {:forge_releases, in_umbrella: true},
      {:forge_repos, in_umbrella: true},
      {:git_core, in_umbrella: true},
      {:git_lfs, in_umbrella: true},
      {:git_transport, in_umbrella: true},
      {:phoenix, "~> 1.8.15"},
      # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#186 - verify Alpine before upgrading.
      # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#187 - support HTTP family 0.18.
      {:phoenix_duskmoon, "~> 9.16.7"},
      {:duskmoon_bundler_runtime, "~> 9.16.1"},
      {:duskmoon_bundler, "~> 9.16.1", runtime: Mix.env() == :dev},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 4.3"},
      {:bandit, "~> 1.12"},
      {:mdex, "~> 0.14.2"}
    ]
  end
end
