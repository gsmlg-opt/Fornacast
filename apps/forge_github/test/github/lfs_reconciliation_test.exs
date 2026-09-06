defmodule ForgeGitHub.LFSReconciliationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeGitHub.{GitRefWorker, LFSReconciliation}
  alias ForgeMirrors.{MirrorOperation, MirrorRefState}
  alias Fornacast.Repo
  alias GitLFS.{LFSObject, RepositoryObject}

  @moduletag :tmp_dir

  setup %{tmp_dir: path} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    {:ok, owner} =
      ForgeAccounts.create_user(%{
        username: "lfs-sweep-#{suffix}",
        email: "lfs-sweep-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} = ForgeRepos.create_repository(owner, %{name: "Sweep", slug: "sweep"})
    git!(path, ["init", "--bare"])
    oid = :crypto.hash(:sha256, "unreachable-#{suffix}") |> Base.encode16(case: :lower)
    now = DateTime.utc_now(:second)

    Repo.insert!(%LFSObject{
      oid_sha256: oid,
      size: 1,
      storage_key: oid,
      state: :ready,
      verified_at: now
    })

    mapping =
      Repo.insert!(%RepositoryObject{
        repository_id: repository.id,
        oid_sha256: oid,
        reachable: true
      })

    sync = %{
      repository_id: repository.id,
      repository_generation: repository.generation,
      repository_path: path,
      confirmed_ref_oids: %{}
    }

    operation = %MirrorOperation{id: suffix, attempt_count: 1, checkpoint: %{}}
    %{repository: repository, sync: sync, operation: operation, mapping: mapping}
  end

  test "empty authoritative sweep prunes only while the writer fence is held", context do
    callback = fn ->
      refute Repo.get!(RepositoryObject, context.mapping.id).reachable
      :finalized
    end

    assert :finalized =
             LFSReconciliation.run(context.operation, context.sync, callback,
               context: fn _ -> {:ok, context.sync} end
             )
  end

  test "ref changes before publication retain old reachability and restart the scan", context do
    path = context.sync.repository_path
    tree = git!(path, ["mktree"], "")
    commit = git!(path, ["commit-tree", tree, "-m", "new ref"])

    assert {:incomplete, checkpoint} =
             LFSReconciliation.run(
               context.operation,
               context.sync,
               fn -> flunk("stale sweep finalized") end,
               context: fn _ -> {:ok, context.sync} end,
               before_publish: fn -> git!(path, ["update-ref", "refs/heads/main", commit]) end
             )

    assert checkpoint["scan_key"] != nil
    assert Repo.get!(RepositoryObject, context.mapping.id).reachable
  end

  test "a reachable pointer with missing bytes blocks finalization through bounded resumes",
       context do
    path = context.sync.repository_path

    File.write!(
      Path.join(path, "pointer.lfs"),
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{context.mapping.oid_sha256}\nsize 1\n"
    )

    git!(path, ["--work-tree", path, "add", "pointer.lfs"])
    tree = git!(path, ["write-tree"])
    commit = git!(path, ["commit-tree", tree, "-m", "pointer"])
    git!(path, ["update-ref", "refs/heads/main", commit])
    sync = %{context.sync | confirmed_ref_oids: %{"refs/heads/main" => commit}}

    assert {:error, :lfs_missing} = resume(context.operation, sync, 20)
    assert Repo.get!(RepositoryObject, context.mapping.id).reachable
  end

  test "conflicting sizes for one reachable OID are integrity failures", context do
    path = context.sync.repository_path

    for size <- [1, 2] do
      name = "pointer-#{size}.lfs"

      File.write!(
        Path.join(path, name),
        "version https://git-lfs.github.com/spec/v1\noid sha256:#{context.mapping.oid_sha256}\nsize #{size}\n"
      )

      git!(path, ["--work-tree", path, "add", name])
    end

    tree = git!(path, ["write-tree"])
    commit = git!(path, ["commit-tree", tree, "-m", "conflicting pointers"])
    git!(path, ["update-ref", "refs/heads/main", commit])
    sync = %{context.sync | confirmed_ref_oids: %{"refs/heads/main" => commit}}

    assert {:error, :lfs_integrity} = resume(context.operation, sync, 20)
    assert Repo.get!(RepositoryObject, context.mapping.id).reachable
  end

  test "an LFS-degraded child terminally fails its finalizer and releases later work" do
    now = DateTime.utc_now(:second)
    context = lfs_mirror_context!()
    reconciliation_id = System.unique_integer([:positive])

    child =
      enqueue_operation!(context, "sync.git_ref", %{
        "initial_absence" => false,
        "reconciliation_operation_id" => reconciliation_id,
        "ref_name" => "refs/heads/main"
      })
      |> claim!(now, "lfs-child")

    assert {:ok, %{operation: %{state: :failed}}} =
             ForgeMirrors.degrade_git_ref(
               child,
               "refs/heads/main",
               String.duplicate("a", 40),
               String.duplicate("a", 40),
               now,
               "lfs_missing",
               "required LFS object is missing"
             )

    finalizer =
      enqueue_operation!(context, "finalize.repository.git", %{
        "reconciliation_operation_id" => reconciliation_id
      })

    later =
      enqueue_operation!(context, "sync.git_ref", %{
        "initial_absence" => false,
        "ref_name" => "refs/heads/later"
      })

    finalizer = claim!(finalizer, now, "lfs-finalizer")
    assert {:ok, %{lfs_enabled: true}} = ForgeMirrors.git_repository_operation_context(finalizer)

    assert {:ok, %{operation: failed, repository_mirror: nil}} =
             GitRefWorker.process_operation(finalizer, now, [])

    assert failed.state == :failed
    assert failed.failure_class == "lfs_missing"

    assert {:ok, [%MirrorOperation{id: later_id}]} =
             ForgeMirrors.claim_operations("later-work", now, 30, 1)

    assert later_id == later.id
  end

  test "a conflicted child terminally fails its LFS-enabled finalizer" do
    now = DateTime.utc_now(:second)
    context = lfs_mirror_context!()
    reconciliation_id = System.unique_integer([:positive])
    oid = String.duplicate("b", 40)

    child =
      enqueue_operation!(context, "sync.git_ref", %{
        "initial_absence" => false,
        "reconciliation_operation_id" => reconciliation_id,
        "ref_name" => "refs/heads/main"
      })
      |> claim!(now, "conflicted-child")

    assert {:ok, %{operation: %{state: :failed}, ref_state: %MirrorRefState{state: :conflicted}}} =
             ForgeMirrors.conflict_git_ref(
               child,
               "refs/heads/main",
               :git_divergence,
               oid,
               oid,
               String.duplicate("c", 40),
               now
             )

    finalizer =
      enqueue_operation!(context, "finalize.repository.git", %{
        "reconciliation_operation_id" => reconciliation_id
      })
      |> claim!(now, "conflicted-finalizer")

    assert {:ok, %{lfs_enabled: true}} = ForgeMirrors.git_repository_operation_context(finalizer)

    assert {:ok, %{operation: failed, repository_mirror: nil}} =
             GitRefWorker.process_operation(finalizer, now, [])

    assert failed.state == :failed
    assert failed.failure_class == "git_divergence"
  end

  defp resume(_operation, _sync, 0), do: flunk("scan failed to finish within bounded attempts")

  defp resume(operation, sync, remaining) do
    case LFSReconciliation.run(operation, sync, fn -> flunk("missing object finalized") end,
           context: fn _ -> {:ok, sync} end
         ) do
      {:incomplete, checkpoint} ->
        resume(%{operation | checkpoint: checkpoint}, sync, remaining - 1)

      result ->
        result
    end
  end

  defp lfs_mirror_context! do
    organization_mirror = active_organization_mirror_fixture(%{capabilities: %{"lfs" => true}})
    repository_mirror = repository_mirror_fixture(organization_mirror)
    storage_path = "lfs-finalizer/#{Ecto.UUID.generate()}.git"

    from(repository in ForgeRepos.Repository,
      where: repository.id == ^repository_mirror.repository_id
    )
    |> Repo.update_all(set: [storage_path: storage_path])

    repository_path = Fornacast.Storage.repository_path!(storage_path)
    File.mkdir_p!(repository_path)
    git!(repository_path, ["init", "--bare"])
    on_exit(fn -> File.rm_rf!(repository_path) end)

    assert {:ok, installation} =
             ForgeMirrors.get_github_app_installation(organization_mirror.github_installation_id)

    assert {:ok, _installation} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: organization_mirror.github_installation_id,
               github_account_id: organization_mirror.github_account_id,
               github_account_login: organization_mirror.github_account_login,
               account_type: :organization,
               repository_selection: :all,
               permissions: %{"contents" => "write", "metadata" => "read"},
               state: :active,
               last_verified_at: DateTime.add(installation.last_verified_at, 1, :second)
             })

    %{organization_mirror: organization_mirror, repository_mirror: repository_mirror}
  end

  defp enqueue_operation!(context, kind, cursor) do
    assert {:ok, operation} =
             ForgeMirrors.enqueue_operation(%{
               organization_mirror_id: context.organization_mirror.id,
               repository_mirror_id: context.repository_mirror.id,
               kind: kind,
               dedupe_key: Ecto.UUID.generate(),
               cursor: cursor,
               next_attempt_at: DateTime.utc_now(:second)
             })

    operation
  end

  defp claim!(%MirrorOperation{id: id}, now, owner) do
    assert {:ok, [%MirrorOperation{id: ^id} = claimed]} =
             ForgeMirrors.claim_operations(owner, now, 30, 1)

    claimed
  end

  defp git!(path, args, input \\ nil) do
    options = [
      cd: path,
      stderr_to_stdout: true,
      env: [
        {"GIT_AUTHOR_NAME", "Test"},
        {"GIT_AUTHOR_EMAIL", "test@example.test"},
        {"GIT_COMMITTER_NAME", "Test"},
        {"GIT_COMMITTER_EMAIL", "test@example.test"}
      ]
    ]

    {output, 0} =
      if input == nil,
        do: System.cmd("git", args, options),
        else: System.cmd("sh", ["-c", "git mktree </dev/null"], options)

    String.trim(output)
  end
end
