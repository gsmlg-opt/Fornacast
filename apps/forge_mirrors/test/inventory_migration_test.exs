defmodule ForgeMirrors.InventoryMigrationRepo do
  @moduledoc false

  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)
  use Ecto.Repo, otp_app: :fornacast, adapter: @adapter
end

defmodule ForgeMirrors.InventoryMigrationTest do
  use ExUnit.Case, async: false

  alias ForgeMirrors.InventoryMigrationRepo
  alias Fornacast.Repo

  @version 20_260_905_000_200

  test "inventory fields roll down and back up with direct constraints" do
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      repo = start_migration_repo!()
      path = Application.app_dir(:fornacast, "priv/repo/migrations")

      try do
        rolled_versions = Ecto.Migrator.run(repo, path, :down, to: @version, log: false)
        assert @version in rolled_versions
        refute column?(repo, "repository_mirrors", "github_archived")
        refute column?(repo, "mirror_operations", "checkpoint")

        assert [@version] = Ecto.Migrator.run(repo, path, :up, to: @version, log: false)
        assert column?(repo, "repository_mirrors", "github_archived")
        assert column?(repo, "repository_mirrors", "inventory_included")
        assert column?(repo, "repository_mirrors", "inventory_selection")
        assert column?(repo, "repository_mirrors", "last_inventory_sweep")
        assert column?(repo, "mirror_operations", "checkpoint")

        assert constraint?(repo, "repository_mirrors_inventory_selection_check")
        assert constraint?(repo, "repository_mirrors_inventory_sweep_check")
        assert constraint?(repo, "mirror_operations_checkpoint_check")
      after
        Ecto.Migrator.run(repo, path, :up, all: true, log: false)
      end
    end
  end

  defp constraint?(repo, name) do
    %{rows: [[exists?]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select exists(select 1 from pg_constraint where conname = $1)",
        [name]
      )

    exists?
  end

  defp column?(repo, table, column) do
    %{rows: [[exists?]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select exists(select 1 from information_schema.columns where table_schema = current_schema() and table_name = $1 and column_name = $2)",
        [table, column]
      )

    exists?
  end

  defp start_migration_repo! do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({InventoryMigrationRepo, config})
    InventoryMigrationRepo
  end
end
