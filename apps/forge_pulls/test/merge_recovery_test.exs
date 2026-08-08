defmodule ForgePulls.MergeRecoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, MergeRecovery, PullRequest}
  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, Repo}

  setup do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    end

    owner = user_fixture()
    repository = repository_fixture(owner)
    path = ForgeRepos.absolute_storage_path(repository)
    {base_oid, head_oid, merge_oid} = create_merge_graph(path)

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

    {:ok,
     owner: owner,
     repository: repository,
     path: path,
     pull: pull,
     operation: operation,
     merge_oid: merge_oid}
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

    assert %Issue{state: :closed, state_reason: :completed} =
             Repo.get!(Issue, context.pull.issue_id)

    assert %Repository{last_pushed_at: %DateTime{}} = Repo.get!(Repository, context.repository.id)

    assert [
             %AuditEvent{
               action: "pull_request.merged",
               actor_user_id: actor_user_id,
               request_id: request_id
             }
           ] =
             Repo.all(
               from event in AuditEvent,
                 where: event.operation_id == ^"pull_merge:#{context.operation.id}"
             )

    assert actor_user_id == context.owner.id
    assert request_id == context.operation.request_id
    assert {:ok, :refreshed} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :refreshed} end)
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
    update_ref(path, base, "refs/heads/main")
    update_ref(path, head, "refs/heads/feature")
    {base, head, merge}
  end

  defp update_ref(path, oid, ref), do: git!(path, ["update-ref", ref, oid])

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
