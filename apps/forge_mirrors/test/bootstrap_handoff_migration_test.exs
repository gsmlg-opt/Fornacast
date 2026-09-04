defmodule ForgeMirrors.BootstrapHandoffMigrationRepo do
  @moduledoc false

  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)
  use Ecto.Repo, otp_app: :fornacast, adapter: @adapter
end

defmodule ForgeMirrors.BootstrapHandoffMigrationTest do
  use ExUnit.Case, async: false

  alias ForgeMirrors.BootstrapHandoffMigrationRepo
  alias Fornacast.Repo

  @version 20_260_905_000_500
  @constraint "mirror_resource_states_resource_kind_check"

  test "label resource mappings roll down and back up with the direct constraint" do
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      repo = start_migration_repo!()
      path = Application.app_dir(:fornacast, "priv/repo/migrations")

      try do
        rolled_versions = Ecto.Migrator.run(repo, path, :down, to: @version, log: false)
        assert @version in rolled_versions
        refute constraint_definition(repo, @constraint) =~ "'label'"

        assert [@version] = Ecto.Migrator.run(repo, path, :up, to: @version, log: false)
        assert constraint_definition(repo, @constraint) =~ "'label'"
      after
        Ecto.Migrator.run(repo, path, :up, all: true, log: false)
      end
    end
  end

  defp constraint_definition(repo, name) do
    %{rows: [[definition]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select pg_get_constraintdef(oid) from pg_constraint where conname = $1",
        [name]
      )

    definition
  end

  defp start_migration_repo! do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({BootstrapHandoffMigrationRepo, config})
    BootstrapHandoffMigrationRepo
  end
end
