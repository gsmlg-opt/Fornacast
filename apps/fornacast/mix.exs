defmodule Fornacast.MixProject do
  use Mix.Project

  def project do
    [
      app: :fornacast,
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
      extra_applications: [:logger, :ssl],
      mod: {Fornacast.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:ex_turso, "~> 0.3"},
      {:concord, "~> 2.4"},
      {:postgrex, "~> 0.22.2"},
      {:phoenix_pubsub, "~> 2.2"}
    ]
  end
end
