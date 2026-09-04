defmodule ForgeMirrors.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_mirrors,
      version: "0.2.2",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [
      mod: {ForgeMirrors.Application, []},
      extra_applications: [:logger]
    ]
  end
end
