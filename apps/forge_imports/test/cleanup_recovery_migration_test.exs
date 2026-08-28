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
        "root_identity" => identity(16)
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
        "observed_at" => "not-a-utc-timestamp",
        "root_identity" => identity(16)
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

    for forged <- [
          Map.put(cleanup.evidence, "repository_generation", "1"),
          Map.put(cleanup.evidence, "mode", 0o755),
          Map.put(
            cleanup.evidence,
            "requested_path",
            cleanup.evidence["repository_storage_path"]
          ),
          Map.put(cleanup.evidence, "quarantine_path", cleanup.evidence["requested_path"]),
          Map.put(
            cleanup.evidence,
            "relative_path",
            "other/.fornacast-cleanup-v1-#{String.duplicate("a", 43)}"
          ),
          Map.put(cleanup.evidence, "remote_failure_kind", "Remote Failure"),
          Map.put(cleanup.evidence, "unknown", true)
        ] do
      assert_update_rejected(
        cleanup,
        [evidence: forged],
        "github_import_cleanups_evidence_check"
      )
    end
  end

  test "database accepts every exact kind and rejects replacement authority drift" do
    unpublished_context = cleanup_context("unpublished")
    unpublished_attrs = unpublished_attrs(unpublished_context)

    assert {:ok, %CleanupOperation{kind: :unpublished_shadow}} =
             %CleanupOperation{}
             |> CleanupOperation.create_changeset(unpublished_attrs)
             |> Repo.insert()

    replacement_context = cleanup_context("replacement")

    {:ok, new_repository} =
      ForgeRepos.create_repository(replacement_context.actor, %{
        name: "cleanup-new-#{replacement_context.suffix}",
        slug: "cleanup-new-#{replacement_context.suffix}"
      })

    replacement_attrs = replacement_attrs(replacement_context, new_repository)

    assert {:ok, replacement} =
             %CleanupOperation{}
             |> CleanupOperation.create_changeset(replacement_attrs)
             |> Repo.insert()

    marker = replacement.evidence["publication_marker"]

    corruptions = [
      put_in(marker, ["action"], "create"),
      put_in(marker, ["repository_id"], new_repository.id + 1),
      put_in(marker, ["hidden_repository_id"], new_repository.id + 1),
      put_in(marker, ["replaced_repository_id"], replacement_context.repository.id + 1),
      put_in(marker, ["attempt_number"], 2),
      put_in(
        marker,
        ["operation_id"],
        "github-import-publication-#{replacement_context.item.id}-2"
      ),
      put_in(marker, ["owner_user_id"], replacement_context.actor.id + 1),
      put_in(marker, ["generation"], marker["generation"] + 1)
    ]

    for corrupted_marker <- corruptions do
      assert_update_rejected(
        replacement,
        [evidence: %{replacement.evidence | "publication_marker" => corrupted_marker}],
        "github_import_cleanups_evidence_check"
      )
    end
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
    context = cleanup_context("remote")
    attrs = remote_attrs(context.repository, context.item)
    {:ok, cleanup} = Persistence.create_cleanup_operation(context.item, attrs)
    cleanup
  end

  defp cleanup_context(label) do
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "cleanup-#{label}-#{suffix}",
        email: "cleanup-#{label}-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 9_910_000_000 + suffix,
          login: "cleanup-#{label}-#{suffix}",
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

    %{actor: actor, run: run, item: item, repository: repository, suffix: suffix}
  end

  defp remote_attrs(repository, item) do
    now = ~U[2026-08-28 12:00:00Z]
    storage_root = Fornacast.Config.repo_storage_root()
    requested_path = Path.join(storage_root, repository.storage_path)
    quarantine_path = GitCore.Remote.cleanup_slot_path(requested_path)

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
        "storage_root" => storage_root,
        "relative_path" => Path.relative_to(quarantine_path, storage_root),
        "repository_id" => repository.id,
        "repository_generation" => repository.generation,
        "repository_storage_path" => repository.storage_path,
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "requested_path" => requested_path,
        "quarantine_path" => quarantine_path,
        "mode" => 0o700,
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

  defp unpublished_attrs(context) do
    now = ~U[2026-08-28 12:00:00Z]
    decision = %{"action" => "rename", "slug" => "cleanup-renamed"}
    repository = context.repository
    item = context.item

    cleanup_attrs(
      :unpublished_shadow,
      repository,
      item,
      %{
        "version" => 1,
        "kind" => "unpublished_shadow",
        "storage_root" => Fornacast.Config.repo_storage_root(),
        "relative_path" => repository.storage_path,
        "repository_id" => repository.id,
        "repository_generation" => repository.generation,
        "repository_write_version" => repository.write_version,
        "repository_storage_path" => repository.storage_path,
        "repository_updated_at" => DateTime.to_iso8601(now),
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "item_state" => "failed",
        "run_id" => context.run.id,
        "run_state" => "failed",
        "attempt_number" => 1,
        "attempt_state" => "failed",
        "attempt_decision" => decision,
        "attempt_fingerprint" => CleanupOperation.attempt_fingerprint(item.id, 1, decision),
        "publication_evidence" => %{},
        "predecessor_item_id" => nil,
        "successor_item_id" => nil,
        "adopter_item_id" => nil
      }
    )
  end

  defp replacement_attrs(context, new_repository) do
    now = ~U[2026-08-28 12:00:00Z]
    old = context.repository
    item = context.item

    decision = %{
      "action" => "replace",
      "slug" => new_repository.slug,
      "replacement_repository_id" => old.id,
      "replacement_owner_id" => context.actor.id,
      "replacement_storage_path" => old.storage_path,
      "replacement_generation" => old.generation,
      "replacement_write_version" => old.write_version,
      "replacement_updated_at" => DateTime.to_iso8601(now),
      "replacement_last_pushed_at" => nil
    }

    marker = %{
      "version" => 1,
      "state" => "committed",
      "attempt_number" => 1,
      "action" => "replace",
      "hidden_repository_id" => new_repository.id,
      "operation_id" => "github-import-publication-#{item.id}-1",
      "request_metadata" => %{},
      "repository_id" => new_repository.id,
      "owner_user_id" => context.actor.id,
      "slug" => new_repository.slug,
      "generation" => old.generation + 1,
      "replaced_repository_id" => old.id,
      "run_id" => context.run.id,
      "published_count_after" => 1,
      "run_lock_version_after" => 2
    }

    cleanup_attrs(
      :replacement_tombstone,
      old,
      item,
      %{
        "version" => 1,
        "kind" => "replacement_tombstone",
        "storage_root" => Fornacast.Config.repo_storage_root(),
        "relative_path" => old.storage_path,
        "repository_id" => old.id,
        "repository_generation" => old.generation,
        "repository_write_version" => old.write_version,
        "repository_storage_path" => old.storage_path,
        "repository_deleted_at" => DateTime.to_iso8601(now),
        "repository_updated_at" => DateTime.to_iso8601(now),
        "item_id" => item.id,
        "item_lock_version" => item.lock_version,
        "attempt_number" => 1,
        "attempt_decision" => decision,
        "attempt_fingerprint" => CleanupOperation.attempt_fingerprint(item.id, 1, decision),
        "publication_operation_id" => marker["operation_id"],
        "publication_marker" => marker,
        "new_repository_id" => new_repository.id,
        "new_repository_generation" => old.generation + 1,
        "publication_audit_id" => 1
      }
    )
  end

  defp cleanup_attrs(kind, repository, item, evidence) do
    now = ~U[2026-08-28 12:00:00Z]

    %{
      repository_id: repository.id,
      repository_item_id: item.id,
      source_lock_version: item.lock_version,
      kind: kind,
      operation_id:
        CleanupOperation.deterministic_operation_id(
          kind,
          repository.id,
          item.id,
          item.lock_version
        ),
      evidence: evidence,
      eligible_at: now,
      next_attempt_at: now
    }
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
