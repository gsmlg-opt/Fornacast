defmodule ForgeImports.ImportPersistenceConstraintTest do
  use ExUnit.Case, async: false

  alias Fornacast.Repo

  @moduletag :persistence
  @now ~U[2026-08-26 00:00:00Z]

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    identity = identity_fixture(actor)
    %{actor: actor, identity: identity}
  end

  test "database rejects terminal one-time envelopes", %{actor: actor, identity: identity} do
    params = [
      actor.id,
      "organization",
      identity.id,
      "one_time",
      identity.github_user_id,
      identity.login,
      "failed",
      database_datetime(@now),
      <<1>>,
      :binary.copy(<<2>>, 12),
      :binary.copy(<<3>>, 16),
      "test-v1"
    ]

    placeholders = placeholders(length(params))

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_runs " <>
                 "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
                 "source_owner_github_id, source_owner_login, state, terminal_at, credential_ciphertext, " <>
                 "credential_nonce, credential_tag, credential_key_id, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders, ", ")}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_runs_terminal_envelope_check"
  end

  test "database rejects a saved credential source without a credential ID", %{
    actor: actor,
    identity: identity
  } do
    params = [
      actor.id,
      "organization",
      identity.id,
      "saved",
      identity.github_user_id,
      identity.login,
      "discovering"
    ]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_runs " <>
                 "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
                 "source_owner_github_id, source_owner_login, state, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_runs_credential_consistency_check"
  end

  test "database requires terminal timestamps and forbids them before terminal", %{
    actor: actor,
    identity: identity
  } do
    params = [
      actor.id,
      "organization",
      identity.id,
      "one_time",
      identity.github_user_id,
      identity.login,
      "failed"
    ]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_runs " <>
                 "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
                 "source_owner_github_id, source_owner_login, state, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_runs_terminal_at_check"
  end

  test "database forbids nonterminal timestamps", %{actor: actor, identity: identity} do
    params = [
      actor.id,
      "organization",
      identity.id,
      "one_time",
      identity.github_user_id,
      identity.login,
      "ready",
      database_datetime(@now)
    ]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_runs " <>
                 "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
                 "source_owner_github_id, source_owner_login, state, terminal_at, " <>
                 "inserted_at, updated_at) values " <>
                 "(#{Enum.join(placeholders(length(params)), ", ")}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_runs_terminal_at_check"
  end

  test "database forbids terminal run leases", %{actor: actor, identity: identity} do
    params = [
      actor.id,
      "organization",
      identity.id,
      "one_time",
      identity.github_user_id,
      identity.login,
      "failed",
      database_datetime(@now),
      "worker",
      database_datetime(DateTime.add(@now, 60, :second))
    ]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_runs " <>
                 "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
                 "source_owner_github_id, source_owner_login, state, terminal_at, " <>
                 "lease_owner, lease_expires_at, inserted_at, updated_at) values " <>
                 "(#{Enum.join(placeholders(length(params)), ", ")}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_runs_terminal_lease_check"
  end

  test "database enforces run resume-state coherence", %{actor: actor, identity: identity} do
    params = [
      actor.id,
      "organization",
      identity.id,
      "one_time",
      identity.github_user_id,
      identity.login,
      "awaiting_credential"
    ]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_runs " <>
                 "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
                 "source_owner_github_id, source_owner_login, state, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_runs_resume_state_coherence_check"
  end

  test "database forbids terminal item leases", %{actor: actor, identity: identity} do
    {:ok, run} = ForgeImports.create_run(actor, run_attrs(identity, 9_810_000_001))

    params = [
      run.id,
      9_810_000_101,
      "acme/terminal",
      "terminal",
      database_datetime(@now),
      "failed",
      "worker",
      database_datetime(DateTime.add(@now, 60, :second))
    ]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_repository_items " <>
                 "(import_run_id, github_repository_id, source_full_name, source_name, " <>
                 "source_observed_at, state, lease_owner, lease_expires_at, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_items_terminal_lease_check"
  end

  test "database enforces item resume-state coherence", %{actor: actor, identity: identity} do
    {:ok, run} = ForgeImports.create_run(actor, run_attrs(identity, 9_815_000_001))

    params = [
      run.id,
      9_815_000_101,
      "acme/waiting",
      "waiting",
      database_datetime(@now),
      "awaiting_credential"
    ]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_repository_items " <>
                 "(import_run_id, github_repository_id, source_full_name, source_name, " <>
                 "source_observed_at, state, inserted_at, updated_at) values " <>
                 "(#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_items_resume_state_coherence_check"
  end

  test "database requires attempt terminal timestamps", %{actor: actor, identity: identity} do
    {:ok, run} = ForgeImports.create_run(actor, run_attrs(identity, 9_820_000_001))

    {:ok, item} =
      ForgeImports.create_repository_item(actor, run, %{
        github_repository_id: 9_820_000_101,
        source_full_name: "acme/attempt",
        source_name: "attempt",
        source_metadata: %{},
        source_observed_at: @now
      })

    params = [item.id, 1, "failed", database_datetime(@now)]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_attempts " <>
                 "(repository_item_id, attempt_number, state, started_at, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert Exception.message(error) =~ "github_import_attempts_terminal_at_check"
  end

  test "raw report insert cannot pair an item with another run", %{
    actor: actor,
    identity: identity
  } do
    {:ok, first_run} = ForgeImports.create_run(actor, run_attrs(identity, 9_800_000_001))
    {:ok, second_run} = ForgeImports.create_run(actor, run_attrs(identity, 9_800_000_002))

    {:ok, item} =
      ForgeImports.create_repository_item(actor, first_run, %{
        github_repository_id: 9_800_000_101,
        source_full_name: "acme/demo",
        source_name: "demo",
        source_metadata: %{},
        source_observed_at: @now
      })

    params = [
      second_run.id,
      item.id,
      "cross-run",
      "repository",
      "warning",
      "ownership_mismatch",
      "Ownership mismatch"
    ]

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_report_entries " <>
                 "(import_run_id, repository_item_id, idempotency_key, scope, outcome, " <>
                 "classification, summary, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    if postgres?(),
      do: assert(Exception.message(error) =~ "github_import_reports_item_run_fkey"),
      else: assert(Exception.message(error) =~ "foreign key constraint failed")
  end

  test "recovery indexes include state time lease and stable id" do
    assert index_columns("github_import_runs_recovery_index") == [
             "state",
             "next_attempt_at",
             "lease_expires_at",
             "id"
           ]

    assert index_columns("github_import_items_recovery_index") == [
             "state",
             "next_attempt_at",
             "lease_expires_at",
             "id"
           ]
  end

  defp index_columns(name) do
    if postgres?() do
      %{rows: [[definition]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "select indexdef from pg_indexes where schemaname = current_schema() and indexname = $1",
          [name]
        )

      [columns] = Regex.run(~r/\(([^)]+)\)$/, definition, capture: :all_but_first)
      columns |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
    else
      %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, "pragma index_info('#{name}')", [])
      Enum.map(rows, &Enum.at(&1, 2))
    end
  end

  defp run_attrs(identity, source_owner_id) do
    %{
      source_kind: :organization,
      github_identity_id: identity.id,
      credential_source: :one_time,
      source_owner_github_id: source_owner_id,
      source_owner_login: identity.login,
      request_metadata: %{}
    }
  end

  defp placeholders(count) do
    if postgres?(), do: Enum.map(1..count, &"$#{&1}"), else: List.duplicate("?", count)
  end

  defp database_datetime(%DateTime{} = value) do
    naive = DateTime.to_naive(value)
    if postgres?(), do: naive, else: NaiveDateTime.to_iso8601(naive)
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 8_900_000_000 + suffix,
          login: "constraint-#{suffix}",
          avatar_url: nil,
          profile_url: nil
        },
        @now
      )

    {:ok, identity} = ForgeAccounts.link_github_identity(actor, identity)
    identity
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "constraint-user-#{suffix}",
        email: "constraint-user-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp reset_database! do
    for table <-
          ForgeImports.ImportPersistenceMigrationTestSupport.import_tables() ++
            [
              "github_credentials",
              "github_identities",
              "audit_events",
              "repository_collaborators",
              "repositories",
              "organization_members",
              "api_keys",
              "ssh_keys",
              "users"
            ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres?, do: ForgeImports.ImportPersistenceMigrationTestSupport.postgres?()
end

defmodule ForgeImports.ImportPersistenceMigrationTestSupport do
  @moduledoc false

  @import_tables [
    "github_import_report_entries",
    "github_import_page_checkpoints",
    "github_import_object_mappings",
    "github_import_attempts",
    "github_import_repository_items",
    "github_import_runs"
  ]

  def import_tables, do: @import_tables

  def postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end

defmodule ForgeImports.ImportPersistenceMigrationRepo do
  @moduledoc false

  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)

  use Ecto.Repo,
    otp_app: :fornacast,
    adapter: @adapter
