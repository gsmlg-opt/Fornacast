defmodule ForgeRepos.GitWriteRecoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeRepos.{GitWriteOperation, GitWriteRecovery, Repository}
  alias Fornacast.{AuditEvent, OperationLease, Repo}

  setup context do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      for table <- ~w(git_write_operations audit_events repositories users) do
        Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
      end
    end

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, context.tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    owner =
      Repo.insert!(%User{
        username: "recovery-#{System.unique_integer([:positive])}",
        email: "recovery-#{System.unique_integer([:positive])}@example.com",
        password_hash: "unused",
        kind: :user,
        state: :active
      })

    repository =
      %Repository{owner_user_id: owner.id, storage_path: "@test/#{owner.id}/recovery.git"}
      |> Repository.create_changeset(%{name: "Recovery", slug: "recovery"})
      |> Repo.insert!()

    path = ForgeRepos.absolute_storage_path(repository)
    File.mkdir_p!(Path.dirname(path))
    {:ok, _path} = GitCore.init_bare(path)
    {expected_oid, proposed_oid, third_oid} = create_commits(path)

    {:ok,
     owner: owner,
     repository: repository,
     path: path,
     expected_oid: expected_oid,
     proposed_oid: proposed_oid,
     third_oid: third_oid}
  end

  @moduletag :tmp_dir

  test "expected refs terminally fail prepared and object-written operations", context do
    update_ref(context.path, context.expected_oid)

    prepared = operation!(context, :prepared)
    object_written = operation!(context, :object_written, request_id: "object-written")

    assert :ok = locked_reconcile(context)
    assert Repo.get!(GitWriteOperation, prepared.id).failure_reason == "effect_not_started"
    assert Repo.get!(GitWriteOperation, object_written.id).failure_reason == "ref_not_advanced"
  end

  test "expected absence matches only a missing ref", context do
    operation = operation!(context, :prepared, expected_oid: nil)

    assert :ok = locked_reconcile(context)

    assert %{state: :failed, failure_reason: "effect_not_started"} =
             Repo.get!(GitWriteOperation, operation.id)
  end

  test "proposed refs atomically complete bookkeeping and deduplicated audit", context do
    update_ref(context.path, context.proposed_oid)
    operation = operation!(context, :ref_advanced)

    assert :ok = locked_reconcile(context)

    assert %{state: :bookkeeping_complete, lease_owner: nil} =
             Repo.get!(GitWriteOperation, operation.id)

    assert %Repository{last_pushed_at: %DateTime{}} = Repo.get!(Repository, context.repository.id)

    assert [%AuditEvent{action: "git.ref.updated"}] =
             Repo.all(
               from audit in AuditEvent, where: audit.operation_id == ^"git_write:#{operation.id}"
             )
  end

  test "same-second multi-ref completions advance the monotonic write version", context do
    completed_at = ~U[2026-08-27 01:45:00Z]
    first_ref = "refs/heads/same-second-first"
    second_ref = "refs/heads/same-second-second"
    update_ref(context.path, context.proposed_oid, first_ref)
    update_ref(context.path, context.proposed_oid, second_ref)

    first =
      operation!(context, :ref_advanced,
        kind: :receive_pack,
        actor_user_id: context.owner.id,
        request_id: "same-second-receive",
        target_ref: first_ref
      )

    second =
      operation!(context, :ref_advanced,
        kind: :receive_pack,
        actor_user_id: context.owner.id,
        request_id: "same-second-receive",
        target_ref: second_ref
      )

    assert :ok =
             GitWriteRecovery.with_test_completion_clock(
               fn -> completed_at end,
               fn -> locked_reconcile(context) end
             )

    assert Repo.get!(GitWriteOperation, first.id).state == :bookkeeping_complete
    assert Repo.get!(GitWriteOperation, second.id).state == :bookkeeping_complete

    assert %Repository{
             write_version: 2,
             last_pushed_at: ^completed_at,
             updated_at: ^completed_at
           } = Repo.get!(Repository, context.repository.id)
  end

  test "prepared receive-pack refs reconcile proposed and expected outcomes idempotently",
       context do
    proposed_ref = "refs/heads/receive-proposed"
    expected_ref = "refs/heads/receive-expected"
    update_ref(context.path, context.proposed_oid, proposed_ref)
    update_ref(context.path, context.expected_oid, expected_ref)

    proposed =
      operation!(context, :prepared,
        kind: :receive_pack,
        actor_user_id: context.owner.id,
        request_id: "receive-recovery",
        target_ref: proposed_ref
      )

    expected =
      operation!(context, :prepared,
        kind: :receive_pack,
        actor_user_id: context.owner.id,
        request_id: "receive-recovery",
        target_ref: expected_ref
      )

    assert :ok = locked_reconcile(context)
    assert :ok = locked_reconcile(context)

    assert Repo.get!(GitWriteOperation, proposed.id).state == :bookkeeping_complete

    assert %GitWriteOperation{state: :failed, failure_reason: "effect_not_started"} =
             Repo.get!(GitWriteOperation, expected.id)

    assert [
             %AuditEvent{
               action: "repository.pushed",
               actor_user_id: actor_id,
               request_id: "receive-recovery",
               operation_id: operation_id
             }
           ] = Repo.all(AuditEvent)

    assert actor_id == context.owner.id
    assert operation_id == "git_write:#{proposed.id}"
  end

  test "public recovery reloads the exact repository instead of trusting a hostile path",
       context do
    update_ref(context.path, context.proposed_oid)
    operation = operation!(context, :ref_advanced)
    hostile = %{context.repository | storage_path: "../hostile.git"}

    assert :ok = GitWriteRecovery.reconcile_repository(hostile)
    assert Repo.get!(GitWriteOperation, operation.id).state == :bookkeeping_complete
  end

  test "public recovery rejects generation drift before reading repository storage", context do
    update_ref(context.path, context.third_oid)
    operation = operation!(context, :ref_advanced)

    assert {1, nil} =
             Repo.update_all(
               from(candidate in Repository, where: candidate.id == ^context.repository.id),
               set: [generation: context.repository.generation + 1]
             )

    assert {:error, {:unavailable, :git_write_recovery}} =
             GitWriteRecovery.reconcile_repository(context.repository)

    assert %GitWriteOperation{state: :ref_advanced, failure_reason: nil} =
             Repo.get!(GitWriteOperation, operation.id)

    assert %Repository{last_pushed_at: nil, write_version: 0} =
             Repo.get!(Repository, context.repository.id)

    refute Repo.get_by(AuditEvent, operation_id: "git_write:#{operation.id}")
  end

  test "third refs stay nonterminal, alert once, and block every retry", context do
    update_ref(context.path, context.third_oid)
    operation = operation!(context, :ref_advanced)
    before_snapshot = git_snapshot(context.path)

    assert {:error, :unavailable} = locked_reconcile(context)
    assert {:error, :unavailable} = locked_reconcile(context)

    assert %{state: :ref_advanced, failure_reason: "unexpected_ref", lease_owner: nil} =
             Repo.get!(GitWriteOperation, operation.id)

    assert git_snapshot(context.path) == before_snapshot

    assert 1 ==
             Repo.aggregate(
               from(audit in AuditEvent,
                 where:
                   audit.operation_id == ^"git_write:#{operation.id}" and
                     audit.action == "git.write.recovery_blocked"
               ),
               :count,
               :id
             )
  end

  test "an older live lease blocks every later row until it is released",
       context do
    update_ref(context.path, context.expected_oid)
    live = operation!(context, :prepared, request_id: "live")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:ok, claimed_live} = OperationLease.claim(GitWriteOperation, live.id, "live", now, 30)

    proposed_ref = "refs/heads/proposed"
    expected_ref = "refs/heads/expected"
    expired_ref = "refs/heads/expired"
    update_ref(context.path, context.proposed_oid, proposed_ref)
    update_ref(context.path, context.expected_oid, expected_ref)
    update_ref(context.path, context.expected_oid, expired_ref)

    proposed =
      operation!(context, :ref_advanced,
        request_id: "proposed",
        target_ref: proposed_ref
      )

    expected =
      operation!(context, :prepared,
        request_id: "expected",
        target_ref: expected_ref
      )

    expired =
      operation!(context, :prepared,
        request_id: "expired",
        target_ref: expired_ref
      )

    assert {:ok, _expired_claim} =
             OperationLease.claim(
               GitWriteOperation,
               expired.id,
               "expired",
               DateTime.add(now, -60, :second),
               5
             )

    assert {:error, :unavailable} = locked_reconcile(context)

    assert %{state: :prepared, lease_owner: "live"} = Repo.get!(GitWriteOperation, live.id)
    assert Repo.get!(GitWriteOperation, proposed.id).state == :ref_advanced
    assert Repo.get!(GitWriteOperation, expected.id).state == :prepared
    assert Repo.get!(GitWriteOperation, expired.id).state == :prepared

    assert :ok = OperationLease.release(GitWriteOperation, claimed_live)
    assert :ok = locked_reconcile(context)

    assert Repo.get!(GitWriteOperation, proposed.id).state == :bookkeeping_complete

    for operation <- [live, expected, expired] do
      assert %{state: :failed, failure_reason: "effect_not_started", lease_owner: nil} =
               Repo.get!(GitWriteOperation, operation.id)
    end
  end

  test "a claim race fails closed without advancing to later rows", context do
    update_ref(context.path, context.expected_oid)
    raced = operation!(context, :prepared, request_id: "raced")
    later_ref = "refs/heads/later"
    update_ref(context.path, context.expected_oid, later_ref)

    later =
      operation!(context, :prepared,
        request_id: "later",
        target_ref: later_ref
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      OperationLease.with_test_after_write_hook(
        fn :claim, GitWriteOperation, id, _version ->
          Repo.update_all(from(item in GitWriteOperation, where: item.id == ^id),
            set: [lease_expires_at: DateTime.add(now, -1, :second)]
          )

          assert {:ok, _stolen} =
                   OperationLease.claim(GitWriteOperation, id, "stolen", now, 30)
        end,
        fn -> locked_reconcile(context) end
      )

    assert {:error, :unavailable} = result

    assert %{state: :prepared, lease_owner: "stolen"} =
             stolen =
             Repo.get!(GitWriteOperation, raced.id)

    assert %{state: :prepared, failure_reason: nil, lease_owner: nil} =
             Repo.get!(GitWriteOperation, later.id)

    assert :ok = OperationLease.release(GitWriteOperation, stolen)
    assert :ok = locked_reconcile(context)

    for operation <- [raced, later] do
      assert %{state: :failed, failure_reason: "effect_not_started"} =
               Repo.get!(GitWriteOperation, operation.id)
    end
  end

  test "each cursor iteration shares a fresh wall clock between selection and claim", context do
    first_ref = "refs/heads/clock-first"
    second_ref = "refs/heads/clock-second"
    update_ref(context.path, context.expected_oid, first_ref)
    update_ref(context.path, context.expected_oid, second_ref)

    first =
      operation!(context, :prepared,
        request_id: "clock-first",
        target_ref: first_ref
      )

    second =
      operation!(context, :prepared,
        request_id: "clock-second",
        target_ref: second_ref
      )

    first_now = ~U[2026-08-09 04:00:00Z]
    second_now = DateTime.add(first_now, 31, :second)

    Repo.update_all(from(item in GitWriteOperation, where: item.id == ^second.id),
      set: [lease_owner: "aging", lease_expires_at: DateTime.add(first_now, 20, :second)]
    )

    counter = :counters.new(1, [])

    clock = fn ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> first_now
        _later -> second_now
      end
    end

    test_pid = self()

    claim_observer = fn claimed, iteration_now ->
      send(test_pid, {:claimed, claimed.id, iteration_now, claimed.lease_expires_at})
    end

    assert :ok =
             GitWriteRecovery.with_test_iteration_clock(clock, claim_observer, fn ->
               locked_reconcile(context)
             end)

    assert_receive {:claimed, first_id, ^first_now, first_expires_at}
    assert first_id == first.id
    assert first_expires_at == DateTime.add(first_now, 30, :second)

    assert_receive {:claimed, second_id, ^second_now, second_expires_at}
    assert second_id == second.id
    assert second_expires_at == DateTime.add(second_now, 30, :second)

    assert Repo.get!(GitWriteOperation, first.id).state == :failed
    assert Repo.get!(GitWriteOperation, second.id).state == :failed
  end

  test "SQL failure after proposed evidence rolls back bookkeeping and remains recoverable",
       context do
    update_ref(context.path, context.proposed_oid)
    operation = operation!(context, :ref_advanced)
    cache_key = {context.path, :recovery_sql_failure}
    assert {:ok, :cached} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :cached} end)

    assert {:error, :unavailable} =
             GitWriteRecovery.with_test_complete_multi_hook(
               fn multi, _operation ->
                 Ecto.Multi.run(multi, :forced_sql_failure, fn repo, _changes ->
                   case Ecto.Adapters.SQL.query(
                          repo,
                          "select * from git_write_recovery_missing_table",
                          []
                        ) do
                     {:error, _error} -> {:error, :forced_sql_failure}
                   end
                 end)
               end,
               fn -> locked_reconcile(context) end
             )

    assert %{state: :ref_advanced, lease_owner: nil} =
             Repo.get!(GitWriteOperation, operation.id)

    assert %Repository{last_pushed_at: nil, write_version: 0} =
             Repo.get!(Repository, context.repository.id)

    assert Repo.aggregate(AuditEvent, :count, :id) == 0

    assert {:ok, :cached} =
             GitCore.Cache.fetch(cache_key, fn ->
               flunk("failed transaction invalidated cache")
             end)

    assert :ok = locked_reconcile(context)
    assert Repo.get!(GitWriteOperation, operation.id).state == :bookkeeping_complete
    assert {:ok, :refreshed} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :refreshed} end)
  end

  test "completion rejects repository generation, lifecycle, and deletion drift atomically",
       context do
    for {suffix, updates} <- [
          {"generation", [generation: context.repository.generation + 1]},
          {"lifecycle", [lifecycle: :tombstoned]},
          {"deletion", [deleted_at: ~U[2026-08-26 00:00:00Z]]}
        ] do
      target_ref = "refs/heads/drift-#{suffix}"
      update_ref(context.path, context.proposed_oid, target_ref)

      operation =
        operation!(context, :ref_advanced,
          request_id: "drift-#{suffix}",
          target_ref: target_ref
        )

      assert {:error, :unavailable} =
               GitWriteRecovery.with_test_complete_multi_hook(
                 fn multi, _operation ->
                   prepend_repository_drift(multi, context.repository, updates)
                 end,
                 fn -> locked_reconcile(context) end
               )

      assert %GitWriteOperation{state: :ref_advanced, lease_owner: nil} =
               Repo.get!(GitWriteOperation, operation.id)

      assert %Repository{
               generation: generation,
               lifecycle: :ready,
               deleted_at: nil,
               last_pushed_at: nil
             } = Repo.get!(Repository, context.repository.id)

      assert generation == context.repository.generation
      refute Repo.get_by(AuditEvent, operation_id: "git_write:#{operation.id}")
    end
  end

  test "on-touch fence clears expected evidence before callback and blocks third evidence",
       context do
    original = Application.get_env(:forge_repos, :repository_write_reconcilers)

    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {100, :git_writes, GitWriteRecovery}
    ])

    on_exit(fn -> Application.put_env(:forge_repos, :repository_write_reconcilers, original) end)
    update_ref(context.path, context.expected_oid)
    cleared = operation!(context, :prepared, request_id: "fence-cleared")

    assert :entered =
             ForgeRepos.with_write_fence(context.repository, :ref, fn path, remaining ->
               assert path == context.path
               assert remaining > 0
               :entered
             end)

    assert Repo.get!(GitWriteOperation, cleared.id).state == :failed

    blocked = operation!(context, :ref_advanced, request_id: "fence-blocked")
    update_ref(context.path, context.third_oid)

    assert {:error, {:unavailable, :write_fence}} =
             ForgeRepos.with_write_fence(context.repository, :ref, fn _path, _remaining ->
               flunk("blocked fence invoked new write")
             end)

    assert Repo.get!(GitWriteOperation, blocked.id).failure_reason == "unexpected_ref"
  end

  test "on-touch fence blocks on the earliest live lease until it expires", context do
    original = Application.get_env(:forge_repos, :repository_write_reconcilers)

    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {100, :git_writes, GitWriteRecovery}
    ])

    on_exit(fn -> Application.put_env(:forge_repos, :repository_write_reconcilers, original) end)
    update_ref(context.path, context.expected_oid)
    live = operation!(context, :prepared, request_id: "live-fence")
    later_ref = "refs/heads/live-fence-later"
    update_ref(context.path, context.expected_oid, later_ref)
    later = operation!(context, :prepared, request_id: "live-fence-later", target_ref: later_ref)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:ok, _claimed} = OperationLease.claim(GitWriteOperation, live.id, "crashed", now, 30)

    assert {:error, {:unavailable, :write_fence}} =
             ForgeRepos.with_write_fence(context.repository, :ref, fn _path, _remaining ->
               flunk("live durable operation allowed a new writer")
             end)

    assert %GitWriteOperation{state: :prepared, lease_owner: "crashed"} =
             Repo.get!(GitWriteOperation, live.id)

    assert %GitWriteOperation{state: :prepared, lease_owner: nil} =
             Repo.get!(GitWriteOperation, later.id)

    assert {1, nil} =
             Repo.update_all(
               from(operation in GitWriteOperation, where: operation.id == ^live.id),
               set: [lease_expires_at: DateTime.add(now, -1, :second)]
             )

    assert :entered =
             ForgeRepos.with_write_fence(context.repository, :ref, fn _path, _remaining ->
               :entered
             end)

    for operation <- [live, later] do
      assert %GitWriteOperation{state: :failed, failure_reason: "effect_not_started"} =
               Repo.get!(GitWriteOperation, operation.id)
    end
  end

  defp locked_reconcile(context) do
    GitWriteRecovery.reconcile_repository_locked(
      context.repository,
      context.path,
      System.monotonic_time(:millisecond) + 10_000
    )
  end

  defp operation!(context, state, overrides \\ []) do
    attrs = %{
      repository_id: context.repository.id,
      actor_user_id: Keyword.get(overrides, :actor_user_id),
      request_id:
        Keyword.get(overrides, :request_id, "request-#{System.unique_integer([:positive])}"),
      kind: Keyword.get(overrides, :kind, :ref_update),
      state: state,
      target_ref: Keyword.get(overrides, :target_ref, "refs/heads/main"),
      expected_oid: Keyword.get(overrides, :expected_oid, context.expected_oid),
      proposed_oid: context.proposed_oid,
      result_blob_oid: nil,
      failure_reason: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      lock_version: 0
    }

    %GitWriteOperation{}
    |> GitWriteOperation.changeset(attrs)
    |> Repo.insert!()
  end

  defp prepend_repository_drift(multi, repository, updates) do
    drift =
      Ecto.Multi.new()
      |> Ecto.Multi.update_all(
        :repository_drift,
        from(candidate in Repository, where: candidate.id == ^repository.id),
        set: updates
      )

    Ecto.Multi.prepend(multi, drift)
  end

  defp create_commits(path) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    first = git!(path, ["commit-tree", tree, "-m", "expected"])
    second = git!(path, ["commit-tree", tree, "-p", first, "-m", "proposed"])
    third = git!(path, ["commit-tree", tree, "-p", first, "-m", "third"])
    {first, second, third}
  end

  defp update_ref(path, oid, ref \\ "refs/heads/main"), do: git!(path, ["update-ref", ref, oid])

  defp git_snapshot(path) do
    {git!(path, ["for-each-ref", "--format=%(refname) %(objectname)"]),
     git!(path, ["count-objects", "-v"])}
  end

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Recovery Test"},
      {"GIT_AUTHOR_EMAIL", "recovery@example.com"},
      {"GIT_COMMITTER_NAME", "Recovery Test"},
      {"GIT_COMMITTER_EMAIL", "recovery@example.com"}
    ]

    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args],
        env: env,
        stderr_to_stdout: true
      )

    String.trim(output)
  end
end
