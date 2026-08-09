defmodule ForgePulls.MergeRecoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, MergeReconciler, MergeRecovery, PullRequest}
  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, OperationLease, Repo}

  setup do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    end

    owner = user_fixture()
    {:ok, recovery_fixture(owner)}
  end

  defp recovery_fixture(owner) do
    repository = repository_fixture(owner)
    path = ForgeRepos.absolute_storage_path(repository)
    {base_oid, head_oid, merge_oid, third_oid} = create_merge_graph(path)

    assert {:ok, pull} =
             ForgePulls.create_pull_request(
               repository,
               owner,
               %{title: "Recover merge", head: "feature", base: "main"},
               %{request_id: unique("create")}
             )

    operation =
      %MergeOperation{}
      |> MergeOperation.prepare_changeset(%{
        pull_request_id: pull.id,
        repository_id: repository.id,
        actor_user_id: owner.id,
        request_id: unique("merge"),
        api_version: "2026-03-10",
        ip_address: "203.0.113.9",
        user_agent: "merge-recovery-test/1.0",
        token_id: "token-recovery",
        base_ref: pull.base_ref,
        head_ref: pull.head_ref,
        expected_base_oid: base_oid,
        expected_head_oid: head_oid,
        state: :prepared
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(state: :merge_written, merge_oid: merge_oid)
      |> Repo.update!()
      |> Ecto.Changeset.change(state: :ref_advanced)
      |> Repo.update!()

    update_ref(path, merge_oid, pull.base_ref)

    %{
      owner: owner,
      repository: repository,
      path: path,
      pull: pull,
      operation: operation,
      merge_oid: merge_oid,
      third_oid: third_oid
    }
  end

  test "proven ref advancement completes pull, issue, repository, audit, and cache atomically",
       context do
    cache_key = {context.path, :pull_merge_recovery}
    assert {:ok, :cached} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :cached} end)

    deadline = System.monotonic_time(:millisecond) + 10_000

    assert [
             {100, :git_writes, ForgeRepos.GitWriteRecovery},
             {200, :pull_merges, MergeRecovery}
           ] = ForgeRepos.RepositoryWriteReconcilers.entries()

    assert {:ok, writer_lease} =
             GitCore.RepositoryWriteLimiter.acquire(context.repository.id, deadline)

    try do
      assert :ok =
               MergeRecovery.reconcile_repository_locked(
                 context.repository,
                 context.path,
                 deadline
               )
    after
      GitCore.RepositoryWriteLimiter.release(writer_lease)
    end

    assert %MergeOperation{state: :completed, lease_owner: nil} =
             Repo.get!(MergeOperation, context.operation.id)

    assert %PullRequest{
             merge_commit_sha: merge_oid,
             merged_by_user_id: merged_by_user_id,
             merged_at: %DateTime{}
           } = Repo.get!(PullRequest, context.pull.id)

    assert merge_oid == context.merge_oid
    assert merged_by_user_id == context.owner.id

    assert %Issue{state: :closed, state_reason: :completed, closed_at: %DateTime{}} =
             Repo.get!(Issue, context.pull.issue_id)

    assert {:ok,
            %PullRequest{
              issue: %Issue{state: :closed, state_reason: :completed, closed_at: %DateTime{}}
            }} =
             ForgePulls.get_pull_request(
               context.repository,
               context.pull.issue.number,
               context.owner
             )

    assert %Repository{last_pushed_at: %DateTime{}} = Repo.get!(Repository, context.repository.id)

    assert [
             %AuditEvent{
               action: "pull_request.merged",
               actor_user_id: actor_user_id,
               request_id: request_id,
               ip_address: "203.0.113.9",
               user_agent: "merge-recovery-test/1.0",
               metadata: audit_metadata
             }
           ] =
             Repo.all(
               from event in AuditEvent,
                 where: event.operation_id == ^"pull_merge:#{context.operation.id}"
             )

    assert actor_user_id == context.owner.id
    assert request_id == context.operation.request_id
    assert audit_metadata["api_version"] == "2026-03-10"
    assert audit_metadata["token_id"] == "token-recovery"
    assert {:ok, :refreshed} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :refreshed} end)
  end

  test "reading a pull synchronously reconciles its proven nonterminal merge", context do
    assert {:ok,
            %PullRequest{
              merge_commit_sha: merge_oid,
              issue: %Issue{state: :closed, state_reason: :completed}
            }} =
             ForgePulls.get_pull_request(
               context.repository,
               context.pull.issue.number,
               context.owner
             )

    assert merge_oid == context.merge_oid
    assert Repo.get!(MergeOperation, context.operation.id).state == :completed
  end

  test "completion SQL failure rolls back every canonical field and remains recoverable",
       context do
    cache_key = {context.path, :pull_merge_rollback}
    assert {:ok, :cached} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :cached} end)

    assert {:error, :unavailable} =
             MergeRecovery.with_test_complete_multi_hook(
               fn multi, _operation ->
                 Ecto.Multi.run(multi, :forced_failure, fn repo, _changes ->
                   case Ecto.Adapters.SQL.query(
                          repo,
                          "select * from pull_merge_recovery_missing_table",
                          []
                        ) do
                     {:error, _error} -> {:error, :forced_failure}
                   end
                 end)
               end,
               fn ->
                 MergeRecovery.reconcile_repository_locked(
                   context.repository,
                   context.path,
                   System.monotonic_time(:millisecond) + 10_000
                 )
               end
             )

    assert %MergeOperation{state: :ref_advanced, lease_owner: nil} =
             Repo.get!(MergeOperation, context.operation.id)

    assert %PullRequest{merge_commit_sha: nil, merged_at: nil, merged_by_user_id: nil} =
             Repo.get!(PullRequest, context.pull.id)

    assert %Issue{state: :open} = Repo.get!(Issue, context.pull.issue_id)
    assert %Repository{last_pushed_at: nil} = Repo.get!(Repository, context.repository.id)
    refute Repo.get_by(AuditEvent, operation_id: "pull_merge:#{context.operation.id}")

    assert {:ok, :cached} =
             GitCore.Cache.fetch(cache_key, fn ->
               flunk("failed transaction invalidated cache")
             end)

    assert :ok =
             MergeRecovery.reconcile_repository_locked(
               context.repository,
               context.path,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert Repo.get!(MergeOperation, context.operation.id).state == :completed
  end

  test "completion fails closed when canonical pull refs no longer match recorded evidence",
       context do
    context.pull
    |> Ecto.Changeset.change(base_ref: "refs/heads/release")
    |> Repo.update!()

    assert {:error, :unavailable} =
             MergeRecovery.reconcile_repository_locked(
               context.repository,
               context.path,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert %MergeOperation{state: :ref_advanced, lease_owner: nil} =
             Repo.get!(MergeOperation, context.operation.id)

    assert %PullRequest{base_ref: "refs/heads/release", merge_commit_sha: nil} =
             Repo.get!(PullRequest, context.pull.id)

    assert %Issue{state: :open} = Repo.get!(Issue, context.pull.issue_id)
    refute Repo.get_by(AuditEvent, operation_id: "pull_merge:#{context.operation.id}")
  end

  test "proven ref advancement completes when the canonical pull issue is already closed",
       context do
    context.pull.issue_id
    |> then(&Repo.get!(Issue, &1))
    |> Issue.update_changeset(%{state: :closed, state_reason: :not_planned})
    |> Repo.update!()

    assert :ok =
             MergeRecovery.reconcile_repository_locked(
               context.repository,
               context.path,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert %MergeOperation{state: :completed, lease_owner: nil} =
             Repo.get!(MergeOperation, context.operation.id)

    assert %PullRequest{merge_commit_sha: merge_oid} = Repo.get!(PullRequest, context.pull.id)
    assert merge_oid == context.merge_oid

    assert %Issue{state: :closed, state_reason: :completed} =
             Repo.get!(Issue, context.pull.issue_id)

    assert %AuditEvent{action: "pull_request.merged"} =
             Repo.get_by!(AuditEvent, operation_id: "pull_merge:#{context.operation.id}")
  end

  test "a closed issue remains fail-closed when the merge ref was not advanced", context do
    Repo.update_all(
      from(operation in MergeOperation, where: operation.id == ^context.operation.id),
      set: [state: :merge_written]
    )

    update_ref(context.path, context.operation.expected_base_oid, context.operation.base_ref)

    context.pull.issue_id
    |> then(&Repo.get!(Issue, &1))
    |> Issue.update_changeset(%{state: :closed, state_reason: :not_planned})
    |> Repo.update!()

    assert :ok =
             MergeRecovery.reconcile_repository_locked(
               context.repository,
               context.path,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert %MergeOperation{state: :failed, failure_reason: "ref_not_advanced"} =
             Repo.get!(MergeOperation, context.operation.id)

    assert %PullRequest{merge_commit_sha: nil} = Repo.get!(PullRequest, context.pull.id)

    assert %Issue{state: :closed, state_reason: :not_planned} =
             Repo.get!(Issue, context.pull.issue_id)

    refute Repo.get_by(AuditEvent, operation_id: "pull_merge:#{context.operation.id}")
  end

  test "a third base OID retains evidence, alerts once, and blocks every retry", context do
    update_ref(context.path, context.third_oid, context.operation.base_ref)
    before_refs = git!(context.path, ["for-each-ref", "--format=%(refname) %(objectname)"])

    assert {:error, :unavailable} = locked_reconcile(context)
    assert {:error, :unavailable} = locked_reconcile(context)

    assert %MergeOperation{
             state: :ref_advanced,
             failure_reason: "unexpected_ref",
             lease_owner: nil
           } = Repo.get!(MergeOperation, context.operation.id)

    assert git!(context.path, ["for-each-ref", "--format=%(refname) %(objectname)"]) ==
             before_refs

    assert [
             %AuditEvent{
               action: "pull_request.merge_recovery_blocked",
               actor_user_id: nil,
               request_id: request_id,
               metadata: %{
                 "current_oid" => current_oid,
                 "expected_oid" => expected_oid,
                 "merge_oid" => merge_oid,
                 "ref" => "refs/heads/main",
                 "result" => "blocked"
               }
             }
           ] =
             Repo.all(
               from audit in AuditEvent,
                 where: audit.operation_id == ^"pull_merge:#{context.operation.id}"
             )

    assert request_id == context.operation.request_id
    assert current_oid == context.third_oid
    assert expected_oid == context.operation.expected_base_oid
    assert merge_oid == context.merge_oid

    assert {:error, {:unavailable, :pull_recovery}} =
             ForgePulls.reconcile_repository(context.repository)
  end

  test "a new merge cannot pass retained third-OID evidence", context do
    update_ref(context.path, context.third_oid, context.operation.base_ref)

    assert {:error, {:unavailable, :pull_recovery}} =
             ForgePulls.merge(
               context.repository,
               context.pull,
               context.owner,
               %{},
               %{request_id: unique("blocked-new-merge")}
             )

    assert 1 ==
             Repo.aggregate(
               from(operation in MergeOperation,
                 where: operation.repository_id == ^context.repository.id
               ),
               :count,
               :id
             )

    assert %MergeOperation{state: :ref_advanced, failure_reason: "unexpected_ref"} =
             Repo.get!(MergeOperation, context.operation.id)
  end

  test "prepared evidence at the expected base fails without writing Git", context do
    Repo.update_all(
      from(operation in MergeOperation, where: operation.id == ^context.operation.id),
      set: [state: :prepared, merge_oid: nil]
    )

    update_ref(context.path, context.operation.expected_base_oid, context.operation.base_ref)
    before_git = git_snapshot(context.path)

    assert :ok = locked_reconcile(context)

    assert %MergeOperation{state: :failed, failure_reason: "effect_not_started"} =
             Repo.get!(MergeOperation, context.operation.id)

    assert git_snapshot(context.path) == before_git
  end

  test "merge-written evidence at the expected base fails without advancing Git", context do
    Repo.update_all(
      from(operation in MergeOperation, where: operation.id == ^context.operation.id),
      set: [state: :merge_written]
    )

    update_ref(context.path, context.operation.expected_base_oid, context.operation.base_ref)
    before_git = git_snapshot(context.path)

    assert :ok = locked_reconcile(context)

    assert %MergeOperation{state: :failed, failure_reason: "ref_not_advanced"} =
             Repo.get!(MergeOperation, context.operation.id)

    assert git_snapshot(context.path) == before_git
  end

  test "terminal operations are no-ops for every observed ref", context do
    for state <- [:completed, :failed] do
      Repo.update_all(
        from(operation in MergeOperation, where: operation.id == ^context.operation.id),
        set: [state: state, failure_reason: terminal_failure_reason(state)]
      )

      update_ref(context.path, context.third_oid, context.operation.base_ref)
      before_operation = Repo.get!(MergeOperation, context.operation.id)
      before_git = git_snapshot(context.path)

      assert :ok = locked_reconcile(context)
      assert Repo.get!(MergeOperation, context.operation.id) == before_operation
      assert git_snapshot(context.path) == before_git
    end
  end

  test "a live oldest lease blocks every later operation in the repository", context do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, live_claim} =
             OperationLease.claim(MergeOperation, context.operation.id, "live-owner", now, 30)

    later_ref = "refs/heads/later"
    update_ref(context.path, context.operation.expected_base_oid, later_ref)
    later = operation!(context, :prepared, base_ref: later_ref)

    assert {:error, :unavailable} = locked_reconcile(context)

    assert %MergeOperation{state: :ref_advanced, lease_owner: "live-owner"} =
             Repo.get!(MergeOperation, context.operation.id)

    assert %MergeOperation{state: :prepared, failure_reason: nil, lease_owner: nil} =
             Repo.get!(MergeOperation, later.id)

    assert :ok = OperationLease.release(MergeOperation, live_claim)
  end

  test "an oldest-row lock-version mismatch blocks later recovery and preserves the winner",
       context do
    later_ref = "refs/heads/claim-race-later"
    update_ref(context.path, context.operation.expected_base_oid, later_ref)
    later = operation!(context, :prepared, base_ref: later_ref)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      OperationLease.with_test_after_write_hook(
        fn :claim, MergeOperation, id, _version ->
          Repo.update_all(from(item in MergeOperation, where: item.id == ^id),
            set: [lease_expires_at: DateTime.add(now, -1, :second)]
          )

          assert {:ok, _stolen} =
                   OperationLease.claim(MergeOperation, id, "claim-race-winner", now, 30)
        end,
        fn -> locked_reconcile(context) end
      )

    assert {:error, :unavailable} = result

    assert %MergeOperation{state: :ref_advanced, lease_owner: "claim-race-winner"} =
             Repo.get!(MergeOperation, context.operation.id)

    assert %MergeOperation{state: :prepared, failure_reason: nil, lease_owner: nil} =
             Repo.get!(MergeOperation, later.id)
  end

  test "an expired lease is reclaimed with the frozen worker clock and owner", context do
    frozen_now = ~U[2026-08-09 12:00:00Z]

    assert {:ok, _expired_claim} =
             OperationLease.claim(
               MergeOperation,
               context.operation.id,
               "expired-owner",
               DateTime.add(frozen_now, -60, :second),
               5
             )

    test_pid = self()

    assert :ok =
             MergeRecovery.with_test_iteration_context(
               fn -> frozen_now end,
               "worker-17",
               fn claimed, now -> send(test_pid, {:claimed, claimed, now}) end,
               fn -> locked_reconcile(context) end
             )

    assert_receive {:claimed,
                    %MergeOperation{
                      id: operation_id,
                      lease_owner: "worker-17",
                      lease_expires_at: lease_expires_at
                    }, ^frozen_now}

    assert operation_id == context.operation.id
    assert lease_expires_at == DateTime.add(frozen_now, 30, :second)
    assert Repo.get!(MergeOperation, context.operation.id).state == :completed
  end

  test "concurrent recovery workers have one lease winner and one completion", context do
    frozen_now = ~U[2026-08-09 12:30:00Z]
    test_pid = self()

    first =
      recovery_worker(context, "worker-a", frozen_now, fn claimed, _now ->
        send(test_pid, {:lease_winner, self(), claimed.lease_owner})
        receive do: (:release_winner -> :ok)
      end)

    assert_receive {:lease_winner, first_pid, "worker-a"}, 500

    second = recovery_worker(context, "worker-b", frozen_now, fn _claimed, _now -> :ok end)
    assert {:error, :unavailable} = Task.await(second, 1_000)

    send(first_pid, :release_winner)
    assert :ok = Task.await(first, 1_000)

    assert %MergeOperation{state: :completed, lease_owner: nil} =
             Repo.get!(MergeOperation, context.operation.id)

    assert 1 ==
             Repo.aggregate(
               from(audit in AuditEvent,
                 where:
                   audit.operation_id == ^"pull_merge:#{context.operation.id}" and
                     audit.action == "pull_request.merged"
               ),
               :count,
               :id
             )
  end

  test "the bounded batch continues to another repository when one repository is busy", context do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, live_claim} =
             OperationLease.claim(
               MergeOperation,
               context.operation.id,
               "busy-repository",
               now,
               30
             )

    recoverable = recovery_fixture(context.owner)

    assert :ok = MergeReconciler.reconcile_pending_repositories()

    assert %MergeOperation{state: :ref_advanced, lease_owner: "busy-repository"} =
             Repo.get!(MergeOperation, context.operation.id)

    assert %MergeOperation{state: :completed, lease_owner: nil} =
             Repo.get!(MergeOperation, recoverable.operation.id)

    assert :ok = OperationLease.release(MergeOperation, live_claim)
  end

  test "the reconciler recovers at startup and dispatches again on its hard-capped timer",
       context do
    task_supervisor =
      start_supervised!({Task.Supervisor, name: nil}, id: make_ref())

    test_pid = self()

    task = fn ->
      allow_background_repo(test_pid)
      result = MergeReconciler.reconcile_pending_repositories()
      send(test_pid, {:reconciler_ran, result})
    end

    start_supervised!(
      {MergeReconciler, name: nil, task_supervisor: task_supervisor, task: task, interval_ms: 20},
      id: make_ref()
    )

    assert MergeReconciler.interval_ms() == 30_000
    assert_receive {:reconciler_ran, :ok}, 500
    assert Repo.get!(MergeOperation, context.operation.id).state == :completed
    assert_receive {:reconciler_ran, :ok}, 500
  end

  test "the runtime deadline terminates a hung task without overlapping ticks" do
    task_supervisor =
      start_supervised!({Task.Supervisor, name: nil}, id: make_ref())

    test_pid = self()

    task = fn ->
      send(test_pid, {:hung_task_started, self()})
      receive do: (:never -> :ok)
    end

    start_supervised!(
      {MergeReconciler,
       name: nil, task_supervisor: task_supervisor, task: task, interval_ms: 20, runtime_ms: 80},
      id: make_ref()
    )

    assert MergeReconciler.runtime_ms() == 30_000
    assert_receive {:hung_task_started, first_pid}, 500
    refute_receive {:hung_task_started, _overlap}, 50
    assert_receive {:hung_task_started, second_pid}, 150
    refute first_pid == second_pid
  end

  test "stale task replies and DOWN messages cannot clear the current task" do
    task_supervisor =
      start_supervised!({Task.Supervisor, name: nil}, id: make_ref())

    test_pid = self()

    task = fn ->
      send(test_pid, {:correlated_task_started, self()})
      receive do: (:finish -> :ok)
    end

    reconciler =
      start_supervised!(
        {MergeReconciler,
         name: nil, task_supervisor: task_supervisor, task: task, interval_ms: 20, runtime_ms: 200},
        id: make_ref()
      )

    assert_receive {:correlated_task_started, first_pid}, 500
    %{task: %Task{ref: old_ref}} = :sys.get_state(reconciler)
    send(first_pid, :finish)
    assert_receive {:correlated_task_started, second_pid}, 500

    send(reconciler, {old_ref, :late_reply})
    send(reconciler, {:DOWN, old_ref, :process, first_pid, :normal})

    refute_receive {:correlated_task_started, _third_pid}, 60
    assert Process.alive?(second_pid)
    send(second_pid, :finish)
  end

  defp user_fixture do
    name = unique("merge-owner")

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: name,
        email: "#{name}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp repository_fixture(owner) do
    slug = unique("merge-repo")
    {:ok, repository} = ForgeRepos.create_repository(owner, %{name: slug, slug: slug})
    repository
  end

  defp create_merge_graph(path) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git!(path, ["commit-tree", tree, "-m", "base"])
    head = git!(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    merge = git!(path, ["commit-tree", tree, "-p", base, "-p", head, "-m", "merge"])
    third = git!(path, ["commit-tree", tree, "-p", base, "-m", "third"])
    update_ref(path, base, "refs/heads/main")
    update_ref(path, head, "refs/heads/feature")
    {base, head, merge, third}
  end

  defp locked_reconcile(context) do
    MergeRecovery.reconcile_repository_locked(
      context.repository,
      context.path,
      System.monotonic_time(:millisecond) + 10_000
    )
  end

  defp operation!(context, state, overrides) do
    operation =
      %MergeOperation{}
      |> MergeOperation.prepare_changeset(%{
        pull_request_id: context.pull.id,
        repository_id: context.repository.id,
        actor_user_id: context.owner.id,
        request_id: unique("merge-operation"),
        base_ref: Keyword.get(overrides, :base_ref, context.pull.base_ref),
        head_ref: context.pull.head_ref,
        expected_base_oid: context.operation.expected_base_oid,
        expected_head_oid: context.operation.expected_head_oid,
        state: :prepared
      })
      |> Repo.insert!()

    case state do
      :prepared ->
        operation

      :merge_written ->
        operation
        |> MergeOperation.merge_written_changeset(context.merge_oid)
        |> Repo.update!()

      :ref_advanced ->
        operation
        |> MergeOperation.merge_written_changeset(context.merge_oid)
        |> Repo.update!()
        |> MergeOperation.ref_advanced_changeset()
        |> Repo.update!()
    end
  end

  defp recovery_worker(context, owner, now, observer) do
    parent = self()

    task =
      Task.async(fn ->
        receive do
          :run ->
            MergeRecovery.with_test_iteration_context(
              fn -> now end,
              owner,
              observer,
              fn -> locked_reconcile(context) end
            )
        end
      end)

    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, task.pid)
    end

    send(task.pid, :run)
    task
  end

  defp allow_background_repo(owner) do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
    end

    :ok
  end

  defp update_ref(path, oid, ref), do: git!(path, ["update-ref", ref, oid])

  defp git_snapshot(path) do
    {git!(path, ["for-each-ref", "--format=%(refname) %(objectname)"]),
     git!(path, ["count-objects", "-v"])}
  end

  defp terminal_failure_reason(:completed), do: nil
  defp terminal_failure_reason(:failed), do: "effect_not_started"

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Merge Test"},
      {"GIT_AUTHOR_EMAIL", "merge@example.test"},
      {"GIT_COMMITTER_NAME", "Merge Test"},
      {"GIT_COMMITTER_EMAIL", "merge@example.test"}
    ]

    {output, 0} = System.cmd("git", ["--git-dir=#{path}" | args], env: env)
    String.trim(output)
  end

  defp unique(prefix) do
    stamp = System.system_time(:nanosecond) |> Integer.to_string(36)
    counter = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    "#{prefix}-#{stamp}-#{counter}"
  end
end
