defmodule FornacastUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps do
    []
  end

  defp releases do
    [
      fornacast: [
        applications: [
          fornacast: :permanent,
          forge_accounts: :permanent,
          forge_repos: :permanent,
          git_core: :permanent,
          git_transport: :permanent,
          fornacast_web: :permanent
        ]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.build": ["duskmoon_bundler.build fornacast_web --tailwind"],
      "assets.deploy": [
        "phx.digest.clean",
        "duskmoon_bundler.build fornacast_web --tailwind --minify",
        "phx.digest"
      ],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
