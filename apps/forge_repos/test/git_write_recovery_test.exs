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

  test "older live leases are skipped while later proposed, expected, and expired rows recover",
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

    assert :ok = locked_reconcile(context)

    assert %{state: :prepared, lease_owner: "live"} = Repo.get!(GitWriteOperation, live.id)
    assert Repo.get!(GitWriteOperation, proposed.id).state == :bookkeeping_complete

    assert %{state: :failed, failure_reason: "effect_not_started"} =
             Repo.get!(GitWriteOperation, expected.id)

    assert %{state: :failed, failure_reason: "effect_not_started", lease_owner: nil} =
             Repo.get!(GitWriteOperation, expired.id)

    assert :ok = OperationLease.release(GitWriteOperation, claimed_live)
  end

  test "a claim race advances the cursor without looping or starving later rows", context do
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

    assert :ok = result

    assert %{state: :prepared, lease_owner: "stolen"} =
             Repo.get!(GitWriteOperation, raced.id)

    assert %{state: :failed, failure_reason: "effect_not_started"} =
             Repo.get!(GitWriteOperation, later.id)
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

    assert is_nil(Repo.get!(Repository, context.repository.id).last_pushed_at)
    assert Repo.aggregate(AuditEvent, :count, :id) == 0

    assert {:ok, :cached} =
             GitCore.Cache.fetch(cache_key, fn ->
               flunk("failed transaction invalidated cache")
             end)

    assert :ok = locked_reconcile(context)
    assert Repo.get!(GitWriteOperation, operation.id).state == :bookkeeping_complete
    assert {:ok, :refreshed} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :refreshed} end)
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
      actor_user_id: nil,
      request_id:
        Keyword.get(overrides, :request_id, "request-#{System.unique_integer([:positive])}"),
      kind: :ref_update,
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
