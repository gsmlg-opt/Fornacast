defmodule Fornacast.MixProject do
  use Mix.Project

  def project do
    [
      app: :fornacast,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {Fornacast.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      # TODO(upstream): gsmlg-dev/concord#77
      {:ex_turso, "~> 3.0"},
      # TODO(upstream): gsmlg-dev/concord#76
      {:concord, "~> 3.0"},
      {:postgrex, "~> 0.22.2"},
      {:phoenix_pubsub, "~> 2.2"}
    ]
  end
end
