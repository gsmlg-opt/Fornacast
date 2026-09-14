defmodule ForgeGitHub.RepositoryMetadataPolicyIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeGitHub.{
    Error,
    InstallationToken,
    InventoryWorker,
    ReleaseSyncWorker,
    RepositoryMetadataSyncWorker
  }

  alias ForgeGitHub.Repository, as: GitHubRepository

  alias ForgeMirrors.{
    MirrorConflict,
    MirrorOperation,
    MirrorResourceState,
    MirrorWebhookDelivery,
    OrganizationMirror,
    RepositoryMirror
  }

  alias ForgeReleases.Release
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture()
    binding = repository_mirror_fixture(organization)
    repository = Repo.get!(Repository, binding.repository_id)
    now = DateTime.utc_now(:second)

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               binding,
               "metadata-policy:baseline",
               now
             )

    assert {:ok, [{_operation_id, {:ok, %{action: :confirmed}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-policy-baseline",
               now: fn -> now end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _repository_name, _ ->
                 {:ok, remote(binding, repository.slug, false, repository.visibility, now)}
               end
             )

    %{
      actor: organization_owner_fixture(organization),
      organization: organization,
      binding: Repo.get!(RepositoryMirror, binding.id),
      now: now
    }
  end

  test "a rename plus unrepresentable archive advances the GET path without a PATCH and recovers",
       c do
    repository = Repo.get!(Repository, c.binding.repository_id)

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata-policy:archived",
               DateTime.add(c.now, 1)
             )

    archived_remote =
      remote(
        c.binding,
        "archived-renamed",
        true,
        repository.visibility,
        DateTime.add(c.now, 1)
      )

    assert {:ok, [{_operation_id, {:ok, %{action: :conflict, conflict: conflict}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-policy-archive",
               now: fn -> DateTime.add(c.now, 1) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, repository_name, _ ->
                 send(self(), {:fetched_repository, repository_name})
                 {:ok, archived_remote}
               end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_repository_patch)
                 flunk("unrepresentable repository metadata must not be patched")
               end
             )

    assert conflict.conflict_kind == "repository_archived_unrepresentable"
    assert_received {:fetched_repository, initial_name}

    assert initial_name ==
             c.binding.github_full_name |> String.split("/", parts: 2) |> List.last()

    refute_received :administration_token
    refute_received :unexpected_repository_patch

    observed = Repo.get!(RepositoryMirror, c.binding.id)
    assert observed.github_archived == true
    assert String.ends_with?(observed.github_full_name, "/archived-renamed")

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               observed,
               "metadata-policy:unarchived",
               DateTime.add(c.now, 2)
             )

    recovered_remote = %{archived_remote | archived: false, updated_at: DateTime.add(c.now, 2)}

    assert {:ok, [{_operation_id, {:ok, %{action: :confirmed}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-policy-unarchive",
               now: fn -> DateTime.add(c.now, 2) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, repository_name, _ ->
                 send(self(), {:recovery_fetch, repository_name})
                 {:ok, recovered_remote}
               end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_repository_patch)
                 flunk("remote-only recovery must not patch GitHub")
               end
             )

    assert_received {:recovery_fetch, "archived-renamed"}
    refute_received :administration_token
    refute_received :unexpected_repository_patch
    assert Repo.get!(Repository, repository.id).slug == "archived-renamed"
    assert Repo.get!(RepositoryMirror, c.binding.id).github_archived == false
    assert Repo.get!(MirrorConflict, conflict.id).state == :resolved
  end

  test "full inventory repairs an intentionally omitted repository metadata webhook", c do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    task_supervisor = start_supervised!(Task.Supervisor)
    observed_at = DateTime.add(c.now, 10)
    owner = c.actor

    repository = Repo.get!(Repository, c.binding.repository_id)

    github_repository = %GitHubRepository{
      id: c.binding.github_repository_id,
      node_id: c.binding.github_node_id,
      owner_id: c.organization.github_account_id,
      name: repository.slug,
      full_name: c.binding.github_full_name,
      owner_login: c.organization.github_account_login,
      description: "changed on GitHub without a webhook",
      visibility: repository.visibility,
      default_branch: repository.default_branch,
      has_issues: true,
      allow_merge_commit: true,
      fork: false,
      archived: false,
      updated_at: observed_at
    }

    assert Repo.aggregate(
             from(delivery in MirrorWebhookDelivery,
               where: delivery.organization_mirror_id == ^c.organization.id
             ),
             :count
           ) == 0

    assert {:ok, %MirrorOperation{} = inventory} =
             ForgeMirrors.schedule_reconciliation(owner, c.organization, observed_at)

    assert {:ok, [{inventory_id, {:ok, %{operation: completed_inventory}}}]} =
             InventoryWorker.run_once("omitted-metadata-inventory",
               now: fn -> observed_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1,
               token_fetch: token_fetch(self()),
               page_fetch: fn "metadata-policy-token", 1, options ->
                 assert options[:gate_key] ==
                          {:github_installation, c.organization.github_installation_id}

                 {:ok, %{repositories: [github_repository], next_cursor: nil}}
               end
             )

    assert inventory_id == inventory.id
    assert completed_inventory.state == :completed
    marker = "inventory-operation:#{inventory.id}"

    children =
      Repo.all(
        from operation in MirrorOperation,
          where:
            operation.organization_mirror_id == ^c.organization.id and
              operation.id != ^inventory.id and
              operation.kind != "finalize.organization.reconciliation" and
              fragment(
                "?->>'inventory_reconciliation_sweep' = ?",
                operation.cursor,
                ^marker
              ),
          order_by: [asc: operation.id]
      )

    assert Enum.map(children, & &1.kind) == [
             "reconcile.repository.git",
             "reconcile.repository.metadata"
           ]

    assert Repo.get!(OrganizationMirror, c.organization.id).last_reconciled_at == nil

    assert {:ok, [{_finalizer_id, {:ok, %{status: :waiting}}}]} =
             InventoryWorker.run_once("omitted-metadata-finalizer-waiting",
               now: fn -> observed_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1,
               token_fetch: fn _, _ -> flunk("finalizer must not fetch a token") end,
               page_fetch: fn _, _, _ -> flunk("finalizer must not call GitHub") end
             )

    assert Repo.get!(OrganizationMirror, c.organization.id).last_reconciled_at == nil

    assert {:ok, [git_operation]} =
             ForgeMirrors.claim_operations(
               "omitted-metadata-git-scaffolding",
               observed_at,
               30,
               1,
               ["reconcile.repository.git"]
             )

    assert {:ok, %MirrorOperation{state: :completed}} =
             ForgeMirrors.complete_operation(git_operation, observed_at)

    assert {:ok, [{_metadata_id, {:ok, %{action: :confirmed}}}]} =
             RepositoryMetadataSyncWorker.run_once("omitted-metadata-worker",
               now: fn -> observed_at end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, github_repository} end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_repository_patch)
                 flunk("remote-only reconciliation must not patch GitHub")
               end
             )

    assert Repo.get!(Repository, repository.id).description ==
             "changed on GitHub without a webhook"

    refute_received :administration_token
    refute_received :unexpected_repository_patch

    assert Enum.all?(
             Repo.all(
               from operation in MirrorOperation,
                 where:
                   operation.organization_mirror_id == ^c.organization.id and
                     operation.kind != "finalize.organization.reconciliation" and
                     fragment(
                       "?->>'inventory_reconciliation_sweep' = ?",
                       operation.cursor,
                       ^marker
                     )
             ),
             &(&1.state == :completed)
           )

    finalizer_retry_at = DateTime.add(observed_at, 5)

    assert {:ok, [{_finalizer_id, {:ok, %{status: :completed}}}]} =
             InventoryWorker.run_once("omitted-metadata-finalizer-completed",
               now: fn -> finalizer_retry_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1,
               token_fetch: fn _, _ -> flunk("finalizer must not fetch a token") end,
               page_fetch: fn _, _, _ -> flunk("finalizer must not call GitHub") end
             )

    assert Repo.get!(OrganizationMirror, c.organization.id).last_reconciled_at == observed_at

    assert Repo.aggregate(
             from(delivery in MirrorWebhookDelivery,
               where: delivery.organization_mirror_id == ^c.organization.id
             ),
             :count
           ) == 0
  end

  test "full inventory repairs an intentionally omitted release deletion", c do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    task_supervisor = start_supervised!(Task.Supervisor)
    observed_at = DateTime.add(c.now, 10)

    organization =
      c.organization
      |> OrganizationMirror.update_changeset(%{capabilities: %{"releases" => "enabled"}})
      |> Repo.update!()

    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: organization.github_installation_id
    )
    |> Ecto.Changeset.change(permissions: %{"contents" => "write", "metadata" => "read"})
    |> Repo.update!()

    repository = Repo.get!(Repository, c.binding.repository_id)

    release =
      Repo.insert!(%Release{
        repository_id: repository.id,
        tag_name: "v1.0.0",
        name: "Version 1",
        body: "Deleted on GitHub without a webhook",
        draft: false,
        prerelease: false,
        target_commitish: repository.default_branch,
        published_at: c.now,
        author_user_id: c.actor.id,
        sync_version: 1
      })

    baseline = %{
      "tag_name" => release.tag_name,
      "name" => release.name,
      "body" => release.body,
      "draft" => release.draft,
      "prerelease" => release.prerelease,
      "target_commitish" => release.target_commitish,
      "published_at" => DateTime.to_iso8601(release.published_at)
    }

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(baseline)

    mapping =
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: c.binding.id,
        resource_kind: :release,
        local_resource_type: "ForgeReleases.Release",
        local_resource_id: release.id,
        github_object_id: 41,
        github_node_id: "RE_41",
        confirmed_snapshot: baseline,
        confirmed_fingerprint: fingerprint,
        confirmed_local_version: 1,
        confirmed_remote_updated_at: c.now,
        state: :confirmed
      })
      |> Repo.insert!()

    github_repository = %GitHubRepository{
      id: c.binding.github_repository_id,
      node_id: c.binding.github_node_id,
      owner_id: organization.github_account_id,
      name: repository.slug,
      full_name: c.binding.github_full_name,
      owner_login: organization.github_account_login,
      description: repository.description,
      visibility: repository.visibility,
      default_branch: repository.default_branch,
      has_issues: false,
      allow_merge_commit: true,
      fork: false,
      archived: false,
      updated_at: observed_at
    }

    assert Repo.aggregate(
             from(delivery in MirrorWebhookDelivery,
               where: delivery.organization_mirror_id == ^organization.id
             ),
             :count
           ) == 0

    assert {:ok, %MirrorOperation{} = inventory} =
             ForgeMirrors.schedule_reconciliation(c.actor, organization, observed_at)

    assert {:ok, [{inventory_id, {:ok, %{operation: %{state: :completed}}}}]} =
             InventoryWorker.run_once("omitted-release-inventory",
               now: fn -> observed_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1,
               token_fetch: token_fetch(self()),
               page_fetch: fn "metadata-policy-token", 1, _ ->
                 {:ok, %{repositories: [github_repository], next_cursor: nil}}
               end
             )

    assert inventory_id == inventory.id
    marker = "inventory-operation:#{inventory.id}"

    children =
      Repo.all(
        from operation in MirrorOperation,
          where:
            operation.organization_mirror_id == ^organization.id and
              operation.id != ^inventory.id and
              operation.kind != "finalize.organization.reconciliation" and
              fragment("?->>'inventory_reconciliation_sweep' = ?", operation.cursor, ^marker),
          select: operation.kind
      )

    assert Enum.sort(children) == [
             "reconcile.repository.git",
             "reconcile.repository.metadata",
             "reconcile.repository.releases"
           ]

    assert {:ok, [{_finalizer_id, {:ok, %{status: :waiting}}}]} =
             InventoryWorker.run_once("omitted-release-finalizer-waiting",
               now: fn -> observed_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1
             )

    assert {:ok, [git_operation]} =
             ForgeMirrors.claim_operations(
               "omitted-release-git",
               observed_at,
               60,
               1,
               ["reconcile.repository.git"]
             )

    assert {:ok, %{state: :completed}} =
             ForgeMirrors.complete_operation(git_operation, observed_at)

    worker_options = [
      now: fn -> observed_at end,
      task_supervisor: task_supervisor,
      max_concurrency: 1,
      batch_size: 1,
      token_fetch: token_fetch(self()),
      list_releases: fn "metadata-policy-token", _owner, _repository, 1, _ ->
        {:ok, %{releases: [], next_cursor: nil}}
      end,
      get_release: fn "metadata-policy-token", _owner, _repository, 41, _ ->
        {:error, Error.new(:not_found)}
      end,
      create_release: fn _, _, _, _, _ -> flunk("reconciliation created a remote release") end,
      update_release: fn _, _, _, _, _, _ -> flunk("reconciliation updated a remote release") end,
      delete_release: fn _, _, _, _, _ -> flunk("reconciliation deleted a remote release") end
    ]

    for {owner, offset} <- [
          {"omitted-release-remote", 1},
          {"omitted-release-mapped", 2}
        ] do
      assert {:ok, [{operation_id, {:ok, _result}}]} =
               ReleaseSyncWorker.run_once(
                 owner,
                 Keyword.put(worker_options, :now, fn -> DateTime.add(observed_at, offset) end)
               )

      assert Repo.get!(MirrorOperation, operation_id).kind in [
               "reconcile.repository.releases",
               "sync.release"
             ]
    end

    assert {:ok, [metadata_operation]} =
             ForgeMirrors.claim_operations(
               "omitted-release-metadata",
               DateTime.add(observed_at, 2),
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert {:ok, %{state: :completed}} =
             ForgeMirrors.complete_operation(metadata_operation, DateTime.add(observed_at, 2))

    assert {:ok, [{child_id, {:ok, %MirrorOperation{state: :pending} = canonical_delete}}]} =
             ReleaseSyncWorker.run_once(
               "omitted-release-canonical-delete",
               Keyword.put(worker_options, :now, fn -> DateTime.add(observed_at, 3) end)
             )

    assert canonical_delete.checkpoint["canonical_release_deletion"] == %{
             "github_object_id" => 41,
             "observed_at" => DateTime.to_iso8601(DateTime.add(observed_at, 3))
           }

    assert {:ok, [claimed_child]} =
             ForgeMirrors.claim_operations(
               "omitted-release-apply-delete",
               DateTime.add(observed_at, 4),
               60,
               1,
               ["sync.release"]
             )

    assert claimed_child.id == child_id

    assert {:ok,
            %{
              baseline: ^baseline,
              local_deleted: false,
              local_resource_id: release_id,
              local_version: 1,
              tag_proof: :not_required
            }} = ForgeMirrors.release_operation_context(claimed_child)

    assert release_id == release.id

    assert {:ok, %{operation: %{state: :completed}}} =
             ReleaseSyncWorker.process_operation(
               claimed_child,
               DateTime.add(observed_at, 4),
               worker_options
             )

    assert [] ==
             Repo.all(
               from operation in MirrorOperation,
                 where:
                   operation.organization_mirror_id == ^organization.id and
                     operation.kind == "sync.release" and operation.state != :completed,
                 select: %{
                   id: operation.id,
                   state: operation.state,
                   checkpoint: operation.checkpoint,
                   failure_class: operation.failure_class,
                   failure_detail: operation.failure_detail
                 }
             )

    assert Repo.get!(Release, release.id).deleted_at == DateTime.add(observed_at, 3)

    assert %{state: :deleted, confirmed_snapshot: ^baseline} =
             Repo.get!(MirrorResourceState, mapping.id)

    assert Enum.all?(
             Repo.all(
               from operation in MirrorOperation,
                 where:
                   operation.organization_mirror_id == ^organization.id and
                     operation.kind != "finalize.organization.reconciliation" and
                     fragment(
                       "?->>'inventory_reconciliation_sweep' = ?",
                       operation.cursor,
                       ^marker
                     )
             ),
             &(&1.state == :completed)
           )

    finalizer_retry_at = DateTime.add(observed_at, 5)

    assert {:ok, [{_finalizer_id, {:ok, %{status: :completed}}}]} =
             InventoryWorker.run_once("omitted-release-finalizer-completed",
               now: fn -> finalizer_retry_at end,
               task_supervisor: task_supervisor,
               max_concurrency: 1,
               batch_size: 1
             )

    assert Repo.get!(OrganizationMirror, organization.id).last_reconciled_at == observed_at

    assert Repo.aggregate(
             from(delivery in MirrorWebhookDelivery,
               where: delivery.organization_mirror_id == ^organization.id
             ),
             :count
           ) == 0
  end

  test "keep Fornacast recovers a committed PATCH after timeout without a second effect", c do
    repository =
      c.binding.repository_id
      |> then(&Repo.get!(Repository, &1))
      |> Ecto.Changeset.change(description: "local owner choice")
      |> Ecto.Changeset.optimistic_lock(:write_version)
      |> Repo.update!()

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata-resolution-integration:conflict",
               DateTime.add(c.now, 1)
             )

    remote =
      c.binding
      |> remote(repository.slug, false, repository.visibility, DateTime.add(c.now, 1))
      |> Map.put(:description, "remote owner choice")

    assert {:ok, [{_operation_id, {:ok, %{action: :conflict, conflict: conflict}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-conflict",
               now: fn -> DateTime.add(c.now, 1) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end
             )

    assert {:ok, %{operation: requested}} =
             ForgeMirrors.request_repository_metadata_conflict_resolution(
               c.actor,
               c.organization.organization_id,
               conflict,
               "keep_fornacast",
               DateTime.add(c.now, 2),
               request_metadata()
             )

    assert {:ok, [{operation_id, {:ok, %MirrorOperation{state: :effect_pending} = deferred}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-first-worker",
               now: fn -> DateTime.add(c.now, 2) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end,
               repository_update: fn _, _, _, target, _ ->
                 send(self(), {:committed_patch, target})
                 {:error, Error.new(:timeout)}
               end
             )

    assert operation_id == requested.id
    assert deferred.external_effect_marker["target"]["description"] == "local owner choice"
    assert deferred.external_effect_marker["attempt_state"] == "attempted"
    assert_received {:committed_patch, target}
    assert_received :administration_token

    recovered_remote =
      c.binding
      |> remote(repository.slug, false, repository.visibility, DateTime.add(c.now, 62))
      |> Map.put(:description, target["description"])

    assert {:ok, [{^operation_id, {:ok, %{action: :confirmed, operation: completed}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-restarted-worker",
               now: fn -> DateTime.add(c.now, 62) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, recovered_remote} end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_second_patch)
                 flunk("canonical recovery must not repeat the committed PATCH")
               end
             )

    assert completed.state == :completed
    refute_received :unexpected_second_patch
    refute_received :administration_token

    assert %MirrorConflict{
             state: :resolved,
             resolution: %{"action" => "keep_fornacast", "v" => 1},
             resolved_by_user_id: actor_id
           } = Repo.get!(MirrorConflict, conflict.id)

    assert actor_id == c.actor.id
  end

  test "a revoked owner cannot turn a queued keep request into a GitHub PATCH", c do
    repository =
      c.binding.repository_id
      |> then(&Repo.get!(Repository, &1))
      |> Ecto.Changeset.change(description: "local choice before revocation")
      |> Ecto.Changeset.optimistic_lock(:write_version)
      |> Repo.update!()

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata-resolution-integration:revoked-owner",
               DateTime.add(c.now, 1)
             )

    remote =
      c.binding
      |> remote(repository.slug, false, repository.visibility, DateTime.add(c.now, 1))
      |> Map.put(:description, "remote choice")

    assert {:ok, [{_operation_id, {:ok, %{action: :conflict, conflict: conflict}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-revoked-conflict",
               now: fn -> DateTime.add(c.now, 1) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end
             )

    assert {:ok, %{operation: requested}} =
             ForgeMirrors.request_repository_metadata_conflict_resolution(
               c.actor,
               c.organization.organization_id,
               conflict,
               "keep_fornacast",
               DateTime.add(c.now, 2),
               request_metadata()
             )

    assert {:ok,
            [
              {operation_id,
               {:ok,
                %{
                  action: :conflict,
                  operation: %MirrorOperation{state: :failed} = failed,
                  conflict: rejected
                }}}
            ]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-revoked-worker",
               now: fn -> DateTime.add(c.now, 2) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end,
               authorize_effect: fn operation, now ->
                 assert operation.external_effect_marker["attempt_state"] == "prepared"

                 Repo.delete_all(
                   from(member in ForgeAccounts.OrganizationMember,
                     where:
                       member.organization_id == ^c.organization.organization_id and
                         member.user_id == ^c.actor.id
                   )
                 )

                 ForgeMirrors.authorize_repository_metadata_effect(operation, now)
               end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_repository_patch)
                 flunk("revoked owner request must not patch GitHub")
               end
             )

    assert operation_id == requested.id
    assert failed.failure_class == "permission_missing"
    assert rejected.id == conflict.id
    assert rejected.conflict_kind == "repository_metadata_resolution_unauthorized"
    refute_received :administration_token
    refute_received :unexpected_repository_patch
  end

  defp token_fetch(test_pid) do
    fn
      _installation_id, %{permissions: %{"metadata" => "read"}} ->
        %InstallationToken{
          token: "metadata-policy-token",
          expires_at: ~U[2026-09-15 00:00:00Z],
          permissions: %{"metadata" => "read"}
        }

      _installation_id, %{permissions: %{"administration" => "write"}} ->
        send(test_pid, :administration_token)

        %InstallationToken{
          token: "metadata-policy-token",
          expires_at: ~U[2026-09-15 00:00:00Z],
          permissions: %{"administration" => "write"}
        }

      _installation_id, %{permissions: %{"contents" => "write", "metadata" => "read"}} ->
        %InstallationToken{
          token: "metadata-policy-token",
          expires_at: ~U[2026-09-15 00:00:00Z],
          permissions: %{"contents" => "write", "metadata" => "read"}
        }
    end
  end

  defp remote(binding, name, archived, visibility, updated_at) do
    repository = Repo.get!(Repository, binding.repository_id)

    %{
      id: binding.github_repository_id,
      node_id: binding.github_node_id,
      name: name,
      description: repository.description,
      visibility: visibility,
      default_branch: repository.default_branch,
      archived: archived,
      updated_at: updated_at
    }
  end

  defp request_metadata do
    %{
      request_id: Ecto.UUID.generate(),
      ip_address: "127.0.0.1",
      user_agent: "repository-metadata-policy-integration-test"
    }
  end
end
