defmodule ForgePulls.HeadRepositoryDeleteMigrationRepo do
  use Ecto.Repo,
    otp_app: :forge_pulls,
    adapter: Ecto.Adapters.Postgres
end

defmodule ForgePulls.HeadRepositoryDeleteMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgePulls.HeadRepositoryDeleteMigrationRepo, as: MigrationRepo
  alias Fornacast.Repo
  alias Fornacast.Repo.Migrations.DeferPullHeadRepositoryConstraint, as: Migration

  @version 20_261_010_000_000
  @migration_path Path.expand(
                    "../../fornacast/priv/repo/migrations/20261010000000_defer_pull_head_repository_constraint.exs",
                    __DIR__
                  )
  @moduletag skip: Repo.__adapter__() != Ecto.Adapters.Postgres

  setup do
    unless Code.ensure_loaded?(Migration), do: Code.require_file(@migration_path)
    schema = "pull_head_delete_#{System.unique_integer([:positive])}"

    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.update(
        :parameters,
        [search_path: schema],
        &Keyword.put(&1, :search_path, schema)
      )

    start_supervised!({MigrationRepo, config})
    SQL.query!(MigrationRepo, ~s(CREATE SCHEMA "#{schema}"), [])

    on_exit(fn ->
      config
      |> Keyword.put(:name, nil)
      |> MigrationRepo.start_link()
      |> case do
        {:ok, cleanup_repo} ->
          try do
            SQL.query!(cleanup_repo, ~s(DROP SCHEMA "#{schema}" CASCADE), [])
          after
            GenServer.stop(cleanup_repo)
          end
      end
    end)

    SQL.query!(MigrationRepo, "CREATE TABLE repositories (id bigint PRIMARY KEY)", [])

    SQL.query!(
      MigrationRepo,
      "CREATE TABLE pull_requests (id bigint PRIMARY KEY, repository_id bigint NOT NULL, " <>
        "head_repository_id bigint, " <>
        "CONSTRAINT pull_requests_repository_id_fkey FOREIGN KEY (repository_id) " <>
        "REFERENCES repositories(id) ON DELETE CASCADE, " <>
        "CONSTRAINT pull_requests_head_repository_id_fkey FOREIGN KEY (head_repository_id) " <>
        "REFERENCES repositories(id) ON DELETE NO ACTION)",
      []
    )

    %{rows: triggers} =
      SQL.query!(
        MigrationRepo,
        "SELECT t.tgname, c.conname FROM pg_trigger t " <>
          "JOIN pg_constraint c ON c.oid = t.tgconstraint " <>
          "JOIN pg_proc p ON p.oid = t.tgfoid " <>
          "WHERE t.tgrelid = 'repositories'::regclass " <>
          "AND p.proname IN ('RI_FKey_noaction_del', 'RI_FKey_cascade_del')",
        []
      )

    for [trigger, constraint] <- triggers do
      name =
        if constraint == "pull_requests_head_repository_id_fkey",
          do: "a_head_noaction",
          else: "z_repository_cascade"

      SQL.query!(
        MigrationRepo,
        ~s(ALTER TRIGGER "#{trigger}" ON repositories RENAME TO "#{name}"),
        []
      )
    end

    :ok
  end

  test "same-repository cascades survive head-first trigger order while cross-head deletes fail at commit" do
    SQL.query!(MigrationRepo, "INSERT INTO repositories VALUES (1), (2), (3)", [])
    SQL.query!(MigrationRepo, "INSERT INTO pull_requests VALUES (1, 1, 1), (2, 2, 3)", [])
    assert constraint_policy() == [false, false, "a"]

    assert_raise Postgrex.Error, ~r/pull_requests_head_repository_id_fkey/, fn ->
      SQL.query!(MigrationRepo, "DELETE FROM repositories WHERE id = 1", [])
    end

    assert :ok = Ecto.Migrator.up(MigrationRepo, @version, Migration, log: false)
    assert constraint_policy() == [true, true, "a"]

    assert {:ok, :cascaded} =
             MigrationRepo.transaction(fn ->
               assert %{num_rows: 1} =
                        SQL.query!(MigrationRepo, "DELETE FROM repositories WHERE id = 1", [])

               assert %{rows: [[0]]} =
                        SQL.query!(
                          MigrationRepo,
                          "SELECT count(*) FROM pull_requests WHERE id = 1",
                          []
                        )

               :cascaded
             end)

    assert_raise Postgrex.Error, ~r/pull_requests_head_repository_id_fkey/, fn ->
      MigrationRepo.transaction(fn ->
        assert %{num_rows: 1} =
                 SQL.query!(MigrationRepo, "DELETE FROM repositories WHERE id = 3", [])

        send(self(), :cross_head_delete_reached_commit)
        :deletion_reached_commit
      end)
    end

    assert_received :cross_head_delete_reached_commit

    assert %{rows: [[3]]} =
             SQL.query!(MigrationRepo, "SELECT id FROM repositories WHERE id = 3", [])

    assert :ok = Ecto.Migrator.down(MigrationRepo, @version, Migration, log: false)
    assert constraint_policy() == [false, false, "a"]

    assert_raise Postgrex.Error, ~r/pull_requests_head_repository_id_fkey/, fn ->
      SQL.query!(MigrationRepo, "DELETE FROM repositories WHERE id = 3", [])
    end
  end

  defp constraint_policy do
    %{rows: [policy]} =
      SQL.query!(
        MigrationRepo,
        "SELECT condeferrable, condeferred, confdeltype::text FROM pg_constraint " <>
          "WHERE conrelid = 'pull_requests'::regclass " <>
          "AND conname = 'pull_requests_head_repository_id_fkey'",
        []
      )

    policy
  end
end
