defmodule ForgeImports.CleanupRecoveryMigrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeImports.{
    CleanupOperation,
    ImportAttempt,
    ImportRun,
    Persistence,
    RepositoryCleanup,
    RepositoryItem
  }

  alias ForgeRepos.Repository
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

    item_indexes =
      Ecto.Adapters.SQL.query!(Repo, index_lookup_sql(), ["github_import_repository_items"]).rows
      |> List.flatten()

    assert "github_import_items_cleanup_due_index" in item_indexes
    assert "github_import_items_replacement_cleanup_index" in item_indexes
    assert "github_import_items_unpublished_cleanup_index" in item_indexes
  end

  test "cleanup indexes retain exact uniqueness and recovery order" do
    indexes = index_definitions("github_import_repository_cleanups")

    assert unique_index?(indexes, "github_import_repository_cleanups_operation_id_index")
    assert unique_index?(indexes, "github_import_cleanups_item_kind_version_index")

    assert index_columns(indexes, "github_import_repository_cleanups_recovery_index") ==
             ~w(kind state next_attempt_at eligible_at id)

    item_indexes = index_definitions("github_import_repository_items")

    assert index_columns(item_indexes, "github_import_items_cleanup_due_index") ==
             ~w(cleanup_state cleanup_eligible_at id)

    assert index_columns(item_indexes, "github_import_items_replacement_cleanup_index") ==
             ~w(replacement_repository_id id)

    unpublished_definition =
      index_definition(item_indexes, "github_import_items_unpublished_cleanup_index")

    assert unpublished_definition =~ "COALESCE(cleanup_eligible_at, updated_at)"
    assert unpublished_definition =~ "(state)::text = ANY"
    assert unpublished_definition =~ "publication_evidence = '{}'::jsonb"
    assert unpublished_definition =~ "lease_owner IS NULL"
    assert unpublished_definition =~ "lease_expires_at IS NULL"
  end

  test "PostgreSQL production unpublished selector uses its expression index under a generic plan" do
    if postgres?() do
      now = DateTime.utc_now(:second)
      {selector_sql, selector_params} = capture_unpublished_selector_sql(now)

      refute selector_sql =~ ~r/\(g0\."state" = ANY\(\$\d+\)/

      assert selector_sql =~
               ~r/g0\."state" IN \('completed','skipped','canceled','failed','published'\)/

      assert selector_sql =~ ~s(g0."publication_evidence" = '{}'::jsonb)

      assert [^now, run_states, attempt_states] = selector_params
      assert run_states == ["completed", "completed_with_warnings", "canceled", "failed"]
      assert attempt_states == ["completed", "failed", "canceled", "destination_changed"]

      context = unpublished_selector_context!()
      insert_unpublished_selector_candidates!(context, 10_000)
      Ecto.Adapters.SQL.query!(Repo, "analyze github_import_repository_items", [])
      Ecto.Adapters.SQL.query!(Repo, "set local plan_cache_mode = force_generic_plan", [])
      Ecto.Adapters.SQL.query!(Repo, "set local enable_sort = off", [])

      plan = explain_prepared_sql(selector_sql, selector_params)

      assert plan =~ "github_import_items_unpublished_cleanup_index"
      refute plan =~ "Sort"
    end
  end

  test "PostgreSQL cleanup selectors use their ordered indexes" do
    if postgres?() do
      Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(Repo, "set local enable_seqscan = off", [])

        assert explain_sql("""
               select id, repository_id
               from github_import_repository_cleanups
               where kind = 'remote_quarantine'
                 and state = 'cleanup_pending'
                 and eligible_at <= now()
                 and next_attempt_at <= now()
                 and (lease_expires_at is null or lease_expires_at <= now())
               order by next_attempt_at, eligible_at, id
               limit 1
               """) =~ "github_import_repository_cleanups_recovery_index"

        assert explain_sql("""
               select id, hidden_repository_id
               from github_import_repository_items
               where state = 'staging_git'
                 and cleanup_state = 'cleanup_pending'
                 and cleanup_eligible_at <= now()
                 and hidden_repository_id is not null
               order by cleanup_eligible_at, id
               limit 100
               """) =~ "github_import_items_cleanup_due_index"

        assert explain_sql("""
               select id
               from github_import_repository_items
               where replacement_repository_id = 1
               order by id
               limit 100
               """) =~ "github_import_items_replacement_cleanup_index"
      end)
    end
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

  test "database requires the quarantine reservation to occupy the entire basename" do
    cleanup = cleanup_fixture()
    root = cleanup.evidence["storage_root"]
    leaf = ".fornacast-cleanup-v1-#{String.duplicate("a", 43)}"

    root_evidence =
      remote_paths(cleanup.evidence, root, "repo.git", leaf)

    assert {:ok, cleanup} =
             cleanup
             |> Ecto.Changeset.change(evidence: root_evidence)
             |> Repo.update()

    nested_evidence =
      remote_paths(cleanup.evidence, root, "foo/repo.git", "foo/#{leaf}")

    assert {:ok, cleanup} =
             cleanup
             |> Ecto.Changeset.change(evidence: nested_evidence)
             |> Repo.update()

    malicious =
      remote_paths(cleanup.evidence, root, "foo/xrepo.git", "foo/x#{leaf}")

    assert_update_rejected(
      cleanup,
      [evidence: malicious],
      "github_import_cleanups_evidence_check"
    )
  end

  test "database identity numbers use exact textual integers" do
    cleanup = cleanup_fixture()
    started_at = ~U[2026-08-28 12:00:00Z]

    present =
      cleanup.evidence
      |> Map.put("root_identity", identity(16))
      |> Map.put("anchored_identity", identity(32))

    cleanup =
      cleanup
      |> CleanupOperation.lease_update_changeset(
        evidence: present,
        effect_started_at: started_at
      )
      |> Repo.update!()

    for branch <- ~w(root_identity anchored_identity),
        field <- ~w(mode major_device minor_device inode),
        literal <- ["1.0", "-0.0", "\"1\"", "9223372036854775808"] do
      assert_identity_literal_rejected(cleanup, branch, field, literal)
    end
  end

  test "postgres jsonb normalizes exponent integer notation before validation" do
    if postgres?() do
      cleanup = cleanup_fixture()
      started_at = ~U[2026-08-28 12:00:00Z]

      present =
        cleanup.evidence
        |> Map.put("root_identity", identity(16))
        |> Map.put("anchored_identity", identity(32))

      cleanup =
        cleanup
        |> CleanupOperation.lease_update_changeset(
          evidence: present,
          effect_started_at: started_at
        )
        |> Repo.update!()

      assert {:ok, _result} =
               Ecto.Adapters.SQL.query(
                 Repo,
                 "update github_import_repository_cleanups set evidence = " <>
                   "jsonb_set(evidence, '{root_identity,mode}', '1e0'::jsonb) where id = $1",
                 [cleanup.id]
               )

      assert Repo.reload!(cleanup).evidence["root_identity"]["mode"] == 1
    end
  end

  test "database blocked errors retain only safe classifications" do
    for value <- ["cleanup_timeout", "storage_unavailable"] do
      cleanup = cleanup_fixture()

      assert {:ok, _blocked} =
               cleanup
               |> Ecto.Changeset.change(
                 state: :cleanup_blocked,
                 next_attempt_at: nil,
                 last_error: value
               )
               |> Repo.update()
    end

    invalid = [
      "/srv/private.git",
      "cleanup failed: /srv/private.git",
      "cleanup failed (/srv/private.git)",
      "cleanup failed=/srv/private.git",
      "cleanup failed, /srv/private.git",
      "C:\\private\\repo.git",
      "cleanup failed: C:\\secret",
      "\\\\server\\share",
      "cleanup failed: \\\\private\\repo.git",
      "file:///srv/private.git",
      "Bearer secret-token",
      "github_pat_secret",
      "GHP_SECRET",
      "token",
      "password",
      "access_token",
      "authorization",
      "credential_envelope",
      "line\nbreak",
      String.duplicate("x", 121)
    ]

    for value <- invalid do
      fresh = cleanup_fixture()

      assert_update_rejected(
        fresh,
        [state: :cleanup_blocked, next_attempt_at: nil, last_error: value],
        "github_import_cleanups_lifecycle_check"
      )
    end

    assert_nul_error_rejected(cleanup_fixture())
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

  defp unpublished_selector_context! do
    context = cleanup_context("unpublished-selector")
    now = DateTime.utc_now(:second)

    Repo.update_all(
      from(repository in Repository, where: repository.id == ^context.repository.id),
      set: [
        lifecycle: :importing,
        visibility: :private,
        write_version: 0,
        deleted_at: nil,
        last_pushed_at: nil,
        storage_reclaimed_at: nil
      ]
    )

    Repo.update_all(
      from(run in ImportRun, where: run.id == ^context.run.id),
      set: [
        state: :failed,
        terminal_at: now,
        failure_kind: "selector_fixture",
        lease_owner: nil,
        lease_expires_at: nil
      ]
    )

    Repo.update_all(
      from(item in RepositoryItem, where: item.id == ^context.item.id),
      set: [
        state: :failed,
        hidden_repository_id: context.repository.id,
        attempt_count: 1,
        failure_kind: "selector_fixture",
        publication_evidence: %{},
        cleanup_eligible_at: nil,
        lease_owner: nil,
        lease_expires_at: nil
      ]
    )

    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: context.item.id,
      attempt_number: 1,
      state: :failed,
      decision: %{"action" => "create", "slug" => context.repository.slug},
      started_at: now,
      terminal_at: now,
      failure_kind: "selector_fixture"
    })
    |> Repo.insert!()

    %{
      context
      | item: Repo.get!(RepositoryItem, context.item.id),
        run: Repo.get!(ImportRun, context.run.id)
    }
  end

  defp insert_unpublished_selector_candidates!(context, count) do
    now = DateTime.utc_now(:second)
    base = 9_930_000_000 + context.suffix * 10_000

    repository_rows =
      for index <- 1..count do
        %{
          owner_user_id: context.actor.id,
          slug: "selector-#{context.suffix}-#{index}",
          name: "Selector #{index}",
          visibility: :private,
          storage_path: "selector/#{context.suffix}-#{index}.git",
          default_branch: "main",
          has_issues: true,
          allow_merge_commit: true,
          lifecycle: :importing,
          generation: 1,
          write_version: 0,
          inserted_at: now,
          updated_at: now
        }
      end

    repositories = insert_all_returning_ids!(Repository, repository_rows)
    assert length(repositories) == count

    item_rows =
      repositories
      |> Enum.with_index(1)
      |> Enum.map(fn {%{id: repository_id}, index} ->
        %{
          import_run_id: context.run.id,
          github_repository_id: base + index,
          source_full_name: "noise/selector-#{context.suffix}-#{index}",
          source_name: "selector-#{index}",
          source_metadata: %{},
          source_observed_at: now,
          selected: true,
          hidden_repository_id: repository_id,
          state: :failed,
          lock_version: 1,
          attempt_count: 1,
          failure_kind: "selector_fixture",
          checkpoint: %{},
          source_git: %{},
          publication_evidence: %{},
          imported_count: 0,
          skipped_count: 0,
          warning_count: 0,
          failure_count: 0,
          cleanup_attempt_count: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    items = insert_all_returning_ids!(RepositoryItem, item_rows)
    assert length(items) == count

    attempt_rows =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {%{id: item_id}, index} ->
        %{
          repository_item_id: item_id,
          attempt_number: 1,
          state: :failed,
          decision: %{
            "action" => "create",
            "slug" => "selector-#{context.suffix}-#{index}"
          },
          started_at: now,
          terminal_at: now,
          failure_kind: "selector_fixture",
          inserted_at: now,
          updated_at: now
        }
      end)

    inserted =
      attempt_rows
      |> Enum.chunk_every(1_000)
      |> Enum.reduce(0, fn rows, total ->
        {inserted, nil} = Repo.insert_all(ImportAttempt, rows)
        total + inserted
      end)

    assert inserted == count
    :ok
  end

  defp insert_all_returning_ids!(schema, rows) do
    rows
    |> Enum.chunk_every(1_000)
    |> Enum.flat_map(fn chunk ->
      {inserted, returned} = Repo.insert_all(schema, chunk, returning: [:id])
      assert inserted == length(chunk)
      returned
    end)
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

  defp remote_paths(evidence, root, repository_storage_path, relative_path) do
    evidence
    |> Map.put("repository_storage_path", repository_storage_path)
    |> Map.put("relative_path", relative_path)
    |> Map.put("requested_path", Path.join(root, repository_storage_path))
    |> Map.put("quarantine_path", Path.join(root, relative_path))
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

  defp assert_identity_literal_rejected(cleanup, branch, field, literal) do
    sql =
      if postgres?() do
        "update github_import_repository_cleanups set evidence = " <>
          "jsonb_set(evidence, '{#{branch},#{field}}', '#{literal}'::jsonb) where id = $1"
      else
        "update github_import_repository_cleanups set evidence = " <>
          "json_set(evidence, '$.#{branch}.#{field}', json('#{literal}')) where id = ?"
      end

    assert {:error, {:constraint, error}} =
             Repo.transaction(
               fn ->
                 case Ecto.Adapters.SQL.query(Repo, sql, [cleanup.id]) do
                   {:ok, _result} -> Repo.rollback(:unexpected_success)
                   {:error, error} -> Repo.rollback({:constraint, error})
                 end
               end,
               mode: :savepoint
             )

    assert Exception.message(error) =~ "github_import_cleanups_evidence_check"
  end

  defp assert_nul_error_rejected(cleanup) do
    sql =
      if postgres?() do
        "update github_import_repository_cleanups set state = 'cleanup_blocked', " <>
          "next_attempt_at = null, last_error = chr(0) where id = $1"
      else
        "update github_import_repository_cleanups set state = 'cleanup_blocked', " <>
          "next_attempt_at = null, last_error = char(0) where id = ?"
      end

    assert {:error, {:rejected, error}} =
             Repo.transaction(
               fn ->
                 case Ecto.Adapters.SQL.query(Repo, sql, [cleanup.id]) do
                   {:ok, _result} -> Repo.rollback(:unexpected_success)
                   {:error, error} -> Repo.rollback({:rejected, error})
                 end
               end,
               mode: :savepoint
             )

    message = Exception.message(error)

    if postgres?(),
      do: assert(message =~ "null character" or message =~ "0x00"),
      else: assert(message =~ "github_import_cleanups_lifecycle_check")
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

  defp index_definition(indexes, name) do
    case Enum.find(indexes, fn [index_name, _definition] -> index_name == name end) do
      [_name, definition] -> definition
      nil -> ""
    end
  end

  defp explain_sql(sql) do
    Ecto.Adapters.SQL.query!(Repo, "explain (costs off) " <> sql, []).rows
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp capture_unpublished_selector_sql(now) do
    handler_id = {__MODULE__, make_ref()}
    owner = self()
    prefix = Keyword.get(Repo.config(), :telemetry_prefix, [:fornacast, :repo])

    :ok =
      :telemetry.attach(
        handler_id,
        prefix ++ [:query],
        fn _event, _measurements, metadata, _config ->
          query = metadata[:query]

          if metadata[:source] == "github_import_repository_items" and is_binary(query) and
               String.contains?(query, ~s("publication_evidence")) and
               String.contains?(query, "coalesce") do
            send(owner, {:unpublished_selector_sql, query, metadata[:params]})
          end
        end,
        nil
      )

    try do
      assert :none =
               RepositoryCleanup.reconcile_kind(:unpublished_shadow, now, 1,
                 monotonic_ms: fn -> 0 end
               )

      assert_receive {:unpublished_selector_sql, sql, params}
      {sql, params}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp explain_prepared_sql(sql, params) do
    statement = "fornacast_unpublished_cleanup_selector"

    Ecto.Adapters.SQL.query!(Repo, "prepare #{statement} as #{sql}", [])

    try do
      params = Enum.map_join(params, ", ", &prepared_argument/1)

      Ecto.Adapters.SQL.query!(
        Repo,
        "explain (costs off) execute #{statement}(#{params})",
        []
      ).rows
      |> List.flatten()
      |> Enum.join("\n")
    after
      Ecto.Adapters.SQL.query!(Repo, "deallocate #{statement}", [])
    end
  end

  defp prepared_argument(%DateTime{} = value), do: sql_string(DateTime.to_iso8601(value))

  defp prepared_argument(%NaiveDateTime{} = value),
    do: sql_string(NaiveDateTime.to_iso8601(value))

  defp prepared_argument(%{} = value), do: sql_string(JSON.encode!(value)) <> "::jsonb"

  defp prepared_argument(value) when is_list(value) do
    "ARRAY[" <> Enum.map_join(value, ", ", &prepared_argument/1) <> "]"
  end

  defp prepared_argument(value) when is_binary(value), do: sql_string(value)
  defp prepared_argument(value) when is_integer(value), do: Integer.to_string(value)

  defp sql_string(value), do: "'" <> String.replace(value, "'", "''") <> "'"

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
