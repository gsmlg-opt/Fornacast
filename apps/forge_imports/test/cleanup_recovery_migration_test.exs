defmodule ForgeImports.CleanupRecoveryMigrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeImports.{CleanupOperation, Persistence}
  alias Fornacast.Repo

  @moduletag :persistence

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    :ok
  end

  test "cleanup recovery migration installs the journal and recovery indexes" do
    assert %{rows: [["github_import_repository_cleanups"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               table_lookup_sql(),
               ["github_import_repository_cleanups"]
             )

    index_names =
      Ecto.Adapters.SQL.query!(Repo, index_lookup_sql(), ["github_import_repository_cleanups"]).rows
      |> List.flatten()

    assert "github_import_repository_cleanups_operation_id_index" in index_names
    assert "github_import_cleanups_item_kind_version_index" in index_names
    assert "github_import_repository_cleanups_recovery_index" in index_names
  end

  test "cleanup indexes retain exact uniqueness and recovery order" do
    indexes = index_definitions("github_import_repository_cleanups")

    assert unique_index?(indexes, "github_import_repository_cleanups_operation_id_index")
    assert unique_index?(indexes, "github_import_cleanups_item_kind_version_index")

    assert index_columns(indexes, "github_import_repository_cleanups_recovery_index") ==
             ~w(state next_attempt_at eligible_at id)
  end

  test "database rejects incoherent lifecycle leases timestamps and anchor evidence" do
    cleanup = cleanup_fixture()
    later = DateTime.add(cleanup.eligible_at, 30, :second)

    assert_update_rejected(
      cleanup,
      [lease_owner: "worker"],
      "github_import_cleanups_lease_pair_check"
    )

    assert_update_rejected(
      cleanup,
      [next_attempt_at: nil],
      "github_import_cleanups_lifecycle_check"
    )

    assert_update_rejected(
      cleanup,
      [effect_finished_at: later],
      "github_import_cleanups_effect_order_check"
    )

    assert_update_rejected(
      cleanup,
      [state: :cleanup_blocked, next_attempt_at: nil],
      "github_import_cleanups_lifecycle_check"
    )

    partial = Map.put(cleanup.evidence, "root_identity", identity(16))

    assert_update_rejected(
      cleanup,
      [evidence: partial, effect_started_at: cleanup.eligible_at],
      "github_import_cleanups_evidence_check"
    )

    both =
      cleanup.evidence
      |> Map.put("root_identity", identity(16))
      |> Map.put("anchored_identity", identity(32))
      |> Map.put("anchored_absence", %{
        "version" => 1,
        "observed_at" => DateTime.to_iso8601(cleanup.eligible_at),
        "root_identity" => identity(16),
        "root_projection" => String.duplicate("a", 64),
        "path_projection" => String.duplicate("b", 64)
      })

    assert_update_rejected(
      cleanup,
      [evidence: both, effect_started_at: cleanup.eligible_at, effect_finished_at: later],
      "github_import_cleanups_evidence_check"
    )

    malformed_absence =
      cleanup.evidence
      |> Map.put("anchored_absence", %{
        "version" => 1,
        "observed_at" => DateTime.to_iso8601(cleanup.eligible_at),
        "root_identity" => identity(16),
        "root_projection" => String.duplicate("A", 64),
        "path_projection" => String.duplicate("b", 64)
      })

    assert_update_rejected(
      cleanup,
      [
        evidence: malformed_absence,
        effect_started_at: cleanup.eligible_at,
        effect_finished_at: later
      ],
      "github_import_cleanups_evidence_check"
    )
  end

  defp table_lookup_sql do
    if postgres?(),
      do: "select table_name from information_schema.tables where table_name = $1",
      else: "select name from sqlite_schema where type = 'table' and name = ?"
  end

  defp index_lookup_sql do
    if postgres?(),
      do: "select indexname from pg_indexes where tablename = $1",
      else: "select name from sqlite_schema where type = 'index' and tbl_name = ?"
  end

  defp cleanup_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "cleanup-migration-#{suffix}",
        email: "cleanup-migration-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_910_000_000 + suffix,
          login: "cleanup-migration-#{suffix}",
          avatar_url: nil,
          profile_url: nil
        },
        ~U[2026-08-28 12:00:00Z]
      )

    {:ok, identity} = ForgeAccounts.link_github_identity(actor, identity)

    {:ok, run} =
      ForgeImports.create_run(actor, %{
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: identity.github_user_id,
        source_owner_login: identity.login,
        request_metadata: %{}
      })

    {:ok, item} =
      ForgeImports.create_repository_item(actor, run, %{
        github_repository_id: 9_920_000_000 + suffix,
        source_full_name: "acme/cleanup-#{suffix}",
        source_name: "cleanup-#{suffix}",
        source_metadata: %{},
        source_observed_at: ~U[2026-08-28 12:00:00Z]
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{
        name: "cleanup-#{suffix}",
        slug: "cleanup-#{suffix}"
      })

    attrs = remote_attrs(repository, item)
    {:ok, cleanup} = Persistence.create_cleanup_operation(item, attrs)
    cleanup
  end

  defp remote_attrs(repository, item) do
    now = ~U[2026-08-28 12:00:00Z]

    %{
      repository_id: repository.id,
      repository_item_id: item.id,
      source_lock_version: item.lock_version,
      kind: :remote_quarantine,
      operation_id:
        CleanupOperation.deterministic_operation_id(
          :remote_quarantine,
          repository.id,
          item.id,
          item.lock_version
        ),
      evidence: %{
        "version" => 1,
        "kind" => "remote_quarantine",
        "repository_id" => repository.id,
        "repository_generation" => repository.generation,
        "repository_storage_path" => repository.storage_path,
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "requested_path" => repository.storage_path,
        "quarantine_path" => "quarantine/#{repository.id}-#{item.id}.git",
        "mode" => 16_384,
        "major_device" => 8,
        "minor_device" => 1,
        "inode" => 99,
        "remote_failure_kind" => "remote_clone_failed"
      },
      eligible_at: now,
      next_attempt_at: now
    }
  end

  defp identity(inode) do
    %{"mode" => 16_384, "major_device" => 8, "minor_device" => 1, "inode" => inode}
  end

  defp assert_update_rejected(cleanup, updates, constraint) do
    assert {:error, {:constraint, error}} =
             Repo.transaction(
               fn ->
                 try do
                   Repo.update_all(
                     from(candidate in CleanupOperation, where: candidate.id == ^cleanup.id),
                     set: updates
                   )

                   Repo.rollback(:unexpected_success)
                 rescue
                   error -> Repo.rollback({:constraint, error})
                 end
               end,
               mode: :savepoint
             )

    assert Exception.message(error) =~ constraint
  end

  defp index_definitions(table) do
    if postgres?() do
      Ecto.Adapters.SQL.query!(
        Repo,
        "select indexname, indexdef from pg_indexes where tablename = $1",
        [table]
      ).rows
    else
      Ecto.Adapters.SQL.query!(
        Repo,
        "select name, \"unique\" from pragma_index_list(?)",
        [table]
      ).rows
    end
  end

  defp unique_index?(indexes, name) do
    if postgres?(),
      do:
        Enum.any?(indexes, fn [index_name, definition] ->
          index_name == name and definition =~ "UNIQUE"
        end),
      else: [name, 1] in indexes
  end

  defp index_columns(indexes, name) do
    if postgres?() do
      case Enum.find(indexes, fn [index_name, _definition] -> index_name == name end) do
        [_name, definition] ->
          [columns] = Regex.run(~r/\(([^)]+)\)$/, definition, capture: :all_but_first)
          columns |> String.split(",") |> Enum.map(&String.trim/1)

        nil ->
          []
      end
    else
      Ecto.Adapters.SQL.query!(Repo, "select name from pragma_index_info(?) order by seqno", [
        name
      ]).rows
      |> List.flatten()
    end
  end

  defp reset_database! do
    for table <- [
          "github_import_repository_cleanups",
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
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

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
end
