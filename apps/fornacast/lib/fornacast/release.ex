defmodule Fornacast.Release do
  @moduledoc """
  Release tasks for database management.

  Run migrations from a packaged release with:

      bin/fornacast migrate

  The command is dispatched through `rel/env.sh.eex` to the underlying
  non-booted release evaluation.
  """

  @app :fornacast

  @doc "Runs all pending database migrations for the configured repositories."
  @spec migrate() :: :ok
  def migrate do
    Application.ensure_all_started(:ssl)
    load_app()

    applied_migrations =
      Enum.flat_map(repos(), fn repo ->
        {:ok, versions, _fun_return} =
          Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))

        versions
      end)

    IO.puts("applied_migrations=#{length(applied_migrations)}")
    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
      {:error, reason} -> raise "could not load #{@app}: #{inspect(reason)}"
    end
  end
end
