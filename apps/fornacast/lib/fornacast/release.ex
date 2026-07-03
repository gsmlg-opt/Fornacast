defmodule Fornacast.Release do
  @moduledoc """
  Release-time operational helpers.
  """

  @app :fornacast

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _apps, _fun_return} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
