defmodule ForgeGitHub.LFSReconciliationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeGitHub.{GitRefWorker, InstallationToken, InventoryWorker, LFSReconciliation, LFSSync}
  alias ForgeGitHub.LFS.{Action, Object, TransferCoordinator}
  alias ForgeGitHub.Repository, as: GitHubRepository

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorWebhookDelivery,
    OrganizationMirror
  }

  alias Fornacast.Repo
  alias GitCore.Remote.ObservedRef
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

  test "full inventory repairs an omitted Git ref through Git and LFS transport seams", %{
    tmp_dir: tmp_dir
  } do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    task_supervisor = start_supervised!(Task.Supervisor)
    context = lfs_mirror_context!()
    now = DateTime.utc_now(:second)
    payload = "downloaded by omitted-webhook reconciliation"
    lfs_oid = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    on_exit(fn -> ForgeBlobs.delete(lfs_oid) end)

    pointer =
      "version https://git-lfs.github.com/spec/v1\n" <>
        "oid sha256:#{lfs_oid}\nsize #{byte_size(payload)}\n"

    remote_path = Path.join(tmp_dir, "omitted-git-lfs-remote.git")
    assert {:ok, ^remote_path} = GitCore.init_bare(remote_path)

    blob = write_object!(remote_path, "blob", pointer)

    tree =
      write_object!(
        remote_path,
        "tree",
        IO.iodata_to_binary(["100644 payload.lfs", <<0>>, Base.decode16!(blob, case: :mixed)])
      )

    commit = git!(remote_path, ["commit-tree", tree, "-m", "remote pointer"])
    git!(remote_path, ["update-ref", "refs/heads/main", commit])

    assert {:ok, nil} = GitCore.exact_ref(context.repository_path, "refs/heads/main")

    assert {:error, %GitCore.Error{kind: :commit_not_found}} =
             GitCore.commit(context.repository_path, commit)

    github_repository = %GitHubRepository{
      id: context.repository_mirror.github_repository_id,
      node_id: context.repository_mirror.github_node_id,
      owner_id: context.organization_mirror.github_account_id,
      name: Path.basename(context.repository_mirror.github_full_name),
      full_name: context.repository_mirror.github_full_name,
      owner_login: context.organization_mirror.github_account_login,
      description: nil,
      visibility: :private,
      default_branch: "main",
      has_issues: false,
      allow_merge_commit: true,
      fork: false,
      archived: false,
      updated_at: now
    }

    assert Repo.aggregate(
             from(delivery in MirrorWebhookDelivery,
               where: delivery.organization_mirror_id == ^context.organization_mirror.id
             ),
             :count
           ) == 0

    owner = organization_owner_fixture(context.organization_mirror)

    assert {:ok, inventory} =
             ForgeMirrors.schedule_reconciliation(owner, context.organization_mirror, now)

    token_fetch = fn _installation_id, scope ->
      permissions = scope.permissions

      %InstallationToken{
        token: "git-lfs-integration-token",
        expires_at: DateTime.add(now, 3_600),
        permissions: permissions
      }
    end

    assert {:ok, [{inventory_id, {:ok, %{operation: %{state: :completed}}}}]} =
             InventoryWorker.run_once("omitted-git-lfs-inventory",
               now: fn -> now end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1,
               token_fetch: token_fetch,
               page_fetch: fn "git-lfs-integration-token", 1, _ ->
                 {:ok, %{repositories: [github_repository], next_cursor: nil}}
               end
             )

    assert inventory_id == inventory.id
    marker = "inventory-operation:#{inventory.id}"

    assert {:ok, [{_finalizer_id, {:ok, %{status: :waiting}}}]} =
             InventoryWorker.run_once("omitted-git-lfs-finalizer-waiting",
               now: fn -> now end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1
             )

    parent = self()

    git_options = [
      now: fn -> now end,
      task_supervisor: task_supervisor,
      max_concurrency: 1,
      batch_size: 1,
      token_fetch: token_fetch,
      fetch_refs: fn _request, "git-lfs-integration-token", namespace ->
        assert {:ok, tracking_ref} =
                 GitCore.tracking_ref_name(namespace, "refs/heads/main")

        git!(context.repository_path, [
          "fetch",
          "--no-tags",
          remote_path,
          "+refs/heads/main:#{tracking_ref}"
        ])

        :ok = GitCore.invalidate_repository_cache(context.repository_path)
        send(parent, :git_objects_fetched)
        {:ok, [%ObservedRef{ref: "refs/heads/main", oid: commit}]}
      end,
      lfs_gate: fn marked,
                   sync,
                   :inbound,
                   ^commit,
                   "git-lfs-integration-token" = token,
                   request ->
        assert marked.external_effect_marker["lfs_required"]
        assert sync.repository_id == context.repository.id

        authorize = fn ->
          case ForgeMirrors.authorize_git_lfs_effect(
                 marked,
                 marked.external_effect_marker
               ) do
            {:ok, %MirrorOperation{}} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

        transfer_page = fn repository,
                           scan,
                           :inbound,
                           ^token,
                           remote_owner,
                           remote_repository,
                           after_oid,
                           options ->
          callbacks = %{
            batch: fn ^token,
                      ^remote_owner,
                      ^remote_repository,
                      :download,
                      objects,
                      batch_options ->
              assert Enum.map(objects, &{&1.oid, &1.size}) == [
                       {lfs_oid, byte_size(payload)}
                     ]

              assert batch_options[:gate_key] ==
                       {:github_installation, context.organization_mirror.github_installation_id}

              send(parent, :lfs_batch_requested)

              {:ok,
               [
                 %Object{
                   oid: lfs_oid,
                   size: byte_size(payload),
                   authenticated: true,
                   actions: %{
                     download:
                       Action.new!(
                         :download,
                         "https://objects.example.test/#{lfs_oid}",
                         %{},
                         nil
                       )
                   },
                   error: nil
                 }
               ]}
            end,
            consume_download: fn %Action{operation: :download}, object, consumer, [] ->
              assert object.oid == lfs_oid

              assert {:ok, staged, %{chunks: []}} =
                       consumer.(&chunk_reader/2, %{chunks: [payload]})

              send(parent, :lfs_download_streamed)
              {:ok, staged}
            end
          }

          TransferCoordinator.process_page(
            repository,
            scan,
            :inbound,
            token,
            remote_owner,
            remote_repository,
            after_oid,
            Keyword.put(options, :callbacks, callbacks)
          )
        end

        LFSSync.ensure(marked, sync, :inbound, commit, token, request,
          authorize: authorize,
          transfer_page: transfer_page
        )
      end,
      confirm: fn operation, ref, local_oid, remote_oid, confirmed_at ->
        assert %RepositoryObject{first_seen_ref: "refs/heads/main"} =
                 Repo.get_by!(RepositoryObject,
                   repository_id: context.repository.id,
                   oid_sha256: lfs_oid
                 )

        result =
          ForgeMirrors.confirm_git_ref(
            operation,
            ref,
            local_oid,
            remote_oid,
            confirmed_at
          )

        send(parent, :ref_confirmed)
        result
      end
    ]

    assert {:ok,
            [{git_root_id, {:ok, %{operation: %{state: :completed}, finalizer: git_finalizer}}}]} =
             GitRefWorker.run_once("omitted-git-lfs-root", git_options)

    assert Repo.get!(MirrorOperation, git_root_id).kind == "reconcile.repository.git"

    assert {:ok, [metadata_operation]} =
             ForgeMirrors.claim_operations(
               "omitted-git-lfs-metadata",
               now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert {:ok, %{state: :completed}} = ForgeMirrors.complete_operation(metadata_operation, now)

    assert {:ok,
            [
              {ref_operation_id, {:ok, %MirrorOperation{state: :effect_pending} = checkpointed}}
            ]} =
             GitRefWorker.run_once("omitted-git-lfs-ref", git_options)

    assert checkpointed.checkpoint["phase"] == "scan"
    assert is_binary(checkpointed.checkpoint["scan_key"])
    assert {:ok, nil} = GitCore.exact_ref(context.repository_path, "refs/heads/main")

    assert {:error, :not_found} =
             GitLFS.verify_object(context.repository, lfs_oid, byte_size(payload))

    assert {:ok, [{_finalizer_id, {:ok, %{status: :waiting}}}]} =
             InventoryWorker.run_once("omitted-git-lfs-finalizer-checkpoint-waiting",
               now: fn -> DateTime.add(now, 10) end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1
             )

    ref_operation = complete_git_ref_lfs!(ref_operation_id, now, git_options, 20)
    assert ref_operation.state == :completed
    assert Repo.get!(MirrorOperation, ref_operation_id).kind == "sync.git_ref"
    assert_received :git_objects_fetched
    assert_received :lfs_batch_requested
    assert_received :lfs_download_streamed
    assert_received :ref_confirmed
    assert {:ok, ^commit} = GitCore.exact_ref(context.repository_path, "refs/heads/main")
    assert :ok = GitLFS.verify_object(context.repository, lfs_oid, byte_size(payload))

    assert %RepositoryObject{first_seen_ref: "refs/heads/main", reachable: true} =
             Repo.get_by!(RepositoryObject,
               repository_id: context.repository.id,
               oid_sha256: lfs_oid
             )

    assert {:ok,
            [{finalizer_id, {:ok, %MirrorOperation{state: :pending} = checkpointed_finalizer}}]} =
             GitRefWorker.run_once("omitted-git-lfs-finalizer-checkpoint", git_options)

    assert finalizer_id == git_finalizer.id
    assert is_binary(checkpointed_finalizer.checkpoint["scan_key"])
    assert is_binary(checkpointed_finalizer.checkpoint["fingerprint"])
    assert checkpointed_finalizer.checkpoint["after_oid"] == nil

    assert {:ok, [{_finalizer_id, {:ok, %{status: :waiting}}}]} =
             InventoryWorker.run_once("omitted-git-lfs-finalizer-scan-waiting",
               now: fn -> DateTime.add(now, 20) end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1
             )

    finalizer = complete_git_lfs_finalizer!(git_finalizer.id, now, git_options, 20)
    assert finalizer.state == :completed

    assert %RepositoryObject{reachable: true} =
             Repo.get_by!(RepositoryObject,
               repository_id: context.repository.id,
               oid_sha256: lfs_oid
             )

    assert Enum.all?(
             Repo.all(
               from operation in MirrorOperation,
                 where:
                   operation.organization_mirror_id == ^context.organization_mirror.id and
                     operation.kind != "finalize.organization.reconciliation" and
                     fragment(
                       "?->>'inventory_reconciliation_sweep' = ?",
                       operation.cursor,
                       ^marker
                     )
             ),
             &(&1.state == :completed)
           )

    assert {:ok, [{_finalizer_id, {:ok, %{status: :completed}}}]} =
             InventoryWorker.run_once("omitted-git-lfs-finalizer-completed",
               now: fn -> DateTime.add(now, 30) end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1
             )

    assert Repo.get!(OrganizationMirror, context.organization_mirror.id).last_reconciled_at == now

    assert Repo.aggregate(
             from(delivery in MirrorWebhookDelivery,
               where: delivery.organization_mirror_id == ^context.organization_mirror.id
             ),
             :count
           ) == 0
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
    organization_mirror =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "lfs" => "enabled"}
      })

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

    %{
      organization_mirror: organization_mirror,
      repository_mirror: repository_mirror,
      repository: Repo.get!(ForgeRepos.Repository, repository_mirror.repository_id),
      repository_path: repository_path
    }
  end

  defp complete_git_ref_lfs!(_id, _now, _options, 0),
    do: flunk("Git ref LFS transfer did not finish within its bounded checkpoints")

  defp complete_git_ref_lfs!(id, now, options, remaining) do
    case Repo.get!(MirrorOperation, id) do
      %MirrorOperation{state: :completed} = completed ->
        completed

      %MirrorOperation{state: state} when state in [:pending, :effect_pending] ->
        offset = 21 - remaining

        assert {:ok, [{^id, {:ok, _result}}]} =
                 GitRefWorker.run_once(
                   "omitted-git-lfs-ref-checkpoint-#{offset}",
                   Keyword.put(options, :now, fn -> DateTime.add(now, offset) end)
                 )

        complete_git_ref_lfs!(id, now, options, remaining - 1)
    end
  end

  defp complete_git_lfs_finalizer!(_id, _now, _options, 0),
    do: flunk("Git/LFS finalizer did not finish within its bounded checkpoints")

  defp complete_git_lfs_finalizer!(id, now, options, remaining) do
    case Repo.get!(MirrorOperation, id) do
      %MirrorOperation{state: :completed} = completed ->
        completed

      %MirrorOperation{state: :pending} ->
        offset = 21 - remaining

        assert {:ok, [{^id, {:ok, _result}}]} =
                 GitRefWorker.run_once(
                   "omitted-git-lfs-finalizer-#{offset}",
                   Keyword.put(options, :now, fn -> DateTime.add(now, offset) end)
                 )

        complete_git_lfs_finalizer!(id, now, options, remaining - 1)
    end
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

  defp chunk_reader(%{chunks: [chunk | rest]} = state, _options),
    do: {:more, chunk, %{state | chunks: rest}}

  defp chunk_reader(%{chunks: []} = state, _options), do: {:done, state}

  defp write_object!(repository_path, type, body) do
    object_path =
      Path.join(
        System.tmp_dir!(),
        "fornacast-lfs-object-#{System.unique_integer([:positive])}"
      )

    File.write!(object_path, body)

    try do
      git!(repository_path, ["hash-object", "-t", type, "-w", object_path])
    after
      File.rm(object_path)
    end
  end
end
