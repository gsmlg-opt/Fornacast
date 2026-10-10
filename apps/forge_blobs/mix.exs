defmodule ForgeBlobs.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_blobs,
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

  def application do
    [
      mod: {ForgeBlobs.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:fornacast, in_umbrella: true},
      {:ex_storage_service, "== 0.6.6"}
    ]
  end
end
