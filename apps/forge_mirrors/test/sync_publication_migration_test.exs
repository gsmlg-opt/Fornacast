defmodule ForgeMirrors.SyncPublicationMigrationRepo do
  @moduledoc false

  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)
  use Ecto.Repo, otp_app: :fornacast, adapter: @adapter
end

defmodule ForgeMirrors.SyncPublicationMigrationTest do
  use ExUnit.Case, async: false

  alias ForgeMirrors.SyncPublicationMigrationRepo
  alias Fornacast.Repo

  @publication_version 20_260_907_000_000
  @lfs_version 20_260_907_000_100

  test "publication and LFS gates restore their previous constraints when new states are absent" do
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      repo = start_migration_repo!()

      try do
        assert @lfs_version in Ecto.Migrator.run(repo, migrations_path(), :down,
                 to: @lfs_version,
                 log: false
               )

        assert lfs_state_constraint(repo) =~ "'scanning'"
        assert lfs_state_constraint(repo) =~ "'complete'"
        assert lfs_state_constraint(repo) =~ "'published'"
        refute lfs_state_constraint(repo) =~ "'prepared'"

        assert lfs_completion_constraint(repo) =~ "published_at IS NOT NULL"
        refute lfs_completion_constraint(repo) =~ "'prepared'::text"

        assert [@lfs_version] =
                 Ecto.Migrator.run(repo, migrations_path(), :up, to: @lfs_version, log: false)

        assert @publication_version in Ecto.Migrator.run(repo, migrations_path(), :down,
                 to: @publication_version,
                 log: false
               )

        assert lifecycle_constraint(repo) =~ "'importing'"
        assert lifecycle_constraint(repo) =~ "'ready'"
        assert lifecycle_constraint(repo) =~ "'tombstoned'"
        refute lifecycle_constraint(repo) =~ "'synchronizing'"
      after
        Ecto.Migrator.run(repo, migrations_path(), :up, all: true, log: false)
      end
    end
  end

  test "publication gate refuses rollback while a repository is synchronizing" do
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      repo = start_migration_repo!()
      repository = insert_repository!(repo, "synchronizing")

      try do
        assert_raise Postgrex.Error, ~r/Cannot remove the publication gate/, fn ->
          Ecto.Migrator.run(repo, migrations_path(), :down, to: @publication_version, log: false)
        end

        assert lifecycle_constraint(repo) =~ "'synchronizing'"
      after
        delete_repository!(repo, repository)
        Ecto.Migrator.run(repo, migrations_path(), :up, all: true, log: false)
      end
    end
  end

  test "LFS distinction refuses rollback while prepared or published scans exist" do
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      repo = start_migration_repo!()
      Enum.each(["prepared", "published"], &assert_lfs_rollback_refused(repo, &1))
    end
  end

  defp insert_repository!(repo, lifecycle) do
    suffix = Ecto.UUID.generate()
    now = DateTime.utc_now(:second)

    %{rows: [[owner_id]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "insert into users (username, email, password_hash, role, state, kind, inserted_at, updated_at) values ($1, $2, 'hash', 'user', 'active', 'user', $3, $3) returning id",
        ["publication-owner-#{suffix}", "publication-owner-#{suffix}@example.test", now]
      )

    %{rows: [[repository_id]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "insert into repositories (owner_user_id, slug, name, visibility, storage_path, default_branch, lifecycle, generation, write_version, inserted_at, updated_at) values ($1, $2, $2, 'private', $3, 'main', $4, 1, 0, $5, $5) returning id",
        [
          owner_id,
          "publication-repository-#{suffix}",
          "/tmp/publication-repository-#{suffix}.git",
          lifecycle,
          now
        ]
      )

    %{id: repository_id, owner_id: owner_id}
  end

  defp insert_scan!(repo, repository_id, state) do
    now = DateTime.utc_now(:second)
    suffix = Ecto.UUID.generate()

    %{rows: [[scan_id]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "insert into lfs_pointer_scans (repository_id, repository_generation, scan_key, baseline_fingerprint, state, batch_limit, completed_at, published_at, inserted_at, updated_at) values ($1, 1, $2, $3, $4, 100, $5, $5, $5, $5) returning id",
        [repository_id, "publication-scan-#{suffix}", String.duplicate("a", 64), state, now]
      )

    scan_id
  end

  defp assert_lfs_rollback_refused(repo, state) do
    repository = insert_repository!(repo, "ready")
    scan_id = insert_scan!(repo, repository.id, state)

    try do
      assert_raise Postgrex.Error, ~r/Cannot discard the distinction/, fn ->
        Ecto.Migrator.run(repo, migrations_path(), :down, to: @lfs_version, log: false)
      end

      assert lfs_state_constraint(repo) =~ "'#{state}'"
    after
      Ecto.Adapters.SQL.query!(repo, "delete from lfs_pointer_scans where id = $1", [scan_id])
      delete_repository!(repo, repository)
      Ecto.Migrator.run(repo, migrations_path(), :up, all: true, log: false)
    end
  end

  defp delete_repository!(repo, %{id: repository_id, owner_id: owner_id}) do
    Ecto.Adapters.SQL.query!(repo, "delete from repositories where id = $1", [repository_id])
    Ecto.Adapters.SQL.query!(repo, "delete from users where id = $1", [owner_id])
  end

  defp lifecycle_constraint(repo), do: constraint_definition(repo, "repositories_lifecycle_check")

  defp lfs_state_constraint(repo),
    do: constraint_definition(repo, "lfs_pointer_scans_state_check")

  defp lfs_completion_constraint(repo),
    do: constraint_definition(repo, "lfs_pointer_scans_completion_check")

  defp constraint_definition(repo, name) do
    %{rows: [[definition]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select pg_get_constraintdef(oid) from pg_constraint where conname = $1",
        [name]
      )

    definition
  end

  defp migrations_path, do: Application.app_dir(:fornacast, "priv/repo/migrations")

  defp start_migration_repo! do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({SyncPublicationMigrationRepo, config})
    SyncPublicationMigrationRepo
  end
end
