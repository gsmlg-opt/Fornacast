defmodule ForgeImports.RepositoryWorkerTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, Organization, OrganizationMember}

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    Persistence,
    Reconciler,
    RecoverySupervisor,
    ReportEntry,
    RepositoryItem,
    RepositoryStager,
    RepositoryWorker
  }

  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, Repo}

  @now ~U[2026-08-27 03:00:00Z]
  @pat "github_pat_repository_worker_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<7>>, 32)}}

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    identity = identity_fixture(actor)
    run = running_one_time_run_fixture(actor, identity)
    item = queued_item_fixture(run, actor)
    attempt_fixture(item)

    %{actor: actor, identity: identity, run: run, item: item}
  end

  test "claims a frozen item and stages into a private unreachable SQL shadow", context do
    assert {:ok, %RepositoryItem{state: :git_staged} = staged} =
             RepositoryWorker.stage(context.item.id,
               owner: "repository-worker-test",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror, request}, 1_000
    assert request.provider == :github
    assert request.owner == "acme"
    assert request.repository == "demo"
    assert request.credential_login == context.identity.login
    assert request.default_branch == "main"

    assert {:error, :not_found} = ForgeRepos.fetch_importing_repository(-1)

    assert {:ok,
            %Repository{
              id: hidden_id,
              owner_user_id: owner_id,
              lifecycle: :importing,
              visibility: :private,
              generation: 1,
              write_version: 0,
              deleted_at: nil
            } = shadow} = ForgeRepos.fetch_importing_repository(staged.hidden_repository_id)

    assert hidden_id == staged.hidden_repository_id
    assert owner_id == context.actor.id
    assert shadow.slug != staged.destination_slug
    assert shadow.storage_path != context.item.replacement_storage_path
    assert shadow.storage_path =~ ~r/\A@hashed\/[0-9a-f]{2}\/[0-9a-f]{2}\/[0-9a-f]{64}\.git\z/
    assert request.destination == ForgeRepos.absolute_storage_path(shadow)
    assert staged.staged_storage_path == request.destination
    assert staged.source_git["empty"] == true
    assert staged.source_git["refs"] == 0
    assert staged.checkpoint["git_staged"] == true
    assert staged.lease_owner == nil
    assert staged.lease_expires_at == nil

    assert ForgeRepos.get_repository(context.actor.username, staged.destination_slug) == nil
    assert ForgeRepos.list_owner_repositories(context.actor) == []
  end

  test "a public destination plan still creates only a private importing shadow", context do
    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^context.item.id),
               set: [
                 destination_visibility: :public,
                 source_metadata: Map.put(context.item.source_metadata, "visibility", "public")
               ]
             )

    assert {:ok, %RepositoryItem{state: :git_staged} = staged} =
             RepositoryWorker.stage(context.item.id,
               owner: "public-plan-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror, _request}, 1_000

    assert {:ok, %Repository{visibility: :private, lifecycle: :importing}} =
             ForgeRepos.fetch_importing_repository(staged.hidden_repository_id)

    assert ForgeRepos.list_owner_repositories(context.actor) == []
  end

  test "a frozen replacement stages an importing shadow at target generation plus one", context do
    suffix = System.unique_integer([:positive])
    digest = :crypto.hash(:sha256, "replacement-target-#{suffix}") |> Base.encode16(case: :lower)

    storage_path =
      "@hashed/#{binary_part(digest, 0, 2)}/#{binary_part(digest, 2, 2)}/#{digest}.git"

    target =
      %Repository{
        owner_user_id: context.actor.id,
        storage_path: storage_path,
        lifecycle: :ready,
        generation: 3
      }
      |> Repository.create_changeset(%{
        slug: "replacement-target-#{suffix}",
        name: "Replacement target",
        visibility: :private
      })
      |> Repo.insert!()

    item =
      queued_item_fixture(context.run, context.actor,
        github_repository_id: 9_800_000_090,
        destination_slug: target.slug,
        conflict_action: :replace,
        replacement_repository_id: target.id,
        replacement_owner_id: target.owner_user_id,
        replacement_storage_path: target.storage_path,
        replacement_generation: target.generation,
        replacement_write_version: target.write_version,
        replacement_updated_at: target.updated_at,
        replacement_last_pushed_at: target.last_pushed_at
      )

    replace_attempt_fixture(item, target)

    assert {:ok, %RepositoryItem{state: :git_staged} = staged} =
             RepositoryWorker.stage(item.id,
               owner: "replacement-generation-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror, _request}, 1_000

    assert {:ok, %Repository{lifecycle: :importing, generation: 4}} =
             ForgeRepos.fetch_importing_repository(staged.hidden_repository_id)

    assert Repo.get!(Repository, target.id).generation == 3
  end

  test "saved credential checkout is item-owned and uses the current verified login", context do
    {run, item, credential} = saved_run_fixture(context.actor, context.identity)

    assert {:ok, %RepositoryItem{state: :git_staged}} =
             RepositoryWorker.stage(item.id,
               owner: "saved-credential-worker",
               lease_seconds: 60,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror, request}, 1_000
    assert request.credential_login == context.identity.login
    assert Repo.get!(ImportRun, run.id).github_credential_id == credential.id
    refute inspect(Repo.get!(RepositoryItem, item.id)) =~ @pat
  end

  test "credential loss atomically pauses the exact run and item before Remote", context do
    {run, item, credential} = saved_run_fixture(context.actor, context.identity)

    assert {1, _rows} =
             Repo.update_all(
               from(saved in GitHubCredential, where: saved.id == ^credential.id),
               set: [status: :invalid]
             )

    assert {:error, :awaiting_credential} =
             RepositoryWorker.stage(item.id,
               owner: "missing-credential-worker",
               lease_seconds: 60,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert %ImportRun{
             state: :awaiting_credential,
             resume_state: :running,
             wait_reason: "credential_invalid",
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(ImportRun, run.id)

    assert %RepositoryItem{
             state: :awaiting_credential,
             resume_state: :staging_git,
             wait_reason: "credential_invalid",
             hidden_repository_id: hidden_id,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, item.id)

    assert is_integer(hidden_id) and hidden_id > 0
    refute_receive {:unexpected_remote, _operation}
  end

  test "credential pause cannot commit after its lease expires behind settlement locks",
       context do
    {run, item, credential} = saved_run_fixture(context.actor, context.identity)

    assert {1, _rows} =
             Repo.update_all(
               from(saved in GitHubCredential, where: saved.id == ^credential.id),
               set: [status: :invalid]
             )

    assert {:error, :lost_lease} =
             RepositoryWorker.with_test_after_settlement_locks_hook(
               fn :credential_pause -> Process.sleep(2_100) end,
               fn ->
                 RepositoryWorker.stage(item.id,
                   owner: "expired-credential-pause-worker",
                   lease_seconds: 2,
                   remote: __MODULE__.UnexpectedRemote,
                   remote_options: [test_pid: self()]
                 )
               end
             )

    assert %ImportRun{state: :running} = Repo.get!(ImportRun, run.id)

    assert %RepositoryItem{
             state: :staging_git,
             source_git: %{},
             checkpoint: %{},
             lease_owner: lease_owner,
             lease_expires_at: %DateTime{}
           } = Repo.get!(RepositoryItem, item.id)

    assert is_binary(lease_owner)
    refute_receive {:unexpected_remote, _operation}
  end

  test "claim rejects a missing exact running attempt without touching the item", context do
    attempt =
      Repo.get_by!(ImportAttempt,
        repository_item_id: context.item.id,
        attempt_number: context.item.attempt_count
      )

    attempt
    |> ImportAttempt.transition_changeset(:completed, %{terminal_at: @now})
    |> Repo.update!()

    assert {:ok, :ignored} =
             RepositoryWorker.stage(context.item.id,
               owner: "stale-attempt-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             state: :queued,
             lock_version: version,
             hidden_repository_id: nil,
             staged_storage_path: nil,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    assert version == context.item.lock_version
    refute_receive {:unexpected_remote, _operation}
  end

  test "live item leases are busy and an expired lease is atomically reclaimed", context do
    assert {:ok, leased} =
             Fornacast.OperationLease.claim(
               RepositoryItem,
               context.item.id,
               "existing-item-owner",
               DateTime.utc_now(:second),
               60,
               allowed_states: [:queued]
             )

    assert {:ok, :busy} =
             RepositoryWorker.stage(context.item.id,
               owner: "blocked-item-owner",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert Repo.get!(RepositoryItem, context.item.id).lease_owner == leased.lease_owner
    refute_receive {:unexpected_remote, _operation}

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^context.item.id),
               set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
             )

    assert {:ok, %RepositoryItem{state: :git_staged, lease_owner: nil}} =
             RepositoryWorker.stage(context.item.id,
               owner: "reclaimed-item-owner",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror, _request}, 1_000
  end

  test "claim expiry is computed only after every blocking eligibility lock", context do
    assert {:ok, %RepositoryItem{state: :git_staged, lease_owner: nil}} =
             RepositoryWorker.with_test_after_claim_locks_hook(
               fn -> Process.sleep(2_100) end,
               fn ->
                 RepositoryWorker.stage(context.item.id,
                   owner: "post-lock-claim-worker",
                   lease_seconds: 2,
                   keyring: @keyring,
                   remote: __MODULE__.SuccessfulRemote,
                   remote_options: [test_pid: self()]
                 )
               end
             )

    assert_receive {:mirror, _request}, 1_000
  end

  test "staging intent cannot use a lease that expires behind capability locks", context do
    assert {:error, :lost_lease} =
             RepositoryStager.with_test_after_capability_locks_hook(
               fn -> Process.sleep(2_100) end,
               fn ->
                 RepositoryWorker.stage(context.item.id,
                   owner: "expired-staging-intent-worker",
                   lease_seconds: 2,
                   keyring: @keyring,
                   remote: __MODULE__.UnexpectedRemote,
                   remote_options: [test_pid: self()]
                 )
               end
             )

    assert %RepositoryItem{
             state: :queued,
             hidden_repository_id: nil,
             staged_storage_path: nil,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    assert Repo.aggregate(Repository, :count) == 0
    refute_receive {:unexpected_remote, _operation}
  end

  test "an expired run lease is accepted once and cleared with Git proof", context do
    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^context.run.id),
               set: [
                 lease_owner: "expired-run-owner",
                 lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)
               ]
             )

    assert [context.item.id] ==
             Reconciler.runnable_repository_item_ids(10, DateTime.utc_now(:second))

    assert {:ok, %RepositoryItem{state: :git_staged}} =
             RepositoryWorker.stage(context.item.id,
               owner: "expired-run-recovery",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror, _request}, 1_000

    assert %ImportRun{lease_owner: nil, lease_expires_at: nil} =
             Repo.get!(ImportRun, context.run.id)
  end

  test "a worker that loses its lease after Remote cannot persist Git proof", context do
    assert {:error, :lost_lease} =
             RepositoryWorker.stage(context.item.id,
               owner: "lease-loser",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.StealLeaseRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive :lease_stolen, 1_000

    assert %RepositoryItem{
             state: :staging_git,
             source_git: %{},
             checkpoint: %{},
             lease_owner: "stolen-owner"
           } = Repo.get!(RepositoryItem, context.item.id)
  end

  test "run cancellation between lock and staging intent rolls back the shadow", context do
    hook = fn repo, run ->
      assert {1, _rows} =
               repo.update_all(
                 from(candidate in ImportRun, where: candidate.id == ^run.id),
                 set: [state: :cancel_requested]
               )
    end

    assert {:error, :lost_lease} =
             RepositoryStager.with_test_after_run_lock_hook(hook, fn ->
               RepositoryWorker.stage(context.item.id,
                 owner: "intent-cancellation-race",
                 lease_seconds: 60,
                 keyring: @keyring,
                 remote: __MODULE__.UnexpectedRemote,
                 remote_options: [test_pid: self()]
               )
             end)

    assert %ImportRun{state: :running} = Repo.get!(ImportRun, context.run.id)

    assert %RepositoryItem{
             state: :queued,
             hidden_repository_id: nil,
             staged_storage_path: nil,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    assert Repo.aggregate(Repository, :count) == 0
    refute_receive {:unexpected_remote, _operation}
  end

  test "generic context transitions cannot enter post-start worker phases", context do
    for target <- [
          :staging_git,
          :git_staged,
          :staging_metadata,
          :ready_to_publish,
          :publishing,
          :published,
          :completed,
          :awaiting_credential,
          :cancel_requested,
          :failed
        ] do
      assert {:error, :invalid_transition} =
               ForgeImports.transition_repository_item(
                 context.actor,
                 context.run,
                 context.item,
                 target
               )
    end

    assert %RepositoryItem{
             state: :queued,
             lock_version: version,
             hidden_repository_id: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    assert version == context.item.lock_version
  end

  test "a forged pre-start item cannot bypass the persisted worker transition fence", context do
    assert {:ok, %{shadow: hidden}} =
             Ecto.Multi.new()
             |> ForgeRepos.create_import_shadow(:shadow, context.actor.id, %{
               item_id: context.item.id,
               generation: 1
             })
             |> Repo.transaction()

    root = Fornacast.Config.repo_storage_root()

    quarantine =
      Path.join(
        Path.join([root, "@hashed", "aa", "bb"]),
        ".fornacast-cleanup-v1-#{String.duplicate("A", 43)}"
      )

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^context.item.id),
               set: [
                 state: :staging_git,
                 hidden_repository_id: hidden.id,
                 staged_storage_path: quarantine,
                 cleanup_state: "cleanup_pending",
                 cleanup_eligible_at: @now,
                 cleanup_attempt_count: 0,
                 cleanup_error: "previous_failure",
                 checkpoint: %{
                   "cleanup_identity" => %{
                     "mode" => 0o700,
                     "major_device" => 1,
                     "minor_device" => 2,
                     "inode" => 3
                   }
                 }
               ]
             )

    persisted = Repo.get!(RepositoryItem, context.item.id)

    forged = %{
      persisted
      | attempt_count: 0,
        cleanup_state: nil,
        cleanup_eligible_at: nil,
        cleanup_error: nil,
        checkpoint: %{}
    }

    assert {:error, :invalid_transition} =
             ForgeImports.transition_repository_item(
               context.actor,
               context.run,
               forged,
               :failed,
               %{failure_kind: "forged_transition"}
             )

    assert %RepositoryItem{
             state: :staging_git,
             attempt_count: 1,
             cleanup_state: "cleanup_pending",
             staged_storage_path: ^quarantine
           } = Repo.get!(RepositoryItem, context.item.id)
  end

  @tag :tmp_dir
  test "bounded default-tree scan records LFS and submodule warnings idempotently", context do
    source = repository_with_unsupported_git!(context.tmp_dir)
    staging_root = Path.join(context.tmp_dir, "staging")
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, staging_root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    assert {:ok,
            %RepositoryItem{
              state: :git_staged,
              warning_count: 2,
              source_git: %{
                "lfs_detected" => true,
                "submodules_detected" => true,
                "scan_truncated" => false
              }
            }} =
             RepositoryWorker.stage(context.item.id,
               owner: "unsupported-scan-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.LocalMirrorRemote,
               remote_options: [source: source]
             )

    assert ["unsupported_git_lfs", "unsupported_submodules"] =
             ReportEntry
             |> where([report], report.repository_item_id == ^context.item.id)
             |> order_by([report], asc: report.classification)
             |> Repo.all()
             |> Enum.map(& &1.classification)

    assert %ImportRun{warning_count: 2} = Repo.get!(ImportRun, context.run.id)

    assert {:ok, :ignored} =
             RepositoryWorker.stage(context.item.id,
               owner: "unsupported-scan-replay",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert Repo.aggregate(ReportEntry, :count) == 2
  end

  @tag :tmp_dir
  test "existing warning evidence is not counted twice when Git proof resumes", context do
    source = repository_with_unsupported_git!(context.tmp_dir)
    staging_root = Path.join(context.tmp_dir, "warning-replay-staging")
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, staging_root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    %ReportEntry{}
    |> ReportEntry.create_changeset(%{
      import_run_id: context.run.id,
      repository_item_id: context.item.id,
      idempotency_key: "git-warning-#{context.item.github_repository_id}-unsupported_git_lfs",
      scope: :repository,
      outcome: :warning,
      classification: "unsupported_git_lfs",
      summary: "Git LFS objects are not imported",
      metadata: %{"category" => "unsupported_git_lfs"},
      source_count: 1
    })
    |> Repo.insert!()

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^context.item.id),
               set: [warning_count: 1]
             )

    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^context.run.id),
               set: [warning_count: 1]
             )

    assert {:ok, %RepositoryItem{state: :git_staged, warning_count: 2}} =
             RepositoryWorker.stage(context.item.id,
               owner: "warning-replay-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.LocalMirrorRemote,
               remote_options: [source: source]
             )

    assert Repo.get!(ImportRun, context.run.id).warning_count == 2
    assert Repo.aggregate(ReportEntry, :count) == 2
  end

  @tag :tmp_dir
  test "a truncated unsupported scan reports truncation instead of claiming absence", context do
    source = repository_with_unsupported_git!(context.tmp_dir)
    staging_root = Path.join(context.tmp_dir, "truncated-staging")
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, staging_root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    assert {:ok,
            %RepositoryItem{
              state: :git_staged,
              warning_count: warning_count,
              source_git: %{"scan_truncated" => true}
            }} =
             RepositoryWorker.stage(context.item.id,
               owner: "truncated-scan-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.LocalMirrorRemote,
               remote_options: [source: source],
               scan_options: [entry_limit: 1]
             )

    classifications =
      ReportEntry
      |> where([report], report.repository_item_id == ^context.item.id)
      |> Repo.all()
      |> Enum.map(& &1.classification)

    assert "unsupported_scan_truncated" in classifications
    assert warning_count == length(classifications)
    assert Repo.get!(ImportRun, context.run.id).warning_count == warning_count
  end

  test "Remote heartbeat renews the exact item lease before half-life", context do
    assert {:ok, %RepositoryItem{state: :git_staged} = staged} =
             RepositoryWorker.stage(context.item.id,
               owner: "heartbeat-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.HeartbeatRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:heartbeat_result, :ok, renewed_version}, 3_000
    assert renewed_version >= context.item.lock_version + 3
    assert staged.lock_version > renewed_version
    assert staged.lease_owner == nil
    assert staged.lease_expires_at == nil
  end

  @tag :tmp_dir
  test "post-scan renewal protects durable proof after a bounded long scan", context do
    source = repository_with_unsupported_git!(context.tmp_dir)
    staging_root = Path.join(context.tmp_dir, "post-scan-renewal")
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, staging_root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    after_scan = fn path ->
      assert {1, _rows} =
               Repo.update_all(
                 from(item in RepositoryItem, where: item.staged_storage_path == ^path),
                 set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), 3, :second)]
               )

      Process.sleep(1_100)
    end

    assert {:ok, %RepositoryItem{state: :git_staged, lease_owner: nil}} =
             RepositoryStager.with_test_after_scan_hook(after_scan, fn ->
               RepositoryWorker.stage(context.item.id,
                 owner: "post-scan-renewal-worker",
                 lease_seconds: 2,
                 keyring: @keyring,
                 remote: __MODULE__.LocalMirrorRemote,
                 remote_options: [source: source],
                 persistence_hook: fn ->
                   Process.sleep(3_200)
                   :ok
                 end
               )
             end)
  end

  test "Remote cancellation polls durable intent and cannot persist success", context do
    assert {:error, :cancelled} =
             RepositoryWorker.stage(context.item.id,
               owner: "cancel-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.CancelRemote,
               remote_options: [test_pid: self(), run_id: context.run.id]
             )

    assert_receive {:cancel_result, true}, 1_000

    assert %ImportRun{state: :cancel_requested} = Repo.get!(ImportRun, context.run.id)

    assert %RepositoryItem{
             state: :cancel_requested,
             source_git: %{},
             checkpoint: %{},
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, context.item.id)
  end

  test "cancellation settlement cannot commit after its lease expires behind locks", context do
    assert {:error, :lost_lease} =
             RepositoryWorker.with_test_after_settlement_locks_hook(
               fn :cancellation -> Process.sleep(2_100) end,
               fn ->
                 RepositoryWorker.stage(context.item.id,
                   owner: "expired-cancellation-worker",
                   lease_seconds: 2,
                   keyring: @keyring,
                   remote: __MODULE__.CancelRemote,
                   remote_options: [test_pid: self(), run_id: context.run.id]
                 )
               end
             )

    assert_receive {:cancel_result, true}, 1_000
    assert %ImportRun{state: :cancel_requested} = Repo.get!(ImportRun, context.run.id)

    assert %RepositoryItem{
             state: :staging_git,
             source_git: %{},
             checkpoint: %{},
             lease_owner: lease_owner,
             lease_expires_at: %DateTime{}
           } = Repo.get!(RepositoryItem, context.item.id)

    assert is_binary(lease_owner)
  end

  test "success returned after durable cancellation cannot persist Git proof", context do
    assert {:error, :cancelled} =
             RepositoryWorker.stage(context.item.id,
               owner: "success-after-cancel-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessAfterCancelRemote,
               remote_options: [test_pid: self(), run_id: context.run.id]
             )

    assert_receive {:success_after_cancel, destination}, 1_000
    assert is_binary(destination)
    assert %ImportRun{state: :cancel_requested} = Repo.get!(ImportRun, context.run.id)

    assert %RepositoryItem{
             state: :cancel_requested,
             source_git: %{},
             checkpoint: %{},
             next_attempt_at: nil,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, context.item.id)
  end

  test "real cancellation quarantine evidence persists after the run leaves running", context do
    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(context.item.id,
               owner: "cancel-cleanup-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.CancelCleanupPendingRemote,
               remote_options: [test_pid: self(), run_id: context.run.id]
             )

    assert_receive {:cancel_cleanup_pending, destination}, 1_000
    assert %ImportRun{state: :cancel_requested} = Repo.get!(ImportRun, context.run.id)

    assert %RepositoryItem{
             state: :staging_git,
             cleanup_state: "cleanup_pending",
             cleanup_error: "cancelled",
             staged_storage_path: quarantine,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    refute File.exists?(destination)
    assert File.dir?(quarantine)
  end

  test "every classified quarantine kind remains durable", context do
    for kind <- [
          :cancelled,
          :heartbeat_failed,
          :owner_down,
          :timeout,
          :host_policy,
          :credential_unavailable,
          :disk_unavailable,
          :output_limit,
          :process_exit,
          :process_unavailable,
          :source_validation,
          :default_branch,
          :ref_limit,
          :repository_limit,
          :unsafe_config,
          :unsafe_credential_state,
          :previous_failure
        ] do
      run = running_one_time_run_fixture(context.actor, context.identity)
      item = queued_item_fixture(run, context.actor, github_repository_id: next_github_id())
      attempt_fixture(item)

      assert {:error, :cleanup_pending} =
               RepositoryWorker.stage(item.id,
                 owner: "cleanup-kind-#{kind}",
                 lease_seconds: 60,
                 keyring: @keyring,
                 remote: __MODULE__.ClassifiedCleanupRemote,
                 remote_options: [kind: kind]
               )

      assert %RepositoryItem{
               cleanup_state: "cleanup_pending",
               cleanup_error: cleanup_error,
               lease_owner: nil
             } = Repo.get!(RepositoryItem, item.id)

      assert cleanup_error == Atom.to_string(kind)
    end
  end

  test "startup reconciler stages exact runnable items in its existing serial scan", context do
    assert [context.item.id] ==
             Reconciler.runnable_repository_item_ids(10, DateTime.utc_now(:second))

    supervisor =
      start_supervised!(
        {RecoverySupervisor,
         name: __MODULE__.RecoverySupervisor,
         task_supervisor: __MODULE__.TaskSupervisor,
         reconciler_name: __MODULE__.Reconciler,
         enabled: true,
         interval_ms: 50,
         batch_size: 10,
         repository_worker_options: [
           lease_seconds: 60,
           keyring: @keyring,
           remote: __MODULE__.SuccessfulRemote,
           remote_options: [test_pid: self()]
         ]}
      )

    assert is_pid(supervisor)
    assert_receive {:mirror, _request}, 2_000

    assert eventually(fn ->
             match?(
               %RepositoryItem{state: :git_staged, lease_owner: nil},
               Repo.get(RepositoryItem, context.item.id)
             )
           end)

    assert :ok = stop_supervised(RecoverySupervisor)
  end

  test "reconciler coerces every repository-worker lease to the accepted minimum", context do
    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.LeaseRecoverySupervisor,
       task_supervisor: __MODULE__.LeaseTaskSupervisor,
       reconciler_name: __MODULE__.LeaseReconciler,
       enabled: true,
       interval_ms: 50,
       batch_size: 1,
       lease_seconds: 1,
       repository_worker: __MODULE__.LeaseProbeWorker,
       repository_worker_options: [test_pid: self(), lease_seconds: 1]}
    )

    assert_receive {:repository_worker_lease, item_id, 2}, 2_000
    assert item_id == context.item.id
    assert :ok = stop_supervised(RecoverySupervisor)
  end

  test "one bounded reconciler scan processes repository workers serially", context do
    second =
      queued_item_fixture(context.run, context.actor,
        github_repository_id: 9_800_000_099,
        source_full_name: "acme/beta",
        source_name: "beta",
        destination_slug: "beta"
      )

    attempt_fixture(second)

    assert [context.item.id, second.id] ==
             Reconciler.runnable_repository_item_ids(10, DateTime.utc_now(:second))

    {:ok, state} = Agent.start_link(fn -> %{active: 0, max_active: 0, calls: []} end)

    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.SerialRecoverySupervisor,
       task_supervisor: __MODULE__.SerialTaskSupervisor,
       reconciler_name: __MODULE__.SerialReconciler,
       enabled: true,
       interval_ms: 50,
       batch_size: 10,
       repository_worker_options: [
         lease_seconds: 60,
         keyring: @keyring,
         remote: __MODULE__.SerialRemote,
         remote_options: [test_pid: self(), state: state]
       ]}
    )

    assert_receive {:serial_remote_enter, 1, first_worker}, 2_000
    refute_receive {:serial_remote_enter, 2, _second_worker}, 100

    assert_raise RuntimeError, fn ->
      Task.Supervisor.async_nolink(__MODULE__.SerialTaskSupervisor, fn -> :unexpected end)
    end

    send(first_worker, {:continue_serial_remote, 1})
    assert_receive {:serial_remote_enter, 2, second_worker}, 2_000
    send(second_worker, {:continue_serial_remote, 2})

    assert eventually(fn ->
             Enum.all?([context.item.id, second.id], fn id ->
               match?(%RepositoryItem{state: :git_staged}, Repo.get(RepositoryItem, id))
             end)
           end)

    assert %{active: 0, max_active: 1, calls: ["demo", "beta"]} = Agent.get(state, & &1)
    assert :ok = stop_supervised(RecoverySupervisor)
  end

  test "a persistently failing low item is deferred so a later item can progress", context do
    second =
      queued_item_fixture(context.run, context.actor,
        github_repository_id: 9_800_000_100,
        source_full_name: "acme/later",
        source_name: "later",
        destination_slug: "later"
      )

    attempt_fixture(second)

    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.FairRecoverySupervisor,
       task_supervisor: __MODULE__.FairTaskSupervisor,
       reconciler_name: __MODULE__.FairReconciler,
       enabled: true,
       interval_ms: 50,
       batch_size: 1,
       repository_worker_options: [
         lease_seconds: 60,
         keyring: @keyring,
         remote: __MODULE__.FirstFailsRemote,
         remote_options: [test_pid: self()]
       ]}
    )

    assert_receive {:persistent_failure, "demo"}, 2_000
    assert_receive {:later_success, "later"}, 2_000

    assert %RepositoryItem{
             state: :staging_git,
             failure_kind: "staging_unavailable",
             next_attempt_at: %DateTime{},
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    assert eventually(fn ->
             match?(
               %RepositoryItem{state: :git_staged, lease_owner: nil},
               Repo.get(RepositoryItem, second.id)
             )
           end)

    assert :ok = stop_supervised(RecoverySupervisor)
  end

  test "a full due retry batch cannot starve a higher never-attempted item", context do
    additional_lows =
      for index <- 1..24 do
        item =
          queued_item_fixture(context.run, context.actor,
            github_repository_id: next_github_id(),
            source_full_name: "acme/retry-#{index}",
            source_name: "retry-#{index}",
            destination_slug: "retry-#{index}"
          )

        attempt_fixture(item)
        item
      end

    low_ids = Enum.map([context.item | additional_lows], & &1.id)
    due_at = DateTime.add(@now, -1, :second)

    assert {25, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id in ^low_ids),
               set: [next_attempt_at: due_at, failure_kind: "staging_unavailable"]
             )

    fresh =
      queued_item_fixture(context.run, context.actor,
        github_repository_id: next_github_id(),
        source_full_name: "acme/fresh-after-full-retry-batch",
        source_name: "fresh-after-full-retry-batch",
        destination_slug: "fresh-after-full-retry-batch"
      )

    attempt_fixture(fresh)

    assert [fresh.id | Enum.take(low_ids, 24)] ==
             Reconciler.runnable_repository_item_ids(25, @now)
  end

  test "terminal no-slot cleanup backoff preserves the run and lets another run progress",
       context do
    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "terminal-fairness-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, _destination}, 1_000
    low_before_terminal = Repo.get!(RepositoryItem, context.item.id)

    assert {:ok, %ImportRun{state: :failed} = terminal_run} =
             ForgeImports.transition_run(
               context.actor,
               Repo.get!(ImportRun, context.run.id),
               :failed,
               %{terminal_at: @now}
             )

    later_run = running_one_time_run_fixture(context.actor, context.identity)

    later =
      queued_item_fixture(later_run, context.actor,
        github_repository_id: 9_800_000_101,
        source_full_name: "acme/later",
        source_name: "later",
        destination_slug: "later"
      )

    attempt_fixture(later)

    start_supervised!(
      {RecoverySupervisor,
       name: __MODULE__.TerminalFairRecoverySupervisor,
       task_supervisor: __MODULE__.TerminalFairTaskSupervisor,
       reconciler_name: __MODULE__.TerminalFairReconciler,
       enabled: true,
       interval_ms: 50,
       batch_size: 1,
       repository_worker_options: [
         lease_seconds: 60,
         keyring: @keyring,
         remote: __MODULE__.FirstFailsRemote,
         remote_options: [test_pid: self()]
       ]}
    )

    assert_receive {:later_success, "later"}, 2_000
    refute_receive {:persistent_failure, "demo"}, 100

    assert eventually(fn ->
             match?(%RepositoryItem{state: :git_staged}, Repo.get(RepositoryItem, later.id))
           end)

    assert Repo.get!(ImportRun, terminal_run.id).lock_version == terminal_run.lock_version

    assert %RepositoryItem{next_attempt_at: next_attempt_at} =
             Repo.get!(RepositoryItem, context.item.id)

    assert next_attempt_at == low_before_terminal.next_attempt_at
    assert :ok = stop_supervised(RecoverySupervisor)
  end

  test "a failed organization activation is durably deferred before later work is selected",
       context do
    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^context.item.id),
               set: [state: :failed]
             )

    {run, low, sibling} = new_organization_fixture(context.actor, context.identity)

    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^sibling.id),
               set: [selected: false]
             )

    other = user_fixture()

    assert {:ok, _raced} =
             ForgeAccounts.create_organization(other, %{
               username: run.destination_organization_slug,
               display_name: "Raced organization"
             })

    later_run = running_one_time_run_fixture(context.actor, context.identity)

    later =
      queued_item_fixture(later_run, context.actor,
        github_repository_id: next_github_id(),
        source_full_name: "acme/later-activation",
        source_name: "later-activation",
        destination_slug: "later-activation"
      )

    attempt_fixture(later)

    assert {:error, :destination_changed} =
             RepositoryWorker.stage(low.id,
               owner: "activation-backoff-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             state: :queued,
             next_attempt_at: %DateTime{},
             failure_kind: "destination_changed",
             lease_owner: nil,
             hidden_repository_id: nil
           } = Repo.get!(RepositoryItem, low.id)

    assert [later.id] ==
             Reconciler.runnable_repository_item_ids(1, DateTime.utc_now(:second))

    refute_receive {:unexpected_remote, _operation}

    assert Repo.aggregate(
             from(repository in Repository, where: repository.lifecycle == :importing),
             :count
           ) == 0
  end

  @tag :tmp_dir
  test "RecoverySupervisor death kills Remote descendants and restart records quarantine",
       context do
    fake = write_blocking_remote_git!(context.tmp_dir)
    credential_root = Path.join(context.tmp_dir, "credentials")
    staging_root = Path.join(context.tmp_dir, "supervisor-death-staging")
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, staging_root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    recovery_options = [
      name: __MODULE__.DeathRecoverySupervisor,
      task_supervisor: __MODULE__.DeathTaskSupervisor,
      reconciler_name: __MODULE__.DeathReconciler,
      enabled: true,
      interval_ms: 50,
      batch_size: 10,
      repository_worker_options: [
        lease_seconds: 2,
        keyring: @keyring,
        remote: GitCore.Remote,
        remote_options: [
          git: fake.git,
          resolver: public_resolver(),
          credential_root: credential_root
        ]
      ]
    ]

    {:ok, recovery} = RecoverySupervisor.start_link(recovery_options)
    Process.unlink(recovery)

    on_exit(fn ->
      case Process.whereis(__MODULE__.DeathRecoverySupervisor) do
        pid when is_pid(pid) -> Supervisor.stop(pid, :shutdown, 20_000)
        nil -> :ok
      end
    end)

    assert recovery == Process.whereis(__MODULE__.DeathRecoverySupervisor)
    old_task_supervisor = Process.whereis(__MODULE__.DeathTaskSupervisor)
    assert is_pid(old_task_supervisor)
    assert eventually(fn -> File.exists?(fake.child_pid) end, 250)
    child_os_pid = fake.child_pid |> File.read!() |> String.trim()
    assert os_process_alive?(child_os_pid)

    assert %RepositoryItem{state: :staging_git, lease_owner: lease_owner} =
             Repo.get!(RepositoryItem, context.item.id)

    assert is_binary(lease_owner)

    Process.exit(recovery, :kill)

    assert eventually(fn ->
             Process.whereis(__MODULE__.DeathRecoverySupervisor) == nil and
               Process.whereis(__MODULE__.DeathTaskSupervisor) == nil and
               Process.whereis(__MODULE__.DeathReconciler) == nil
           end)

    assert eventually(fn -> not os_process_alive?(child_os_pid) end, 500)

    assert eventually(
             fn ->
               not File.exists?(credential_root) or
                 match?({:ok, []}, File.ls(credential_root))
             end,
             1_000
           )

    {:ok, restarted_recovery} = RecoverySupervisor.start_link(recovery_options)
    Process.unlink(restarted_recovery)
    assert restarted_recovery != recovery

    assert restarted_task_supervisor = Process.whereis(__MODULE__.DeathTaskSupervisor)
    assert restarted_task_supervisor != old_task_supervisor

    assert eventually(
             fn ->
               match?(
                 %RepositoryItem{
                   state: :staging_git,
                   cleanup_state: "cleanup_pending",
                   cleanup_error: "previous_failure",
                   lease_owner: nil
                 },
                 Repo.get(RepositoryItem, context.item.id)
               )
             end,
             1_000
           )

    final = Repo.get!(RepositoryItem, context.item.id)
    assert File.dir?(final.staged_storage_path)
    refute inspect(final) =~ @pat
    assert occurrences(File.read!(fake.argv_log), "ARG=clone\n") == 1
  end

  @tag :tmp_dir
  test "a lost Remote result recovers by validated refresh and never mirrors twice", context do
    source = repository_with_unsupported_git!(context.tmp_dir)
    staging_root = Path.join(context.tmp_dir, "refresh-staging")
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, staging_root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "lost-result-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.LostMirrorResultRemote,
               remote_options: [source: source, test_pid: self()]
             )

    assert_receive {:lost_mirror_result, destination}, 1_000
    assert File.dir?(destination)
    make_item_due!(context.item.id)

    assert {:ok,
            %RepositoryItem{
              state: :git_staged,
              staged_storage_path: ^destination,
              next_attempt_at: nil,
              failure_kind: nil,
              failure_detail: nil
            }} =
             RepositoryWorker.stage(context.item.id,
               owner: "refresh-recovery-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.RefreshProbeRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:refresh, ^destination}, 1_000
    refute_receive {:unexpected_mirror, ^destination}
  end

  test "ambiguous wrong-mode staging fails closed before credential checkout", context do
    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "ambiguous-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, destination}, 1_000
    File.mkdir!(destination)
    File.chmod!(destination, 0o755)
    make_item_due!(context.item.id)

    assert {:error, :ambiguous_staging} =
             RepositoryWorker.stage(context.item.id,
               owner: "ambiguous-recovery-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             state: :staging_git,
             cleanup_state: nil,
             staged_storage_path: ^destination,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    refute_receive {:unexpected_remote, _operation}
    assert {:ok, %File.Stat{mode: mode}} = File.lstat(destination)
    assert Bitwise.band(mode, 0o777) == 0o755
  end

  test "post-Remote database outage rolls back reports run count and item proof", context do
    assert {:error, :persistence_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "persistence-outage-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()],
               persistence_hook: fn -> {:error, :injected_database_outage} end
             )

    assert_receive {:mirror, _request}, 1_000

    assert %ImportRun{warning_count: 0, lock_version: run_version} =
             Repo.get!(ImportRun, context.run.id)

    assert run_version == context.run.lock_version + 2

    assert %RepositoryItem{
             state: :staging_git,
             source_git: %{},
             checkpoint: %{},
             warning_count: 0,
             failure_kind: "persistence_unavailable",
             next_attempt_at: %DateTime{},
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    assert Repo.aggregate(ReportEntry, :count) == 0
  end

  test "Git proof cannot commit after its lease expires inside the final transaction", context do
    hook = fn ->
      assert {1, _rows} =
               Repo.update_all(
                 from(item in RepositoryItem, where: item.id == ^context.item.id),
                 set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), 1, :second)]
               )

      Process.sleep(1_100)
      :ok
    end

    assert {:error, :lost_lease} =
             RepositoryWorker.stage(context.item.id,
               owner: "expired-final-proof-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()],
               persistence_hook: hook
             )

    assert_receive {:mirror, _request}, 1_000

    assert %RepositoryItem{
             state: :staging_git,
             source_git: %{},
             checkpoint: %{},
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)
  end

  test "stale shadow identity fails closed and releases the claimed item", context do
    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "stale-shadow-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, _destination}, 1_000
    staged = Repo.get!(RepositoryItem, context.item.id)
    other = user_fixture()
    make_item_due!(context.item.id)

    assert {1, _rows} =
             Repo.update_all(
               from(shadow in Repository, where: shadow.id == ^staged.hidden_repository_id),
               set: [owner_user_id: other.id]
             )

    assert {:error, :ambiguous_staging} =
             RepositoryWorker.stage(context.item.id,
               owner: "stale-shadow-recovery-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             state: :staging_git,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    refute_receive {:unexpected_remote, _operation}
  end

  test "retry rejects drifted private shadow generation write version and internal slug",
       context do
    other = user_fixture()

    for updates <- [
          [owner_user_id: other.id],
          [visibility: :public],
          [generation: 2],
          [write_version: 1],
          [slug: "ordinary-shadow"]
        ] do
      run = running_one_time_run_fixture(context.actor, context.identity)
      item = queued_item_fixture(run, context.actor, github_repository_id: next_github_id())
      attempt_fixture(item)

      assert {:error, :staging_unavailable} =
               RepositoryWorker.stage(item.id,
                 owner: "shadow-drift-first-worker",
                 lease_seconds: 60,
                 keyring: @keyring,
                 remote: __MODULE__.UnavailableRemote,
                 remote_options: [test_pid: self()]
               )

      assert_receive {:remote_unavailable, _destination}, 1_000
      staged = Repo.get!(RepositoryItem, item.id)
      make_item_due!(item.id)

      assert {1, _rows} =
               Repo.update_all(
                 from(shadow in Repository, where: shadow.id == ^staged.hidden_repository_id),
                 set: updates
               )

      assert {:error, :ambiguous_staging} =
               RepositoryWorker.stage(item.id,
                 owner: "shadow-drift-recovery-worker",
                 lease_seconds: 60,
                 keyring: @keyring,
                 remote: __MODULE__.UnexpectedRemote,
                 remote_options: [test_pid: self()]
               )

      assert %RepositoryItem{state: :staging_git, lease_owner: nil} =
               Repo.get!(RepositoryItem, item.id)
    end

    refute_receive {:unexpected_remote, _operation}
  end

  test "Turso busy retries the entire git-proof transaction without double commit", context do
    hook_key = {__MODULE__, make_ref()}
    Process.put(hook_key, :busy)

    try do
      hook = fn ->
        if turso?() and Process.get(hook_key) == :busy do
          Process.put(hook_key, :ready)
          raise Turso.Error, code: :busy, message: "injected git-proof busy"
        end

        :ok
      end

      assert {:ok, %RepositoryItem{state: :git_staged}} =
               RepositoryWorker.stage(context.item.id,
                 owner: "persistence-busy-worker",
                 lease_seconds: 60,
                 keyring: @keyring,
                 remote: __MODULE__.SuccessfulRemote,
                 remote_options: [test_pid: self()],
                 persistence_hook: hook
               )

      assert_receive {:mirror, _request}, 1_000
      assert Repo.get!(ImportRun, context.run.id).lock_version == context.run.lock_version + 2
      assert Repo.aggregate(ReportEntry, :count) == 0
    after
      Process.delete(hook_key)
    end
  end

  test "activates one frozen new organization atomically before item claim", context do
    {run, item, sibling} = new_organization_fixture(context.actor, context.identity)

    assert {:ok, %RepositoryItem{state: :git_staged} = staged} =
             RepositoryWorker.stage(item.id,
               owner: "new-organization-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror, _request}, 1_000

    assert %ImportRun{
             destination_organization_id: organization_id,
             lock_version: run_version
           } = Repo.get!(ImportRun, run.id)

    assert is_integer(organization_id) and organization_id > 0
    assert run_version == run.lock_version + 3

    assert %Organization{
             id: ^organization_id,
             username: "imported-tools",
             display_name: "Imported Tools",
             description: "GitHub organization",
             kind: :organization,
             state: :active
           } = Repo.get!(Organization, organization_id)

    assert [
             %OrganizationMember{
               organization_id: ^organization_id,
               user_id: actor_id,
               role: :owner
             }
           ] = Repo.all(OrganizationMember)

    assert actor_id == context.actor.id

    for expected <- [item, sibling] do
      assert %RepositoryItem{
               destination_owner_id: ^organization_id,
               lock_version: item_version
             } = Repo.get!(RepositoryItem, expected.id)

      assert item_version >= expected.lock_version + 1
    end

    assert {:ok, %Repository{owner_user_id: ^organization_id}} =
             ForgeRepos.fetch_importing_repository(staged.hidden_repository_id)

    assert ["github_import.organization_activated", "organization.created"] =
             AuditEvent
             |> Repo.all()
             |> Enum.filter(&(&1.target_id == Integer.to_string(organization_id)))
             |> Enum.map(& &1.action)
             |> Enum.sort()

    assert {:ok, %RepositoryItem{state: :git_staged, destination_owner_id: ^organization_id}} =
             RepositoryWorker.stage(sibling.id,
               owner: "new-organization-sibling-replay",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.SuccessfulRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror, _request}, 1_000

    assert Repo.aggregate(
             from(account in Organization, where: account.kind == :organization),
             :count
           ) ==
             1

    assert Repo.aggregate(OrganizationMember, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 2
  end

  test "a new-organization namespace race rolls back before claim and shadow", context do
    {run, item, sibling} = new_organization_fixture(context.actor, context.identity)
    other = user_fixture()

    assert {:ok, raced_organization} =
             ForgeAccounts.create_organization(other, %{
               username: run.destination_organization_slug,
               display_name: "Raced owner"
             })

    assert {:error, :destination_changed} =
             RepositoryWorker.stage(item.id,
               owner: "new-organization-race",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert %ImportRun{destination_organization_id: nil} = Repo.get!(ImportRun, run.id)

    assert_activation_failure_deferred(item, sibling)

    assert ForgeAccounts.organization_role(other, raced_organization) == :owner
    assert ForgeAccounts.organization_role(context.actor, raced_organization) == nil
    refute_receive {:unexpected_remote, _operation}
    assert Repo.aggregate(Repository, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
  end

  test "organization activation audit collision rolls back organization owner and propagation",
       context do
    {run, item, sibling} = new_organization_fixture(context.actor, context.identity)

    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor_user_id: context.actor.id,
      action: "organization.created",
      target_type: "organization",
      target_id: "999999",
      metadata: %{},
      operation_id: "github-import-organization-#{run.id}"
    })
    |> Repo.insert!()

    assert {:error, :destination_changed} =
             RepositoryWorker.stage(item.id,
               owner: "organization-audit-collision",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert %ImportRun{destination_organization_id: nil} = Repo.get!(ImportRun, run.id)

    assert_activation_failure_deferred(item, sibling)

    assert Repo.aggregate(
             from(account in Organization, where: account.kind == :organization),
             :count
           ) == 0

    assert Repo.aggregate(OrganizationMember, :count) == 0
    assert [%AuditEvent{target_id: "999999"}] = Repo.all(AuditEvent)
    refute_receive {:unexpected_remote, _operation}
  end

  test "organization activation-event collision rolls back organization owner and propagation",
       context do
    {run, item, sibling} = new_organization_fixture(context.actor, context.identity)

    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor_user_id: context.actor.id,
      action: "github_import.organization_activated",
      target_type: "organization",
      target_id: "999999",
      metadata: %{},
      operation_id: "github-import-organization-#{run.id}"
    })
    |> Repo.insert!()

    assert {:error, :destination_changed} =
             RepositoryWorker.stage(item.id,
               owner: "organization-activation-audit-collision",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    assert %ImportRun{destination_organization_id: nil} = Repo.get!(ImportRun, run.id)

    assert_activation_failure_deferred(item, sibling)

    assert Repo.aggregate(
             from(account in Organization, where: account.kind == :organization),
             :count
           ) == 0

    assert Repo.aggregate(OrganizationMember, :count) == 0
    assert [%AuditEvent{target_id: "999999"}] = Repo.all(AuditEvent)
    refute_receive {:unexpected_remote, _operation}
  end

  test "persists strict cleanup-pending evidence and blocks every successor path", context do
    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(context.item.id,
               owner: "cleanup-pending-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.CleanupPendingRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:mirror_cleanup_pending, destination}, 1_000

    assert %RepositoryItem{
             state: :staging_git,
             cleanup_state: "cleanup_pending",
             cleanup_error: "source_validation",
             staged_storage_path: quarantine,
             checkpoint: %{
               "cleanup_identity" => %{
                 "mode" => 0o700,
                 "major_device" => major_device,
                 "minor_device" => minor_device,
                 "inode" => inode
               }
             },
             lease_owner: nil,
             lease_expires_at: nil
           } = persisted = Repo.get!(RepositoryItem, context.item.id)

    assert is_integer(major_device)
    assert is_integer(minor_device)
    assert is_integer(inode) and inode > 0
    refute File.exists?(destination)
    assert File.dir?(quarantine)
    assert Path.dirname(quarantine) == Path.dirname(destination)
    assert Path.basename(quarantine) =~ ~r/\A\.fornacast-cleanup-v1-[A-Za-z0-9_-]{43}\z/
    refute inspect(persisted) =~ quarantine
    refute inspect(persisted) =~ @pat

    assert {:ok, :ignored} =
             RepositoryWorker.stage(context.item.id,
               owner: "cleanup-pending-successor",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.UnexpectedRemote,
               remote_options: [test_pid: self()]
             )

    refute_receive {:unexpected_remote, _operation}
    assert Repo.get!(RepositoryItem, context.item.id).staged_storage_path == quarantine
  end

  test "caller-loss recovery persists deterministic cleanup evidence without PAT checkout",
       context do
    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "caller-loss-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, destination}, 1_000

    assert %RepositoryItem{
             state: :staging_git,
             cleanup_state: nil,
             staged_storage_path: ^destination,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    quarantine = create_cleanup_slot!(destination)

    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(context.item.id,
               owner: "caller-loss-recovery-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.EvidenceOnlyRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             cleanup_state: "cleanup_pending",
             cleanup_error: "previous_failure",
             staged_storage_path: ^quarantine,
             next_attempt_at: nil,
             failure_kind: nil,
             failure_detail: nil,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    refute_receive {:unexpected_remote, _operation}
  end

  test "cancel reconciliation rediscovers a lost quarantine without credential checkout",
       context do
    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "cancel-loss-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, destination}, 1_000
    quarantine = create_cleanup_slot!(destination)

    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^context.run.id),
               set: [state: :cancel_requested]
             )

    assert [context.item.id] ==
             Reconciler.runnable_repository_item_ids(
               10,
               DateTime.add(DateTime.utc_now(:second), 31, :second)
             )

    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(context.item.id,
               owner: "cancel-loss-recovery-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.EvidenceOnlyRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             cleanup_state: "cleanup_pending",
             cleanup_error: "previous_failure",
             staged_storage_path: ^quarantine,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    refute_receive {:unexpected_remote, _operation}
  end

  test "disabled actor cleanup recovery persists a lost slot under a running run", context do
    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "disabled-actor-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, destination}, 1_000
    quarantine = create_cleanup_slot!(destination)

    context.actor
    |> ForgeAccounts.User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    assert [context.item.id] ==
             Reconciler.runnable_repository_item_ids(
               10,
               DateTime.add(DateTime.utc_now(:second), 31, :second)
             )

    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(context.item.id,
               owner: "disabled-actor-cleanup-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.EvidenceOnlyRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             cleanup_state: "cleanup_pending",
             staged_storage_path: ^quarantine,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    refute_receive {:unexpected_remote, _operation}
  end

  test "disabled actor cleanup bypasses activation replay only for an already activated org",
       context do
    {_run, item, _sibling} = new_organization_fixture(context.actor, context.identity)

    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(item.id,
               owner: "disabled-org-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, destination}, 1_000
    quarantine = create_cleanup_slot!(destination)
    activated_run = Repo.get!(ImportRun, item.import_run_id)
    assert is_integer(activated_run.destination_organization_id)

    context.actor
    |> ForgeAccounts.User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    assert [item.id] ==
             Reconciler.runnable_repository_item_ids(
               10,
               DateTime.add(DateTime.utc_now(:second), 31, :second)
             )

    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(item.id,
               owner: "disabled-org-cleanup-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.EvidenceOnlyRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             cleanup_state: "cleanup_pending",
             staged_storage_path: ^quarantine,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, item.id)

    refute_receive {:unexpected_remote, _operation}
  end

  test "validated cleanup bypasses drifted new-organization replay without enabling Git",
       context do
    {_run, item, sibling} = new_organization_fixture(context.actor, context.identity)

    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(item.id,
               owner: "drifted-org-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, destination}, 1_000
    quarantine = create_cleanup_slot!(destination)

    assert {1, _rows} =
             Repo.update_all(
               from(candidate in RepositoryItem, where: candidate.id == ^sibling.id),
               set: [destination_owner_id: nil]
             )

    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(item.id,
               owner: "drifted-org-cleanup-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.EvidenceOnlyRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             cleanup_state: "cleanup_pending",
             staged_storage_path: ^quarantine,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, item.id)

    refute_receive {:unexpected_remote, _operation}
  end

  test "terminal run cleanup recovery persists a lost slot without a credential", context do
    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "terminal-run-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, destination}, 1_000
    quarantine = create_cleanup_slot!(destination)
    run = Repo.get!(ImportRun, context.run.id)

    assert {:ok, %ImportRun{state: :failed}} =
             ForgeImports.transition_run(context.actor, run, :failed, %{terminal_at: @now})

    assert [context.item.id] ==
             Reconciler.runnable_repository_item_ids(
               10,
               DateTime.add(DateTime.utc_now(:second), 31, :second)
             )

    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(context.item.id,
               owner: "terminal-run-cleanup-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.EvidenceOnlyRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             cleanup_state: "cleanup_pending",
             staged_storage_path: ^quarantine,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    refute_receive {:unexpected_remote, _operation}
  end

  test "completed run cleanup recovery persists a lost slot without a credential", context do
    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(context.item.id,
               owner: "completed-run-first-worker",
               lease_seconds: 60,
               keyring: @keyring,
               remote: __MODULE__.UnavailableRemote,
               remote_options: [test_pid: self()]
             )

    assert_receive {:remote_unavailable, destination}, 1_000
    quarantine = create_cleanup_slot!(destination)

    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^context.run.id),
               set: [
                 state: :completed,
                 terminal_at: @now,
                 credential_ciphertext: nil,
                 credential_nonce: nil,
                 credential_tag: nil,
                 credential_key_id: nil
               ]
             )

    assert [context.item.id] ==
             Reconciler.runnable_repository_item_ids(
               10,
               DateTime.add(DateTime.utc_now(:second), 31, :second)
             )

    assert {:error, :cleanup_pending} =
             RepositoryWorker.stage(context.item.id,
               owner: "completed-run-cleanup-worker",
               lease_seconds: 60,
               keyring: :unavailable,
               remote: __MODULE__.EvidenceOnlyRemote,
               remote_options: [test_pid: self()]
             )

    assert %RepositoryItem{
             cleanup_state: "cleanup_pending",
             staged_storage_path: ^quarantine,
             lease_owner: nil
           } = Repo.get!(RepositoryItem, context.item.id)

    refute_receive {:unexpected_remote, _operation}
  end

  defmodule SuccessfulRemote do
    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      if File.exists?(request.destination), do: raise("destination existed before Remote")
      if not File.dir?(Path.dirname(request.destination)), do: raise("staging parent missing")

      send(Keyword.fetch!(opts, :test_pid), {:mirror, request})

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: true,
         default_branch: request.default_branch,
         refs: 0,
         bytes: 0
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule CleanupPendingRemote do
    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      send(Keyword.fetch!(opts, :test_pid), {:mirror_cleanup_pending, request.destination})

      quarantine = cleanup_slot(request.destination)
      File.mkdir!(quarantine)
      File.chmod!(quarantine, 0o700)
      {:ok, evidence} = GitCore.Remote.cleanup_evidence(request.destination)

      {:error,
       %GitCore.Remote.Error{
         kind: :cleanup_pending,
         detail: %{evidence | original_kind: :source_validation}
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}

    defp cleanup_slot(destination) do
      digest =
        :sha256
        |> :crypto.hash("fornacast.git-core.remote.cleanup-slot.v1\0" <> destination)
        |> Base.url_encode64(padding: false)

      Path.join(Path.dirname(destination), ".fornacast-cleanup-v1-" <> digest)
    end
  end

  defmodule UnexpectedRemote do
    def mirror(_request, _pat, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:unexpected_remote, :mirror})
      raise "unexpected mirror"
    end

    def refresh(_request, _pat, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:unexpected_remote, :refresh})
      raise "unexpected refresh"
    end

    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule UnavailableRemote do
    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      send(Keyword.fetch!(opts, :test_pid), {:remote_unavailable, request.destination})

      {:error, %GitCore.Remote.Error{kind: :remote_unavailable, detail: :injected_unavailability}}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule FirstFailsRemote do
    def mirror(%{repository: "demo"} = request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      send(Keyword.fetch!(opts, :test_pid), {:persistent_failure, request.repository})
      {:error, %GitCore.Remote.Error{kind: :remote_unavailable, detail: :persistent_failure}}
    end

    def mirror(%{repository: "later"} = request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      send(Keyword.fetch!(opts, :test_pid), {:later_success, request.repository})

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: true,
         default_branch: request.default_branch,
         refs: 0,
         bytes: 0
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule LeaseProbeWorker do
    def stage(item_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {
        :repository_worker_lease,
        item_id,
        Keyword.fetch!(opts, :lease_seconds)
      })

      {:ok, :ignored}
    end
  end

  defmodule EvidenceOnlyRemote do
    def mirror(_request, _pat, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:unexpected_remote, :mirror})
      raise "unexpected mirror"
    end

    def refresh(_request, _pat, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:unexpected_remote, :refresh})
      raise "unexpected refresh"
    end

    def cleanup_evidence(destination), do: GitCore.Remote.cleanup_evidence(destination)
  end

  defmodule LocalMirrorRemote do
    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      source = Keyword.fetch!(opts, :source)
      git = System.find_executable("git") || raise "git is required"

      {_output, 0} = System.cmd(git, ["clone", "--mirror", source, request.destination])
      File.chmod!(request.destination, 0o700)

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: false,
         default_branch: request.default_branch,
         refs: 1,
         bytes: 1_024
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule HeartbeatRemote do
    import Ecto.Query

    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")

      {1, _rows} =
        ForgeImports.RepositoryItem
        |> where([item], item.staged_storage_path == ^request.destination)
        |> Fornacast.Repo.update_all(
          set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), 1, :second)]
        )

      heartbeat = Keyword.fetch!(opts, :heartbeat).()

      item =
        ForgeImports.RepositoryItem
        |> Ecto.Query.where([item], item.staged_storage_path == ^request.destination)
        |> Fornacast.Repo.one!()

      send(Keyword.fetch!(opts, :test_pid), {:heartbeat_result, heartbeat, item.lock_version})

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: true,
         default_branch: request.default_branch,
         refs: 0,
         bytes: 0
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule CancelRemote do
    import Ecto.Query

    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      run_id = Keyword.fetch!(opts, :run_id)

      {1, _rows} =
        Fornacast.Repo.update_all(
          Ecto.Query.from(run in ForgeImports.ImportRun, where: run.id == ^run_id),
          set: [state: :cancel_requested]
        )

      cancelled = Keyword.fetch!(opts, :cancel?).()
      send(Keyword.fetch!(opts, :test_pid), {:cancel_result, cancelled})

      if cancelled do
        {:error, %GitCore.Remote.Error{kind: :cancelled, detail: :durable_intent}}
      else
        {:ok,
         %GitCore.Remote.Result{
           path: request.destination,
           empty?: true,
           default_branch: request.default_branch,
           refs: 0,
           bytes: 0
         }}
      end
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule SuccessAfterCancelRemote do
    import Ecto.Query

    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      run_id = Keyword.fetch!(opts, :run_id)

      {1, _rows} =
        Fornacast.Repo.update_all(
          from(run in ForgeImports.ImportRun, where: run.id == ^run_id),
          set: [state: :cancel_requested]
        )

      send(Keyword.fetch!(opts, :test_pid), {:success_after_cancel, request.destination})

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: true,
         default_branch: request.default_branch,
         refs: 0,
         bytes: 0
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule CancelCleanupPendingRemote do
    import Ecto.Query

    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      run_id = Keyword.fetch!(opts, :run_id)

      {1, _rows} =
        Fornacast.Repo.update_all(
          from(run in ForgeImports.ImportRun, where: run.id == ^run_id),
          set: [state: :cancel_requested]
        )

      quarantine = cleanup_slot(request.destination)
      File.mkdir!(quarantine)
      File.chmod!(quarantine, 0o700)
      {:ok, evidence} = GitCore.Remote.cleanup_evidence(request.destination)
      send(Keyword.fetch!(opts, :test_pid), {:cancel_cleanup_pending, request.destination})

      {:error,
       %GitCore.Remote.Error{
         kind: :cleanup_pending,
         detail: %{evidence | original_kind: :cancelled}
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}

    defp cleanup_slot(destination) do
      digest =
        :sha256
        |> :crypto.hash("fornacast.git-core.remote.cleanup-slot.v1\0" <> destination)
        |> Base.url_encode64(padding: false)

      Path.join(Path.dirname(destination), ".fornacast-cleanup-v1-" <> digest)
    end
  end

  defmodule ClassifiedCleanupRemote do
    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      quarantine = cleanup_slot(request.destination)
      File.mkdir!(quarantine)
      File.chmod!(quarantine, 0o700)
      {:ok, evidence} = GitCore.Remote.cleanup_evidence(request.destination)

      {:error,
       %GitCore.Remote.Error{
         kind: :cleanup_pending,
         detail: %{evidence | original_kind: Keyword.fetch!(opts, :kind)}
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}

    defp cleanup_slot(destination) do
      digest =
        :sha256
        |> :crypto.hash("fornacast.git-core.remote.cleanup-slot.v1\0" <> destination)
        |> Base.url_encode64(padding: false)

      Path.join(Path.dirname(destination), ".fornacast-cleanup-v1-" <> digest)
    end
  end

  defmodule LostMirrorResultRemote do
    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      source = Keyword.fetch!(opts, :source)
      git = System.find_executable("git") || raise "git is required"
      {_output, 0} = System.cmd(git, ["clone", "--mirror", source, request.destination])
      File.chmod!(request.destination, 0o700)
      send(Keyword.fetch!(opts, :test_pid), {:lost_mirror_result, request.destination})
      {:error, %GitCore.Remote.Error{kind: :remote_unavailable, detail: :lost_result}}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule RefreshProbeRemote do
    def mirror(request, _pat, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:unexpected_mirror, request.destination})
      raise "unexpected second mirror"
    end

    def refresh(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      send(Keyword.fetch!(opts, :test_pid), {:refresh, request.destination})

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: false,
         default_branch: request.default_branch,
         refs: 1,
         bytes: 1_024
       }}
    end

    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule SerialRemote do
    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")
      state = Keyword.fetch!(opts, :state)

      call =
        Agent.get_and_update(state, fn current ->
          active = current.active + 1
          call = length(current.calls) + 1

          {call,
           %{
             current
             | active: active,
               max_active: max(current.max_active, active),
               calls: current.calls ++ [request.repository]
           }}
        end)

      send(Keyword.fetch!(opts, :test_pid), {:serial_remote_enter, call, self()})

      receive do
        {:continue_serial_remote, ^call} -> :ok
      after
        5_000 -> raise "serial remote was not released"
      end

      Agent.update(state, &%{&1 | active: &1.active - 1})

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: true,
         default_branch: request.default_branch,
         refs: 0,
         bytes: 0
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defmodule StealLeaseRemote do
    import Ecto.Query

    def mirror(request, pat, opts) do
      if pat != "github_pat_repository_worker_secret", do: raise("wrong credential")

      {1, _rows} =
        ForgeImports.RepositoryItem
        |> where([item], item.staged_storage_path == ^request.destination)
        |> Fornacast.Repo.update_all(
          set: [lease_owner: "stolen-owner"],
          inc: [lock_version: 1]
        )

      send(Keyword.fetch!(opts, :test_pid), :lease_stolen)

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: true,
         default_branch: request.default_branch,
         refs: 0,
         bytes: 0
       }}
    end

    def refresh(_request, _pat, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defp running_one_time_run_fixture(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 8_800_000_001,
        source_owner_login: "acme",
        source_repository_github_id: 9_800_000_001,
        source_repository_full_name: "acme/demo",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :running,
        selected_count: 1,
        request_metadata: %{}
      }
      |> Persistence.insert_run()
      |> unwrap!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        actor.id,
        identity.github_user_id,
        @pat,
        @keyring
      )

    ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap!()
  end

  defp queued_item_fixture(run, actor, overrides \\ []) do
    defaults = %{
      import_run_id: run.id,
      github_repository_id: 9_800_000_001,
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{
        "default_branch" => "main",
        "visibility" => "private",
        "description" => nil,
        "has_issues" => true,
        "allow_merge_commit" => true,
        "fork" => false,
        "archived" => false
      },
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_slug: "demo",
      destination_visibility: :private,
      state: :queued,
      attempt_count: 1
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Persistence.insert_repository_item()
    |> unwrap!()
  end

  defp new_organization_fixture(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 8_800_000_011,
        source_owner_login: "github-tools",
        source_metadata: %{
          "name" => "Imported Tools",
          "description" => "GitHub organization",
          "observed_at" => DateTime.to_iso8601(@now)
        },
        destination_organization_action: :new,
        destination_organization_slug: "imported-tools",
        destination_organization_status: :clean,
        state: :running,
        selected_count: 2,
        request_metadata: %{}
      }
      |> Persistence.insert_run()
      |> unwrap!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        actor.id,
        identity.github_user_id,
        @pat,
        @keyring
      )

    run = ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap!()

    item = new_organization_item(run, 9_800_000_011, "alpha")
    sibling = new_organization_item(run, 9_800_000_012, "beta")
    attempt_fixture(item)
    attempt_fixture(sibling)
    {run, item, sibling}
  end

  defp saved_run_fixture(actor, identity) do
    credential = saved_credential_fixture(actor, identity)

    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :saved,
        github_credential_id: credential.id,
        source_owner_github_id: 8_800_000_021,
        source_owner_login: "acme",
        source_repository_github_id: 9_800_000_021,
        source_repository_full_name: "acme/demo",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :running,
        selected_count: 1,
        request_metadata: %{}
      }
      |> Persistence.insert_run()
      |> unwrap!()

    item = queued_item_fixture(run, actor)
    attempt_fixture(item)
    {run, item, credential}
  end

  defp saved_credential_fixture(actor, identity) do
    placeholder =
      %GitHubCredential{}
      |> GitHubCredential.changeset(%{
        local_user_id: actor.id,
        github_identity_id: identity.id,
        ciphertext: <<1>>,
        nonce: :binary.copy(<<2>>, 12),
        tag: :binary.copy(<<3>>, 16),
        key_id: "test-2026-08-25",
        status: :valid,
        last_verified_at: @now
      })
      |> Repo.insert!()

    keyring = Application.fetch_env!(:fornacast, :github_credential_keyring)

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_saved(
        placeholder,
        identity,
        @pat,
        keyring
      )

    {1, _rows} =
      Repo.update_all(
        from(credential in GitHubCredential, where: credential.id == ^placeholder.id),
        set: [
          ciphertext: envelope.ciphertext,
          nonce: envelope.nonce,
          tag: envelope.tag,
          key_id: envelope.key_id
        ]
      )

    Repo.get!(GitHubCredential, placeholder.id)
  end

  defp new_organization_item(run, github_repository_id, slug) do
    %{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "github-tools/#{slug}",
      source_name: slug,
      source_metadata: %{
        "default_branch" => "main",
        "visibility" => "private",
        "has_issues" => true,
        "allow_merge_commit" => true,
        "fork" => false,
        "archived" => false
      },
      source_observed_at: @now,
      selected: true,
      destination_owner_id: nil,
      destination_slug: slug,
      destination_visibility: :private,
      state: :queued,
      attempt_count: 1
    }
    |> Persistence.insert_repository_item()
    |> unwrap!()
  end

  defp assert_activation_failure_deferred(item, sibling) do
    assert %RepositoryItem{
             destination_owner_id: nil,
             hidden_repository_id: nil,
             staged_storage_path: nil,
             failure_kind: "destination_changed",
             next_attempt_at: %DateTime{},
             lease_owner: nil,
             lease_expires_at: nil,
             lock_version: item_version
           } = Repo.get!(RepositoryItem, item.id)

    assert item_version == item.lock_version + 1

    assert %RepositoryItem{
             destination_owner_id: nil,
             hidden_repository_id: nil,
             staged_storage_path: nil,
             failure_kind: nil,
             next_attempt_at: nil,
             lease_owner: nil,
             lease_expires_at: nil,
             lock_version: sibling_version
           } = Repo.get!(RepositoryItem, sibling.id)

    assert sibling_version == sibling.lock_version
  end

  defp attempt_fixture(item) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{"action" => "create", "slug" => item.destination_slug},
      started_at: @now
    })
    |> Repo.insert!()
  end

  defp replace_attempt_fixture(item, target) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{
        "action" => "replace",
        "slug" => item.destination_slug,
        "replacement_repository_id" => target.id,
        "replacement_owner_id" => target.owner_user_id,
        "replacement_storage_path" => target.storage_path,
        "replacement_generation" => target.generation,
        "replacement_write_version" => target.write_version,
        "replacement_updated_at" => target.updated_at,
        "replacement_last_pushed_at" => target.last_pushed_at
      },
      started_at: @now
    })
    |> Repo.insert!()
  end

  defp identity_fixture(actor) do
    suffix = System.unique_integer([:positive])

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: 8_900_000_000 + suffix,
          login: "repository-worker-#{suffix}",
          avatar_url: nil,
          profile_url: nil
        },
        @now
      )

    ForgeAccounts.link_github_identity(actor, identity) |> unwrap!()
  end

  defp create_cleanup_slot!(destination) do
    digest =
      :sha256
      |> :crypto.hash("fornacast.git-core.remote.cleanup-slot.v1\0" <> destination)
      |> Base.url_encode64(padding: false)

    quarantine = Path.join(Path.dirname(destination), ".fornacast-cleanup-v1-" <> digest)
    File.mkdir!(quarantine)
    File.chmod!(quarantine, 0o700)
    quarantine
  end

  defp repository_with_unsupported_git!(tmp_dir) do
    work = Path.join(tmp_dir, "unsupported-work")
    bare = Path.join(tmp_dir, "unsupported-source.git")
    File.mkdir!(work)
    git!(["init", "--initial-branch=main"], work)
    git!(["config", "user.name", "Fornacast Test"], work)
    git!(["config", "user.email", "fornacast@example.test"], work)

    File.write!(Path.join(work, ".gitattributes"), "*.bin filter=lfs diff=lfs merge=lfs -text\n")

    File.write!(
      Path.join(work, "asset.bin"),
      "version https://git-lfs.github.com/spec/v1\n" <>
        "oid sha256:#{String.duplicate("a", 64)}\nsize 42\n"
    )

    File.write!(
      Path.join(work, ".gitmodules"),
      "[submodule \"dependency\"]\n\tpath = dependency\n\turl = https://github.com/acme/dependency.git\n"
    )

    git!(["add", ".gitattributes", ".gitmodules", "asset.bin"], work)
    git!(["commit", "-m", "unsupported fixtures"], work)
    git!(["clone", "--bare", work, bare], tmp_dir)
    bare
  end

  defp write_blocking_remote_git!(tmp_dir) do
    git = Path.join(tmp_dir, "blocking-remote-git")
    real_git = System.find_executable("git") || raise "git is required"
    shell = System.find_executable("sh") || raise "sh is required"
    sleep = System.find_executable("sleep") || raise "sleep is required"
    child_pid = Path.join(tmp_dir, "remote-child.pid")
    argv_log = Path.join(tmp_dir, "remote-argv.log")

    File.write!(git, """
    #!#{shell}
    set -eu
    for argument in "$@"; do printf 'ARG=%s\n' "$argument"; done >> #{shell_quote(argv_log)}

    case "${1-}" in
      credential-cache|credential-cache--daemon)
        exec #{shell_quote(real_git)} "$@"
        ;;
    esac

    command_name=""
    for argument in "$@"; do
      if [ "$argument" = "clone" ]; then command_name="clone"; fi
    done

    if [ "$command_name" = "clone" ]; then
      #{shell_quote(sleep)} 300 &
      child=$!
      printf '%s' "$child" > #{shell_quote(child_pid)}
      wait "$child"
    fi

    exit 1
    """)

    File.chmod!(git, 0o700)
    %{git: git, child_pid: child_pid, argv_log: argv_log}
  end

  defp git!(args, directory) do
    git = System.find_executable("git") || raise "git is required"
    {output, status} = System.cmd(git, args, cd: directory, stderr_to_stdout: true)
    if status != 0, do: raise("git failed: #{output}")
    output
  end

  defp os_process_alive?(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {integer, ""} when integer > 0 -> File.dir?("/proc/#{integer}")
      _invalid -> false
    end
  end

  defp occurrences(value, pattern), do: length(:binary.matches(value, pattern))

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp public_resolver do
    fn
      "github.com", :a -> [{140, 82, 121, 3}]
      "github.com", :aaaa -> [{0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154}]
    end
  end

  defp next_github_id, do: 9_900_000_000 + System.unique_integer([:positive])

  defp make_item_due!(item_id) do
    assert {1, _rows} =
             Repo.update_all(
               from(item in RepositoryItem, where: item.id == ^item_id),
               set: [next_attempt_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
             )

    :ok
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    ForgeAccounts.create_user(%{
      username: "repository-worker-#{suffix}",
      email: "repository-worker-#{suffix}@example.test",
      password: "correct horse battery staple"
    })
    |> unwrap!()
  end

  defp unwrap!({:ok, value}), do: value

  defp reset_database! do
    for table <- [
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

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp turso?, do: not postgres?()
end
