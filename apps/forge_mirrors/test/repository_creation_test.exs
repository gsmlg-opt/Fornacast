defmodule ForgeMirrors.RepositoryCreationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.{DomainOutboxEvent, Repo}

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorConflict,
    MirrorOperation,
    MirrorResourceState,
    OrganizationMirror,
    RepositoryMirror
  }

  alias ForgeRepos.Repository

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        policy: %{"auto_create_remote_repositories" => true},
        capabilities: %{"git" => "enabled"}
      })

    installation =
      Repo.get_by!(GitHubAppInstallation,
        github_installation_id: organization.github_installation_id
      )

    {:ok, _installation} =
      ForgeMirrors.observe_github_app_installation(%{
        github_installation_id: organization.github_installation_id,
        github_account_id: organization.github_account_id,
        github_account_login: organization.github_account_login,
        account_type: :organization,
        repository_selection: :all,
        permissions: %{
          "metadata" => "read",
          "administration" => "write",
          "contents" => "write"
        },
        state: :active,
        last_verified_at: DateTime.add(installation.last_verified_at, 1, :second)
      })

    repository_id = repository_fixture(organization.organization_id)
    now = DateTime.utc_now(:second)

    event = %DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(repository_id),
      event_type: "repository.created",
      origin: :fornacast,
      payload: %{
        "repository_id" => repository_id,
        "owner_id" => organization.organization_id
      },
      available_at: now
    }

    assert {:ok, {:materialized, [%MirrorOperation{}]}} =
             ForgeMirrors.materialize_outbox_event(event)

    assert {:ok, [operation]} =
             ForgeMirrors.claim_operations(
               "repository-create-test",
               now,
               60,
               1,
               ["sync.repository.create"]
             )

    %{organization: organization, repository_id: repository_id, operation: operation, now: now}
  end

  test "marks absence before create and atomically binds the canonical repository baseline", c do
    assert {:ok, context} = ForgeMirrors.repository_creation_context(c.operation)
    assert context.repository_id == c.repository_id
    assert context.github_repository_id == nil
    assert context.github_account_id == c.organization.github_account_id
    assert context.target["archived"] == false

    assert {:ok, %MirrorOperation{state: :effect_pending} = marked} =
             ForgeMirrors.mark_repository_creation_effect(c.operation, context, c.now)

    assert marked.external_effect_marker["action"] == "create_remote_repository"
    assert marked.external_effect_marker["expected_absence"] == true
    assert marked.external_effect_marker["target"] == context.target

    remote = %{
      id: 41,
      node_id: "R_41",
      owner_id: c.organization.github_account_id,
      owner_login: c.organization.github_account_login,
      full_name: "#{c.organization.github_account_login}/#{context.target["name"]}",
      name: context.target["name"],
      description: context.target["description"],
      visibility: String.to_atom(context.target["visibility"]),
      default_branch: context.target["default_branch"],
      archived: false,
      updated_at: c.now
    }

    assert {:ok,
            %{
              operation: %MirrorOperation{state: :completed},
              binding: %RepositoryMirror{state: :discovered} = binding,
              baseline: %MirrorResourceState{state: :confirmed} = baseline,
              git_reconciliation:
                %MirrorOperation{
                  kind: "reconcile.repository.git",
                  state: :pending
                } = git_reconciliation
            }} = ForgeMirrors.confirm_repository_creation(marked, remote, c.now)

    assert binding.repository_id == c.repository_id
    assert binding.github_repository_id == remote.id
    assert binding.github_node_id == remote.node_id
    assert binding.github_full_name == remote.full_name
    assert baseline.local_resource_id == c.repository_id
    assert baseline.github_object_id == remote.id
    assert baseline.github_node_id == remote.node_id
    assert baseline.confirmed_snapshot == context.target
    assert git_reconciliation.repository_mirror_id == binding.id
    assert git_reconciliation.cursor["repository_creation_operation_id"] == marked.id

    assert Repo.aggregate(
             from(state in MirrorResourceState,
               where:
                 state.repository_mirror_id == ^binding.id and state.resource_kind == :repository
             ),
             :count
           ) == 1
  end

  test "a policy downgrade fences marking before any provider effect", c do
    assert {:ok, context} = ForgeMirrors.repository_creation_context(c.operation)
    organization = Repo.get!(OrganizationMirror, c.organization.id)

    organization
    |> OrganizationMirror.update_changeset(%{
      policy: %{"auto_create_remote_repositories" => false}
    })
    |> Repo.update!()

    assert {:error, :policy_disabled} =
             ForgeMirrors.mark_repository_creation_effect(c.operation, context, c.now)

    assert Repo.get!(MirrorOperation, c.operation.id).state == :processing
  end

  test "a pre-existing same-name repository becomes a visible namespace conflict", c do
    assert {:ok, context} = ForgeMirrors.repository_creation_context(c.operation)

    remote = %{
      id: 99,
      node_id: "R_99",
      owner_id: c.organization.github_account_id,
      owner_login: c.organization.github_account_login,
      full_name: "#{c.organization.github_account_login}/#{context.target["name"]}",
      name: context.target["name"],
      description: "foreign repository",
      visibility: :private,
      default_branch: "main",
      archived: false,
      updated_at: c.now
    }

    assert {:ok,
            %{
              operation: %MirrorOperation{
                state: :failed,
                failure_class: "namespace_collision"
              },
              conflict: %MirrorConflict{state: :open} = conflict
            }} =
             ForgeMirrors.conflict_repository_creation(
               c.operation,
               remote,
               "repository_namespace_collision",
               c.now
             )

    assert conflict.repository_mirror_id == c.operation.repository_mirror_id
    assert conflict.resource_identity == "99"
    assert conflict.local_snapshot == context.target
    assert conflict.remote_snapshot["description"] == "foreign repository"

    binding = Repo.get!(RepositoryMirror, c.operation.repository_mirror_id)
    assert binding.github_repository_id == nil
    assert binding.github_node_id == nil
  end

  test "credential revocation preserves an ambiguous create marker and the local repository", c do
    assert {:ok, context} = ForgeMirrors.repository_creation_context(c.operation)

    assert {:ok, marked} =
             ForgeMirrors.mark_repository_creation_effect(c.operation, context, c.now)

    marker = marked.external_effect_marker

    assert {:ok,
            %MirrorOperation{
              state: :failed,
              failure_class: "credential_revoked",
              failure_disposition: :terminal,
              external_effect_marker: nil,
              checkpoint: %{"halted_external_effect" => ^marker}
            }} =
             ForgeMirrors.halt_repository_creation_effect(
               marked,
               c.now,
               "credential_revoked"
             )

    assert {:ok, _repository} = ForgeRepos.fetch_live_repository(c.repository_id)

    assert Repo.get!(RepositoryMirror, c.operation.repository_mirror_id).github_repository_id ==
             nil
  end

  test "pause after claim releases processing work without losing the queued intent", c do
    actor = organization_owner_fixture(c.organization)
    organization = Repo.get!(OrganizationMirror, c.organization.id)
    assert {:ok, _paused} = ForgeMirrors.pause(actor, organization)

    assert {:error, :paused} = ForgeMirrors.repository_creation_context(c.operation)

    assert {:ok,
            %MirrorOperation{
              state: :pending,
              lease_owner: nil,
              lease_expires_at: nil,
              external_effect_marker: nil
            }} = ForgeMirrors.pause_repository_creation(c.operation, c.now)

    assert {:ok, []} =
             ForgeMirrors.claim_operations(
               "repository-create-paused",
               c.now,
               60,
               1,
               ["sync.repository.create"]
             )
  end

  test "pause after the create marker releases the lease and retains recovery evidence", c do
    assert {:ok, context} = ForgeMirrors.repository_creation_context(c.operation)

    assert {:ok, marked} =
             ForgeMirrors.mark_repository_creation_effect(c.operation, context, c.now)

    marker = marked.external_effect_marker
    actor = organization_owner_fixture(c.organization)
    organization = Repo.get!(OrganizationMirror, c.organization.id)
    assert {:ok, _paused} = ForgeMirrors.pause(actor, organization)

    assert {:error, :paused} = ForgeMirrors.repository_creation_context(marked)
    assert {:error, :paused} = ForgeMirrors.authorize_repository_creation_effect(marked)

    assert {:ok,
            %MirrorOperation{
              state: :effect_pending,
              lease_owner: nil,
              lease_expires_at: nil,
              external_effect_marker: ^marker
            }} = ForgeMirrors.pause_repository_creation(marked, c.now)

    assert {:ok, []} =
             ForgeMirrors.claim_operations(
               "repository-create-paused-effect",
               c.now,
               60,
               1,
               ["sync.repository.create"]
             )
  end

  test "policy downgrade after marking checkpoints ambiguous recovery evidence", c do
    assert {:ok, context} = ForgeMirrors.repository_creation_context(c.operation)

    assert {:ok, marked} =
             ForgeMirrors.mark_repository_creation_effect(c.operation, context, c.now)

    marker = marked.external_effect_marker
    organization = Repo.get!(OrganizationMirror, c.organization.id)

    organization
    |> OrganizationMirror.update_changeset(%{
      policy: %{"auto_create_remote_repositories" => false}
    })
    |> Repo.update!()

    assert {:error, :policy_disabled} =
             ForgeMirrors.authorize_repository_creation_effect(marked)

    assert {:ok,
            %MirrorOperation{
              state: :failed,
              failure_class: "local_validation",
              external_effect_marker: nil,
              checkpoint: %{"halted_external_effect" => ^marker}
            }} =
             ForgeMirrors.halt_repository_creation_effect(marked, c.now, "local_validation")
  end

  test "repository namespace conflicts remain scoped to each local binding", c do
    assert {:ok, first_context} = ForgeMirrors.repository_creation_context(c.operation)
    remote = remote(c, first_context, 101)

    assert {:ok, %{conflict: first_conflict}} =
             ForgeMirrors.conflict_repository_creation(
               c.operation,
               remote,
               "repository_namespace_collision",
               c.now
             )

    second_repository_id = repository_fixture(c.organization.organization_id)

    second_event = %DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(second_repository_id),
      event_type: "repository.created",
      origin: :fornacast,
      payload: %{
        "repository_id" => second_repository_id,
        "owner_id" => c.organization.organization_id
      },
      available_at: c.now
    }

    assert {:ok, {:materialized, [%MirrorOperation{}]}} =
             ForgeMirrors.materialize_outbox_event(second_event)

    assert {:ok, [second_operation]} =
             ForgeMirrors.claim_operations(
               "repository-create-second",
               c.now,
               60,
               1,
               ["sync.repository.create"]
             )

    assert {:ok, second_context} = ForgeMirrors.repository_creation_context(second_operation)

    second_remote =
      remote
      |> Map.put(:name, second_context.target["name"])
      |> Map.put(
        :full_name,
        "#{c.organization.github_account_login}/#{second_context.target["name"]}"
      )

    assert {:ok, %{conflict: second_conflict}} =
             ForgeMirrors.conflict_repository_creation(
               second_operation,
               second_remote,
               "repository_namespace_collision",
               c.now
             )

    refute first_conflict.id == second_conflict.id

    assert Repo.get!(MirrorConflict, first_conflict.id).repository_mirror_id ==
             c.operation.repository_mirror_id

    assert second_conflict.repository_mirror_id == second_operation.repository_mirror_id
  end

  test "a newer local edit does not prevent confirmation of the older marked create", c do
    assert {:ok, context} = ForgeMirrors.repository_creation_context(c.operation)

    assert {:ok, marked} =
             ForgeMirrors.mark_repository_creation_effect(c.operation, context, c.now)

    repository = Repo.get!(Repository, c.repository_id)

    repository
    |> Ecto.Changeset.change(description: "newer local description")
    |> Ecto.Changeset.optimistic_lock(:write_version)
    |> Repo.update!()

    retry_at = DateTime.add(c.now, 1)

    assert {:ok, _deferred} =
             ForgeMirrors.defer_repository_creation_effect(marked, c.now, retry_at, "network")

    assert {:ok, [reclaimed]} =
             ForgeMirrors.claim_operations(
               "repository-create-recovery",
               retry_at,
               60,
               1,
               ["sync.repository.create"]
             )

    assert {:ok, recovery_context} = ForgeMirrors.repository_creation_context(reclaimed)
    assert recovery_context.target == context.target

    remote = %{
      id: 42,
      node_id: "R_42",
      owner_id: c.organization.github_account_id,
      owner_login: c.organization.github_account_login,
      full_name: "#{c.organization.github_account_login}/#{context.target["name"]}",
      name: context.target["name"],
      description: context.target["description"],
      visibility: String.to_atom(context.target["visibility"]),
      default_branch: context.target["default_branch"],
      archived: false,
      updated_at: c.now
    }

    assert {:ok, %{baseline: baseline}} =
             ForgeMirrors.confirm_repository_creation(reclaimed, remote, retry_at)

    assert baseline.confirmed_snapshot == context.target
    assert baseline.confirmed_local_version == nil
    assert Repo.get!(Repository, c.repository_id).description == "newer local description"
  end

  test "a non-default local branch schedules Git convergence after GitHub creates main", c do
    repository = Repo.get!(Repository, c.repository_id)

    repository
    |> Ecto.Changeset.change(default_branch: "trunk")
    |> Ecto.Changeset.optimistic_lock(:write_version)
    |> Repo.update!()

    assert {:ok, context} = ForgeMirrors.repository_creation_context(c.operation)
    assert context.target["default_branch"] == "trunk"

    assert {:ok, marked} =
             ForgeMirrors.mark_repository_creation_effect(c.operation, context, c.now)

    github_remote =
      c
      |> remote(context, 43)
      |> Map.put(:default_branch, "main")

    assert {:ok,
            %{
              baseline: %MirrorResourceState{confirmed_snapshot: %{"default_branch" => "main"}},
              git_reconciliation:
                %MirrorOperation{
                  kind: "reconcile.repository.git",
                  state: :pending
                } = git_reconciliation
            }} = ForgeMirrors.confirm_repository_creation(marked, github_remote, c.now)

    assert {:ok, [claimed_git]} =
             ForgeMirrors.claim_operations(
               "repository-create-git",
               c.now,
               60,
               1,
               ["reconcile.repository.git"]
             )

    assert claimed_git.id == git_reconciliation.id

    assert {:ok, %{finalizer: %MirrorOperation{} = pending_finalizer}} =
             ForgeMirrors.fanout_git_ref_reconciliation(claimed_git, [], c.now)

    assert {:ok, [claimed_finalizer]} =
             ForgeMirrors.claim_operations(
               "repository-create-finalizer",
               c.now,
               60,
               1,
               ["finalize.repository.git"]
             )

    assert claimed_finalizer.id == pending_finalizer.id

    assert {:ok,
            %{
              repository_mirror: %RepositoryMirror{state: :discovered},
              metadata_reconciliation:
                %MirrorOperation{
                  kind: "reconcile.repository.metadata",
                  state: :pending
                } = pending_metadata
            }} = ForgeMirrors.finalize_git_ref_reconciliation(claimed_finalizer, c.now)

    unrelated_completion = %MirrorOperation{
      kind: "reconcile.repository.metadata",
      state: :completed,
      organization_mirror_id: c.organization.id,
      repository_mirror_id: c.operation.repository_mirror_id
    }

    assert :ok =
             ForgeMirrors.activate_repository_after_metadata(unrelated_completion, c.now)

    assert Repo.get!(RepositoryMirror, c.operation.repository_mirror_id).state == :discovered

    assert {:ok, [claimed_metadata]} =
             ForgeMirrors.claim_operations(
               "repository-create-metadata",
               c.now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert claimed_metadata.id == pending_metadata.id

    converged_remote = Map.put(github_remote, :default_branch, "trunk")

    assert {:ok, %{operation: %MirrorOperation{state: :completed}}} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed_metadata,
               converged_remote,
               c.now
             )

    assert Repo.get!(RepositoryMirror, c.operation.repository_mirror_id).state == :active
  end

  defp remote(c, context, id) do
    %{
      id: id,
      node_id: "R_#{id}",
      owner_id: c.organization.github_account_id,
      owner_login: c.organization.github_account_login,
      full_name: "#{c.organization.github_account_login}/#{context.target["name"]}",
      name: context.target["name"],
      description: context.target["description"],
      visibility: String.to_atom(context.target["visibility"]),
      default_branch: context.target["default_branch"],
      archived: false,
      updated_at: c.now
    }
  end
end
