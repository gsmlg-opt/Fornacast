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

  test "database permits provisional discovery IDs but requires verified IDs afterward", %{
    actor: actor,
    identity: identity
  } do
    params = [
      actor.id,
      "repository",
      identity.id,
      "one_time",
      "octocat",
      "octocat/provisional",
      "discovering"
    ]

    assert {:ok, %{num_rows: 1}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_runs " <>
                 "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
                 "source_owner_login, source_repository_full_name, state, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "update github_import_runs set state = 'awaiting_resolution' " <>
                 "where source_repository_full_name = " <> List.last(placeholders(1)),
               ["octocat/provisional"]
             )

    assert Exception.message(error) =~ "github_import_runs_verified_source_check"
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

  test "database defaults upgraded destination status to clean and accepts a classified invalid state",
       %{actor: actor, identity: identity} do
    run_id = insert_default_destination_run!(actor, identity)
    placeholder = List.first(placeholders(1))

    assert %{rows: [["clean", nil]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "select destination_organization_status, " <>
                 "destination_organization_classification from github_import_runs " <>
                 "where id = #{placeholder}",
               [run_id]
             )

    [status, classification, id] = ["invalid", "reserved_namespace", run_id]
    [status_placeholder, classification_placeholder, id_placeholder] = placeholders(3)

    assert {:ok, %{num_rows: 1}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "update github_import_runs set destination_organization_status = " <>
                 "#{status_placeholder}, destination_organization_classification = " <>
                 "#{classification_placeholder} where id = #{id_placeholder}",
               [status, classification, id]
             )
  end

  test "database rejects destination conflicts without a classification", %{
    actor: actor,
    identity: identity
  } do
    run_id = insert_default_destination_run!(actor, identity)
    [status_placeholder, id_placeholder] = placeholders(2)

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "update github_import_runs set destination_organization_status = " <>
                 "#{status_placeholder} where id = #{id_placeholder}",
               ["conflict", run_id]
             )

    assert Exception.message(error) =~ "github_import_runs_destination_status_coherence_check"
  end

  test "database rejects overlong destination classifications", %{
    actor: actor,
    identity: identity
  } do
    run_id = insert_default_destination_run!(actor, identity)
    [status_placeholder, classification_placeholder, id_placeholder] = placeholders(3)

    assert {:error, error} =
             Ecto.Adapters.SQL.query(
               Repo,
               "update github_import_runs set destination_organization_status = " <>
                 "#{status_placeholder}, destination_organization_classification = " <>
                 "#{classification_placeholder} where id = #{id_placeholder}",
               ["invalid", String.duplicate("x", 121), run_id]
             )

    assert Exception.message(error) =~ "github_import_runs_destination_classification_check"
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

  defp insert_default_destination_run!(actor, identity) do
    params = [
      actor.id,
      "organization",
      identity.id,
      "one_time",
      identity.github_user_id,
      identity.login,
      "discovering"
    ]

    assert {:ok, %{num_rows: 1}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "insert into github_import_runs " <>
                 "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
                 "source_owner_github_id, source_owner_login, state, inserted_at, updated_at) " <>
                 "values (#{Enum.join(placeholders(length(params)), ", ")}, " <>
                 "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
               params
             )

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select id from github_import_runs order by id desc limit 1",
        []
      )

    id
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

  @dual_failure_diagnostic "PostgreSQL migration restore failed after test body failure; preserving original failure"

  def import_tables, do: @import_tables

  def postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  def with_restore(body, restore) when is_function(body, 0) and is_function(restore, 0) do
    body_outcome = capture_outcome(body)
    restore_outcome = capture_outcome(restore)

    case {body_outcome, restore_outcome} do
      {{:ok, result}, {:ok, _restore_result}} ->
        result

      {{:error, kind, reason, stacktrace}, {:ok, _restore_result}} ->
        :erlang.raise(kind, reason, stacktrace)

      {{:ok, _result}, {:error, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {{:error, kind, reason, stacktrace},
       {:error, _restore_kind, _restore_reason, _restore_stack}} ->
        IO.puts(:stderr, @dual_failure_diagnostic)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  def dual_failure_diagnostic, do: @dual_failure_diagnostic

  def foreign_key_states(repo, count) do
    parent = self()

    tasks =
      for _index <- 1..count do
        Task.async(fn ->
          repo.checkout(
            fn ->
              send(parent, {:foreign_key_connection_ready, self()})

              receive do
                :read_foreign_key_state ->
                  %{rows: [[state]]} =
                    Ecto.Adapters.SQL.query!(repo, "PRAGMA foreign_keys", [], log: false)

                  state
              end
            end,
            timeout: :infinity
          )
        end)
      end

    ready =
      for _index <- 1..count do
        receive do
          {:foreign_key_connection_ready, pid} -> pid
        after
          5_000 -> raise "timed out waiting for a migration connection"
        end
      end

    Enum.each(ready, &send(&1, :read_foreign_key_state))
    Task.await_many(tasks, 5_000)
  end

  defp capture_outcome(fun) do
    try do
      {:ok, fun.()}
    catch
      kind, reason -> {:error, kind, reason, __STACKTRACE__}
    end
  end
end

defmodule ForgeImports.ImportPersistenceMigrationRepo do
  @moduledoc false

  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)

  use Ecto.Repo,
    otp_app: :fornacast,
    adapter: @adapter
end

defmodule ForgeImports.ImportPersistenceProvisionalSourceMigrationCycleTest do
  use ExUnit.Case, async: false

  alias ForgeImports.ImportPersistenceMigrationRepo
  alias Fornacast.Repo

  @moduletag :persistence
  @pre_provisional_version 20_260_825_000_350
  @provisional_version 20_260_825_000_360
  @destination_version 20_260_825_000_370
  @repository_lifecycle_version 20_260_825_000_400
  @repository_write_version 20_260_825_000_410
  @staged_path_version 20_260_825_000_420
  @cleanup_recovery_version 20_260_825_000_430
  @external_attribution_version 20_260_825_000_500
  @recovery_constraints_version 20_260_825_000_600
  @cleanup_selector_version 20_260_831_000_100
  @run_scoped_indexes [
    {"github_import_items_run_id_index", "github_import_repository_items"},
    {"github_import_reports_run_id_index", "github_import_report_entries"}
  ]

  test "migration restore reports its failure without masking the original failure" do
    original = RuntimeError.exception("original migration test failure")
    restore = RuntimeError.exception("sensitive restore failure detail")
    original_stacktrace = [{__MODULE__, :original_migration_failure, 0, []}]

    diagnostic =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        result =
          try do
            ForgeImports.ImportPersistenceMigrationTestSupport.with_restore(
              fn -> :erlang.raise(:error, original, original_stacktrace) end,
              fn -> raise restore end
            )
          rescue
            exception -> {exception, __STACKTRACE__}
          end

        assert {^original, ^original_stacktrace} = result
      end)

    assert diagnostic =~
             ForgeImports.ImportPersistenceMigrationTestSupport.dual_failure_diagnostic()

    refute diagnostic =~ restore.message
  end

  @tag :tmp_dir
  test "00360 independently preserves index shape and has an exact lifecycle", context do
    if postgres?() do
      repo = start_migration_repo!()

      with_complete_restore(repo, fn ->
        clear_import_rows!(repo)
        ensure_up!(repo, @provisional_version)
        ensure_up!(repo, @destination_version)
        ensure_up!(repo, @repository_lifecycle_version)
        ensure_up!(repo, @repository_write_version)
        ensure_up!(repo, @staged_path_version)
        ensure_up!(repo, @cleanup_recovery_version)
        ensure_up!(repo, @external_attribution_version)
        ensure_up!(repo, @recovery_constraints_version)
        ensure_up!(repo, @cleanup_selector_version)

        assert [@cleanup_selector_version] = migrate_down(repo, @cleanup_selector_version)
        assert [@recovery_constraints_version] = migrate_down(repo, @recovery_constraints_version)
        assert [@external_attribution_version] = migrate_down(repo, @external_attribution_version)
        assert [@cleanup_recovery_version] = migrate_down(repo, @cleanup_recovery_version)
        assert [@staged_path_version] = migrate_down(repo, @staged_path_version)
        assert [@repository_write_version] = migrate_down(repo, @repository_write_version)

        assert [@repository_lifecycle_version] =
                 migrate_down(repo, @repository_lifecycle_version)

        assert [@destination_version] = migrate_down(repo, @destination_version)
        assert_provisional_schema!(repo)
        assert [@provisional_version] = migrate_down(repo, @provisional_version)
        refute column_exists?(repo, "github_import_runs", "source_metadata")
        refute Enum.any?(@run_scoped_indexes, fn {name, _table} -> index_exists?(repo, name) end)

        seeded = seed_pre_00360_children!(repo)
        assert [@provisional_version] = migrate_up(repo, @provisional_version)
        assert_provisional_schema!(repo)
        assert_seeded_children!(repo, seeded)
        assert [@destination_version] = migrate_up(repo, @destination_version)
        clear_import_rows!(repo)
        delete_seed_accounts!(repo, seeded)

        assert [@repository_lifecycle_version] = migrate_up(repo, @repository_lifecycle_version)
        assert [@repository_write_version] = migrate_up(repo, @repository_write_version)
        assert [@staged_path_version] = migrate_up(repo, @staged_path_version)
        assert [@cleanup_recovery_version] = migrate_up(repo, @cleanup_recovery_version)
        assert [@external_attribution_version] = migrate_up(repo, @external_attribution_version)
        assert [@recovery_constraints_version] = migrate_up(repo, @recovery_constraints_version)
        assert [@cleanup_selector_version] = migrate_up(repo, @cleanup_selector_version)
      end)
    else
      repo = start_scratch_repo!(context.tmp_dir, "provisional")
      assert Enum.member?(migrate_up(repo, @pre_provisional_version), @pre_provisional_version)
      seeded = seed_pre_00360_children!(repo)

      assert [@provisional_version] = migrate_up(repo, @provisional_version)
      assert_provisional_schema!(repo)
      assert_seeded_children!(repo, seeded)

      assert Enum.sort(
               ForgeImports.ImportPersistenceMigrationTestSupport.foreign_key_states(repo, 2)
             ) == [1, 1]

      assert_raise RuntimeError,
                   "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved",
                   fn -> migrate_down(repo, @provisional_version) end

      assert_provisional_schema!(repo)
      assert migration_applied?(repo, @provisional_version)
    end
  end

  defp assert_provisional_schema!(repo) do
    assert column_exists?(repo, "github_import_runs", "source_metadata")

    Enum.each(@run_scoped_indexes, fn {name, table} ->
      assert index_exists?(repo, name)
      assert index_columns(repo, name, table) == ["import_run_id", "id"]
    end)
  end

  defp seed_pre_00360_children!(repo) do
    suffix = System.unique_integer([:positive])
    actor_username = "provisional-actor-#{suffix}"
    actor_id = insert_user!(repo, actor_username, "provisional-#{suffix}@example.test")
    identity_id = insert_identity!(repo, actor_id, suffix)
    run_id = insert_run!(repo, actor_id, identity_id, actor_username, suffix)
    item_id = insert_item!(repo, run_id, suffix)
    report_id = insert_report!(repo, run_id, item_id, suffix)

    %{
      run_id: run_id,
      item_id: item_id,
      report_id: report_id,
      identity_ids: [identity_id],
      user_ids: [actor_id]
    }
  end

  defp insert_user!(repo, username, email) do
    now = database_datetime(DateTime.utc_now(:second))
    params = [username, email, "not-used", "user", "active", "user", now, now]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into users " <>
        "(username, email, password_hash, role, state, kind, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )

    select_id!(repo, "users", "username", username)
  end

  defp insert_identity!(repo, actor_id, suffix) do
    now = database_datetime(DateTime.utc_now(:second))
    github_id = 8_600_000_000 + suffix
    params = ["user", github_id, "provisional-identity-#{suffix}", actor_id, now, now, now, now]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into github_identities " <>
        "(kind, github_user_id, login, local_user_id, last_verified_at, last_observed_at, " <>
        "inserted_at, updated_at) values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )

    select_id!(repo, "github_identities", "github_user_id", github_id)
  end

  defp insert_run!(repo, actor_id, identity_id, actor_username, suffix) do
    now = database_datetime(DateTime.utc_now(:second))
    source_login = "provisional-source-#{suffix}"

    params = [
      actor_id,
      "repository",
      identity_id,
      "one_time",
      8_600_000_000 + suffix,
      source_login,
      9_600_000_000 + suffix,
      "#{source_login}/repository",
      "existing",
      actor_username,
      "awaiting_resolution",
      now,
      now
    ]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into github_import_runs " <>
        "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
        "source_owner_github_id, source_owner_login, source_repository_github_id, " <>
        "source_repository_full_name, destination_organization_action, " <>
        "destination_organization_slug, state, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )

    select_id!(repo, "github_import_runs", "source_owner_login", source_login)
  end

  defp insert_item!(repo, run_id, suffix) do
    now = database_datetime(DateTime.utc_now(:second))
    github_repository_id = 9_700_000_000 + suffix

    params = [
      run_id,
      github_repository_id,
      "github/provisional-#{suffix}",
      "provisional-#{suffix}",
      now,
      "awaiting_resolution",
      now,
      now
    ]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into github_import_repository_items " <>
        "(import_run_id, github_repository_id, source_full_name, source_name, " <>
        "source_observed_at, state, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )

    select_id!(
      repo,
      "github_import_repository_items",
      "github_repository_id",
      github_repository_id
    )
  end

  defp insert_report!(repo, run_id, item_id, suffix) do
    now = database_datetime(DateTime.utc_now(:second))
    idempotency_key = "provisional-report-#{suffix}"

    params = [
      run_id,
      item_id,
      idempotency_key,
      "repository",
      "warning",
      "provisional_warning",
      "Preserve this report during the source migration.",
      1,
      now,
      now
    ]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into github_import_report_entries " <>
        "(import_run_id, repository_item_id, idempotency_key, scope, outcome, " <>
        "classification, summary, source_count, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )

    select_id!(repo, "github_import_report_entries", "idempotency_key", idempotency_key)
  end

  defp assert_seeded_children!(repo, seeded) do
    assert row_exists?(repo, "github_import_runs", seeded.run_id)
    assert row_exists?(repo, "github_import_repository_items", seeded.item_id)
    assert row_exists?(repo, "github_import_report_entries", seeded.report_id)
  end

  defp row_exists?(repo, table, id) do
    placeholder = List.first(placeholders(1))

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "select id from #{table} where id = #{placeholder}", [id])

    rows == [[id]]
  end

  defp select_id!(repo, table, field, value) do
    placeholder = List.first(placeholders(1))

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select id from #{table} where #{field} = #{placeholder}",
        [value]
      )

    id
  end

  defp delete_seed_accounts!(repo, seeded) do
    delete_ids!(repo, "github_identities", seeded.identity_ids)
    delete_ids!(repo, "users", seeded.user_ids)
  end

  defp delete_ids!(_repo, _table, []), do: :ok

  defp delete_ids!(repo, table, ids) do
    Ecto.Adapters.SQL.query!(
      repo,
      "delete from #{table} where id in (#{Enum.join(placeholders(length(ids)), ", ")})",
      ids
    )

    :ok
  end

  defp placeholders(count) do
    if postgres?(), do: Enum.map(1..count, &"$#{&1}"), else: List.duplicate("?", count)
  end

  defp database_datetime(%DateTime{} = value) do
    naive = DateTime.to_naive(value)
    if postgres?(), do: naive, else: NaiveDateTime.to_iso8601(naive)
  end

  defp ensure_up!(repo, version) do
    if migration_applied?(repo, version), do: [], else: migrate_up(repo, version)
  end

  defp with_complete_restore(repo, body) do
    ForgeImports.ImportPersistenceMigrationTestSupport.with_restore(body, fn ->
      ensure_up!(repo, @provisional_version)
      ensure_up!(repo, @destination_version)
      ensure_up!(repo, @repository_lifecycle_version)
      ensure_up!(repo, @repository_write_version)
      ensure_up!(repo, @staged_path_version)
      ensure_up!(repo, @cleanup_recovery_version)
      ensure_up!(repo, @external_attribution_version)
      ensure_up!(repo, @recovery_constraints_version)
      ensure_up!(repo, @cleanup_selector_version)
    end)
  end

  defp migrate_down(repo, version),
    do: Ecto.Migrator.run(repo, migrations_path(), :down, to: version, log: false)

  defp migrate_up(repo, version),
    do: Ecto.Migrator.run(repo, migrations_path(), :up, to: version, log: false)

  defp clear_import_rows!(repo) do
    Enum.each(import_tables(), fn table ->
      Ecto.Adapters.SQL.query!(repo, "delete from #{table}", [])
    end)
  end

  defp migration_applied?(repo, version) do
    placeholder = if postgres?(), do: "$1", else: "?"

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select version from schema_migrations where version = #{placeholder}",
        [version]
      )

    rows == [[version]]
  end

  defp column_exists?(repo, table, column) do
    if postgres?() do
      %{rows: [[exists?]]} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select exists (select 1 from information_schema.columns " <>
            "where table_schema = current_schema() and table_name = $1 and column_name = $2)",
          [table, column]
        )

      exists?
    else
      %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "pragma table_info('#{table}')", [])
      Enum.any?(rows, &(Enum.at(&1, 1) == column))
    end
  end

  defp index_exists?(repo, name) do
    if postgres?() do
      %{rows: [[exists?]]} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select exists (select 1 from pg_indexes " <>
            "where schemaname = current_schema() and indexname = $1)",
          [name]
        )

      exists?
    else
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select name from sqlite_schema where type = 'index' and name = ?",
          [name]
        )

      rows == [[name]]
    end
  end

  defp index_columns(repo, name, table) do
    if postgres?() do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select a.attname " <>
            "from pg_class i " <>
            "join pg_index ix on i.oid = ix.indexrelid " <>
            "join pg_class t on t.oid = ix.indrelid " <>
            "join unnest(ix.indkey) with ordinality as keys(attnum, ord) on true " <>
            "join pg_attribute a on a.attrelid = t.oid and a.attnum = keys.attnum " <>
            "where i.relname = $1 and t.relname = $2 order by keys.ord",
          [name, table]
        )

      Enum.map(rows, &List.first/1)
    else
      %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "pragma index_info('#{name}')", [])
      Enum.map(rows, &Enum.at(&1, 2))
    end
  end

  defp start_scratch_repo!(tmp_dir, suffix) do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:database, Path.join(tmp_dir, "#{suffix}.db"))
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({ImportPersistenceMigrationRepo, config})
    ImportPersistenceMigrationRepo
  end

  defp start_migration_repo! do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({ImportPersistenceMigrationRepo, config})
    ImportPersistenceMigrationRepo
  end

  defp migrations_path, do: Application.app_dir(:fornacast, "priv/repo/migrations")
  defp import_tables, do: ForgeImports.ImportPersistenceMigrationTestSupport.import_tables()
  defp postgres?, do: ForgeImports.ImportPersistenceMigrationTestSupport.postgres?()