end

defmodule ForgeImports.ImportPersistenceMigrationCycleTest do
  use ExUnit.Case, async: false

  alias ForgeImports.ImportPersistenceMigrationRepo
  alias Fornacast.Repo

  @moduletag :persistence
  @version 20_260_825_000_300

  test "Task 6 rollback is pre-DDL guarded on Turso and reversible on PostgreSQL" do
    repo = start_migration_repo!()

    clear_import_rows!(repo)
    assert migration_applied?(repo)
    assert Enum.all?(import_tables(), &table_exists?(repo, &1))

    if postgres?() do
      assert [@version] =
               Ecto.Migrator.run(repo, migrations_path(), :down, step: 1, log: false)

      refute migration_applied?(repo)
      refute Enum.any?(import_tables(), &table_exists?(repo, &1))

      assert [@version] =
               Ecto.Migrator.run(repo, migrations_path(), :up,
                 to: @version,
                 log: false
               )

      assert migration_applied?(repo)
      assert Enum.all?(import_tables(), &table_exists?(repo, &1))
    else
      assert_raise RuntimeError,
                   "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved",
                   fn ->
                     Ecto.Migrator.run(repo, migrations_path(), :down, step: 1, log: false)
                   end

      assert migration_applied?(repo)
      assert Enum.all?(import_tables(), &table_exists?(repo, &1))
    end
  end

  defp clear_import_rows!(repo) do
    Enum.each(import_tables(), fn table ->
      Ecto.Adapters.SQL.query!(repo, "delete from #{table}", [])
    end)
  end

  defp migration_applied?(repo) do
    placeholder = if postgres?(), do: "$1", else: "?"

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select version from schema_migrations where version = #{placeholder}",
        [@version]
      )

    rows == [[@version]]
  end

  defp table_exists?(repo, table) do
    if postgres?() do
      %{rows: [[exists?]]} =
        Ecto.Adapters.SQL.query!(repo, "select to_regclass($1) is not null", [table])

      exists?
    else
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select name from sqlite_schema where type = 'table' and name = ?",
          [table]
        )

      rows == [[table]]
    end
  end

  defp migrations_path, do: Application.app_dir(:fornacast, "priv/repo/migrations")
  defp import_tables, do: ForgeImports.ImportPersistenceMigrationTestSupport.import_tables()
  defp postgres?, do: ForgeImports.ImportPersistenceMigrationTestSupport.postgres?()

  defp start_migration_repo! do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({ImportPersistenceMigrationRepo, config})
    ImportPersistenceMigrationRepo
  end
end