end

defmodule ForgeImports.ImportPersistenceDestinationStatusMigrationCycleTest do
  use ExUnit.Case, async: false

  alias ForgeImports.ImportPersistenceMigrationRepo
  alias Fornacast.Repo

  @moduletag :persistence
  @version 20_260_825_000_370
  @repository_lifecycle_version 20_260_825_000_400
  @repository_write_version 20_260_825_000_410
  @staged_path_version 20_260_825_000_420
  @cleanup_recovery_version 20_260_825_000_430
  @external_attribution_version 20_260_825_000_500
  @recovery_constraints_version 20_260_825_000_600
  @cleanup_selector_version 20_260_831_000_100
  @migration_file Path.expand(
                    "../../fornacast/priv/repo/migrations/20260825000370_add_github_import_destination_status.exs",
                    __DIR__
                  )

  test "00370 backfills provisional columns before finalizing their contract" do
    source = File.read!(@migration_file)

    assert source =~
             "add_provisional_columns()\n    flush()\n    backfill_destination_statuses()\n    finalize_columns()"
  end

  test "forward migration installs destination status fields and checks" do
    repo = start_migration_repo!()

    assert_destination_projection!(repo)
  end

  test "destination-status rollback is pre-DDL guarded on Turso and reversible on PostgreSQL" do
    repo = start_migration_repo!()

    if postgres?() do
      with_complete_restore(repo, fn ->
        clear_import_rows!(repo)
        assert migration_applied?(repo)
        assert Enum.all?(import_tables(), &table_exists?(repo, &1))
        ensure_latest_migrations_up!(repo)
        assert [@cleanup_selector_version] = migrate_down(repo, @cleanup_selector_version)
        assert [@recovery_constraints_version] = migrate_down(repo, @recovery_constraints_version)
        assert [@external_attribution_version] = migrate_down(repo, @external_attribution_version)
        assert [@cleanup_recovery_version] = migrate_down(repo, @cleanup_recovery_version)
        assert [@staged_path_version] = migrate_down(repo, @staged_path_version)
        assert [@repository_write_version] = migrate_down(repo, @repository_write_version)

        assert [@repository_lifecycle_version] =
                 migrate_down(repo, @repository_lifecycle_version)

        assert [@version] = migrate_down(repo, @version)

        refute migration_applied?(repo)
        assert Enum.all?(import_tables(), &table_exists?(repo, &1))
        assert column_exists?(repo, "github_import_runs", "source_metadata")
        refute column_exists?(repo, "github_import_runs", "destination_organization_status")

        refute column_exists?(
                 repo,
                 "github_import_runs",
                 "destination_organization_classification"
               )

        assert [@version] = migrate_up(repo, @version)
        assert [@repository_lifecycle_version] = migrate_up(repo, @repository_lifecycle_version)
        assert [@repository_write_version] = migrate_up(repo, @repository_write_version)
        assert [@staged_path_version] = migrate_up(repo, @staged_path_version)
        assert [@cleanup_recovery_version] = migrate_up(repo, @cleanup_recovery_version)
        assert [@external_attribution_version] = migrate_up(repo, @external_attribution_version)
        assert [@recovery_constraints_version] = migrate_up(repo, @recovery_constraints_version)
        assert [@cleanup_selector_version] = migrate_up(repo, @cleanup_selector_version)

        assert migration_applied?(repo)
        assert Enum.all?(import_tables(), &table_exists?(repo, &1))
        assert column_exists?(repo, "github_import_runs", "source_metadata")
        assert_destination_projection!(repo)
      end)
    else
      clear_import_rows!(repo)
      assert migration_applied?(repo)
      assert Enum.all?(import_tables(), &table_exists?(repo, &1))

      assert_raise RuntimeError,
                   "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved",
                   fn ->
                     Ecto.Migrator.run(repo, migrations_path(), :down,
                       to: @version,
                       log: false
                     )
                   end

      assert migration_applied?(repo)
      assert Enum.all?(import_tables(), &table_exists?(repo, &1))
      assert_destination_projection!(repo)
    end
  end

  @tag :tmp_dir
  test "00370 backfills every pre-existing destination shape before installing coherence",
       context do
    if postgres?() do
      repo = start_migration_repo!()

      with_complete_restore(repo, fn ->
        clear_import_rows!(repo)
        ensure_latest_migrations_up!(repo)
        assert [@cleanup_selector_version] = migrate_down(repo, @cleanup_selector_version)
        assert [@recovery_constraints_version] = migrate_down(repo, @recovery_constraints_version)
        assert [@external_attribution_version] = migrate_down(repo, @external_attribution_version)
        assert [@cleanup_recovery_version] = migrate_down(repo, @cleanup_recovery_version)
        assert [@staged_path_version] = migrate_down(repo, @staged_path_version)
        assert [@repository_write_version] = migrate_down(repo, @repository_write_version)

        assert [@repository_lifecycle_version] =
                 migrate_down(repo, @repository_lifecycle_version)

        assert [@version] = migrate_down(repo, @version)
        assert_destination_backfill!(repo)
        assert [@repository_lifecycle_version] = migrate_up(repo, @repository_lifecycle_version)
        assert [@repository_write_version] = migrate_up(repo, @repository_write_version)
        assert [@staged_path_version] = migrate_up(repo, @staged_path_version)
        assert [@cleanup_recovery_version] = migrate_up(repo, @cleanup_recovery_version)
        assert [@external_attribution_version] = migrate_up(repo, @external_attribution_version)
        assert [@recovery_constraints_version] = migrate_up(repo, @recovery_constraints_version)
        assert [@cleanup_selector_version] = migrate_up(repo, @cleanup_selector_version)
      end)
    else
      repo = start_scratch_repo!(context.tmp_dir, "destination-upgrade")
      assert Enum.member?(migrate_up(repo, 20_260_825_000_360), 20_260_825_000_360)
      assert_destination_backfill!(repo)
    end
  end

  defp assert_destination_backfill!(repo) do
    refute column_exists?(repo, "github_import_runs", "destination_organization_status")
    seeded = seed_pre_00370_runs!(repo)

    assert [@version] = migrate_up(repo, @version)

    expected = %{
      repository_personal: {"clean", nil},
      organization_existing: {"clean", nil},
      organization_reserved: {"invalid", "reserved_namespace"},
      organization_taken: {"conflict", "namespace_conflict"},
      organization_invalid: {"invalid", "invalid_namespace"},
      organization_evidence: {"invalid", "reserved_namespace"},
      organization_clean: {"clean", nil}
    }

    Enum.each(expected, fn {key, expectation} ->
      assert destination_projection(repo, Map.fetch!(seeded.runs, key)) == expectation
    end)

    assert_destination_projection!(repo)

    unless postgres?() do
      assert repository_item_count(repo, seeded.runs.organization_evidence) == 1

      assert Enum.sort(
               ForgeImports.ImportPersistenceMigrationTestSupport.foreign_key_states(repo, 2)
             ) == [1, 1]
    end

    if postgres?() do
      clear_import_rows!(repo)
      delete_seed_accounts!(repo, seeded)
    end
  end

  defp assert_destination_projection!(repo) do
    assert column_exists?(repo, "github_import_runs", "destination_organization_status")
    assert finalized_status_column?(repo)

    assert column_exists?(
             repo,
             "github_import_runs",
             "destination_organization_classification"
           )

    for constraint <- [
          "github_import_runs_destination_status_check",
          "github_import_runs_destination_classification_check",
          "github_import_runs_destination_status_coherence_check"
        ] do
      assert constraint_exists?(repo, constraint)
    end
  end

  defp finalized_status_column?(repo) do
    if postgres?() do
      %{rows: [[nullable, default]]} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select is_nullable, column_default from information_schema.columns " <>
            "where table_schema = current_schema() and table_name = $1 and column_name = $2",
          ["github_import_runs", "destination_organization_status"]
        )

      nullable == "NO" and is_binary(default) and String.contains?(default, "clean")
    else
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(repo, "pragma table_info('github_import_runs')", [])

      case Enum.find(rows, &(Enum.at(&1, 1) == "destination_organization_status")) do
        row when is_list(row) ->
          Enum.at(row, 3) == 1 and is_binary(Enum.at(row, 4)) and
            String.contains?(Enum.at(row, 4), "clean")

        _missing ->
          false
      end
    end
  end

  defp seed_pre_00370_runs!(repo) do
    suffix = System.unique_integer([:positive])
    actor_username = "backfill-actor-#{suffix}"
    taken_username = "backfill-taken-#{suffix}"
    actor_id = insert_user!(repo, actor_username, "actor-#{suffix}@example.test", "user")
    taken_id = insert_user!(repo, taken_username, "taken-#{suffix}@example.test", "organization")
    identity_id = insert_identity!(repo, actor_id, suffix)

    runs = %{
      repository_personal:
        insert_pre_00370_run!(repo, actor_id, identity_id,
          label: "repository-personal-#{suffix}",
          source_kind: "repository",
          repository_id: 91_000 + suffix,
          repository_full_name: "octocat/repository-#{suffix}",
          destination_action: "existing",
          destination_slug: actor_username,
          destination_id: nil
        ),
      organization_existing:
        insert_pre_00370_run!(repo, actor_id, identity_id,
          label: "organization-existing-#{suffix}",
          destination_action: "existing",
          destination_slug: taken_username,
          destination_id: taken_id
        ),
      organization_reserved:
        insert_pre_00370_run!(repo, actor_id, identity_id,
          label: "organization-reserved-#{suffix}",
          destination_action: "new",
          destination_slug: "imports"
        ),
      organization_taken:
        insert_pre_00370_run!(repo, actor_id, identity_id,
          label: "organization-taken-#{suffix}",
          destination_action: "new",
          destination_slug: taken_username
        ),
      organization_invalid:
        insert_pre_00370_run!(repo, actor_id, identity_id,
          label: "organization-invalid-#{suffix}",
          destination_action: "new",
          destination_slug: "Bad!"
        ),
      organization_evidence:
        insert_pre_00370_run!(repo, actor_id, identity_id,
          label: "organization-evidence-#{suffix}",
          destination_action: "new",
          destination_slug: "evidence-#{suffix}"
        ),
      organization_clean:
        insert_pre_00370_run!(repo, actor_id, identity_id,
          label: "organization-clean-#{suffix}",
          destination_action: "new",
          destination_slug: "clean-#{suffix}"
        )
    }

    insert_wait_reason_evidence!(repo, runs.organization_evidence, actor_id, suffix)

    %{runs: runs, identity_id: identity_id, user_ids: [actor_id, taken_id]}
  end

  defp insert_user!(repo, username, email, kind) do
    now = database_datetime(DateTime.utc_now(:second))
    params = [username, email, "not-used", "user", "active", kind, now, now]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into users " <>
        "(username, email, password_hash, role, state, kind, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )

    select_id!(repo, "users", "username", username)
  end

  defp insert_identity!(repo, actor_id, suffix) do
    now = database_datetime(DateTime.utc_now(:second))
    github_id = 8_700_000_000 + suffix
    login = "backfill-identity-#{suffix}"
    params = ["user", github_id, login, actor_id, now, now, now, now]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into github_identities " <>
        "(kind, github_user_id, login, local_user_id, last_verified_at, last_observed_at, " <>
        "inserted_at, updated_at) values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )

    select_id!(repo, "github_identities", "github_user_id", github_id)
  end

  defp insert_pre_00370_run!(repo, actor_id, identity_id, opts) do
    now = database_datetime(DateTime.utc_now(:second))
    label = Keyword.fetch!(opts, :label)
    source_kind = Keyword.get(opts, :source_kind, "organization")

    params = [
      actor_id,
      source_kind,
      identity_id,
      "one_time",
      8_800_000_000 + System.unique_integer([:positive]),
      label,
      Keyword.get(opts, :repository_id),
      Keyword.get(opts, :repository_full_name),
      Keyword.get(opts, :destination_action),
      Keyword.get(opts, :destination_slug),
      Keyword.get(opts, :destination_id),
      "awaiting_resolution",
      now,
      now
    ]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into github_import_runs " <>
        "(actor_user_id, source_kind, github_identity_id, credential_source, " <>
        "source_owner_github_id, source_owner_login, source_repository_github_id, " <>
        "source_repository_full_name, destination_organization_action, " <>
        "destination_organization_slug, destination_organization_id, state, inserted_at, updated_at) " <>
        "values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )

    select_id!(repo, "github_import_runs", "source_owner_login", label)
  end

  defp insert_wait_reason_evidence!(repo, run_id, actor_id, suffix) do
    now = database_datetime(DateTime.utc_now(:second))

    params = [
      run_id,
      9_800_000_000 + suffix,
      "github/evidence-#{suffix}",
      "evidence-#{suffix}",
      now,
      actor_id,
      "evidence-#{suffix}",
      "private",
      "awaiting_resolution",
      "reserved_namespace",
      now,
      now
    ]

    Ecto.Adapters.SQL.query!(
      repo,
      "insert into github_import_repository_items " <>
        "(import_run_id, github_repository_id, source_full_name, source_name, source_observed_at, " <>
        "destination_owner_id, destination_slug, destination_visibility, state, wait_reason, " <>
        "inserted_at, updated_at) values (#{Enum.join(placeholders(length(params)), ", ")})",
      params
    )
  end

  defp destination_projection(repo, run_id) do
    placeholder = List.first(placeholders(1))

    %{rows: [[status, classification]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select destination_organization_status, destination_organization_classification " <>
          "from github_import_runs where id = #{placeholder}",
        [run_id]
      )

    {status, classification}
  end

  defp repository_item_count(repo, run_id) do
    placeholder = List.first(placeholders(1))

    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select count(*) from github_import_repository_items " <>
          "where import_run_id = #{placeholder}",
        [run_id]
      )

    count
  end

  defp select_id!(repo, table, field, value) do
    placeholder = List.first(placeholders(1))

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select id from #{table} where #{field} = #{placeholder}",
        [value]
      )

    id
  end

  defp delete_seed_accounts!(repo, seeded) do
    clear_import_rows!(repo)
    delete_ids!(repo, "github_identities", [seeded.identity_id])
    delete_ids!(repo, "users", seeded.user_ids)
  end

  defp delete_ids!(_repo, _table, []), do: :ok

  defp delete_ids!(repo, table, ids) do
    Ecto.Adapters.SQL.query!(
      repo,
      "delete from #{table} where id in (#{Enum.join(placeholders(length(ids)), ", ")})",
      ids
    )

    :ok
  end

  defp placeholders(count) do
    if postgres?(), do: Enum.map(1..count, &"$#{&1}"), else: List.duplicate("?", count)
  end

  defp database_datetime(%DateTime{} = value) do
    naive = DateTime.to_naive(value)
    if postgres?(), do: naive, else: NaiveDateTime.to_iso8601(naive)
  end

  defp migrate_down(repo, version),
    do: Ecto.Migrator.run(repo, migrations_path(), :down, to: version, log: false)

  defp migrate_up(repo, version),
    do: Ecto.Migrator.run(repo, migrations_path(), :up, to: version, log: false)

  defp clear_import_rows!(repo) do
    Enum.each(import_tables(), fn table ->
      Ecto.Adapters.SQL.query!(repo, "delete from #{table}", [])
    end)
  end

  defp migration_applied?(repo, version \\ @version) do
    placeholder = if postgres?(), do: "$1", else: "?"

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "select version from schema_migrations where version = #{placeholder}",
        [version]
      )

    rows == [[version]]
  end

  defp ensure_up!(repo, version) do
    unless migration_applied?(repo, version) do
      Ecto.Migrator.run(repo, migrations_path(), :up, to: version, log: false)
    end
  end

  defp ensure_latest_migrations_up!(repo) do
    ensure_up!(repo, @version)
    ensure_up!(repo, @repository_lifecycle_version)
    ensure_up!(repo, @repository_write_version)
    ensure_up!(repo, @staged_path_version)
    ensure_up!(repo, @cleanup_recovery_version)
    ensure_up!(repo, @external_attribution_version)
    ensure_up!(repo, @recovery_constraints_version)
    ensure_up!(repo, @cleanup_selector_version)
  end

  defp with_complete_restore(repo, body) do
    ForgeImports.ImportPersistenceMigrationTestSupport.with_restore(body, fn ->
      ensure_latest_migrations_up!(repo)
    end)
  end

  defp column_exists?(repo, table, column) do
    if postgres?() do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select 1 from information_schema.columns " <>
            "where table_schema = current_schema() and table_name = $1 and column_name = $2",
          [table, column]
        )

      rows != []
    else
      %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "pragma table_info('#{table}')", [])
      Enum.any?(rows, &(Enum.at(&1, 1) == column))
    end
  end

  defp constraint_exists?(repo, name) do
    if postgres?() do
      %{rows: [[exists?]]} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select exists (select 1 from pg_constraint where conname = $1)",
          [name]
        )

      exists?
    else
      %{rows: [[sql]]} =
        Ecto.Adapters.SQL.query!(
          repo,
          "select sql from sqlite_schema where type = 'table' and name = ?",
          ["github_import_runs"]
        )

      String.contains?(sql, name)
    end
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

  defp start_scratch_repo!(tmp_dir, suffix) do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:database, Path.join(tmp_dir, "#{suffix}.db"))
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({ImportPersistenceMigrationRepo, config})
    ImportPersistenceMigrationRepo
  end
end
