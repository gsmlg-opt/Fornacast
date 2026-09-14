defmodule ForgeMirrors.RepositoryMetadataReconciliationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeMirrors.{MirrorConflict, MirrorOperation, MirrorResourceState, RepositoryMirror}
  alias ForgeRepos.Repository
  alias Fornacast.{DomainOutboxEvent, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture()
    binding = repository_mirror_fixture(organization)
    now = DateTime.utc_now(:second)
    %{organization: organization, binding: binding, now: now}
  end

  test "canonical matching repository observation confirms a durable metadata baseline", c do
    assert {:ok, operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata:one",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(
               "repository-metadata-test",
               c.now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert claimed.id == operation.id
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote = %{
      id: sync.github_repository_id,
      node_id: sync.github_node_id,
      name: sync.local_snapshot["name"],
      description: sync.local_snapshot["description"],
      visibility: String.to_atom(sync.local_snapshot["visibility"]),
      default_branch: sync.local_snapshot["default_branch"],
      archived: sync.local_snapshot["archived"],
      updated_at: c.now
    }

    assert {:ok, %{operation: %MirrorOperation{state: :completed}, baseline: baseline}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert baseline.state == :confirmed
    assert baseline.confirmed_snapshot == sync.local_snapshot

    assert %MirrorResourceState{id: baseline_id, resource_kind: :repository, state: :confirmed} =
             Repo.get!(MirrorResourceState, baseline.id)

    assert baseline_id == baseline.id
  end

  test "a canonical metadata difference is retained as a conflict instead of overwriting local state",
       c do
    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata:conflict",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(
               "repository-metadata-conflict",
               c.now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote = %{
      id: sync.github_repository_id,
      node_id: sync.github_node_id,
      name: "remote-renamed",
      description: sync.local_snapshot["description"],
      visibility: String.to_atom(sync.local_snapshot["visibility"]),
      default_branch: sync.local_snapshot["default_branch"],
      archived: sync.local_snapshot["archived"],
      updated_at: c.now
    }

    assert {:ok, %{operation: %MirrorOperation{state: :failed}, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert conflict.conflict_kind == "repository_metadata_diverged"
    assert conflict.remote_snapshot["name"] == "remote-renamed"
    assert %MirrorConflict{state: :open} = Repo.get!(MirrorConflict, conflict.id)
  end

  test "an archived GitHub repository is observed as an explicit unrepresentable conflict", c do
    _baseline = confirm_baseline(c)
    repository = Repo.get!(Repository, c.binding.repository_id)
    claimed = claim_metadata_operation(c, "metadata:archived", "repository-metadata-archived")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.put(:archived, true)
      |> Map.put(:updated_at, DateTime.add(c.now, 1))

    assert {:ok, %{action: :conflict, operation: failed, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert failed.state == :failed
    assert failed.failure_class == "unsupported_resource"
    assert conflict.conflict_kind == "repository_archived_unrepresentable"
    assert conflict.remote_snapshot["archived"] == true
    assert Repo.get!(RepositoryMirror, c.binding.id).github_archived == true
    assert Repo.get!(Repository, repository.id) == repository
    refute repository_outbox_event?(repository.id)
  end

  test "GitHub internal visibility is explicit and never coerced to private", c do
    _baseline = confirm_baseline(c)
    repository = Repo.get!(Repository, c.binding.repository_id)
    claimed = claim_metadata_operation(c, "metadata:internal", "repository-metadata-internal")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.put(:name, "internal-renamed")
      |> Map.put(:visibility, :internal)
      |> Map.put(:updated_at, DateTime.add(c.now, 1))

    assert {:ok, %{action: :conflict, operation: failed, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert failed.state == :failed
    assert failed.failure_class == "unsupported_resource"
    assert conflict.conflict_kind == "repository_internal_visibility_unrepresentable"
    assert conflict.remote_snapshot["visibility"] == "internal"

    assert Repo.get!(RepositoryMirror, c.binding.id).github_full_name ==
             remote_full_name(c.binding, "internal-renamed")

    assert Repo.get!(Repository, repository.id) == repository
    refute repository_outbox_event?(repository.id)
  end

  test "combined archived and internal state has one deterministic policy conflict", c do
    _baseline = confirm_baseline(c)
    claimed = claim_metadata_operation(c, "metadata:archived-internal", "metadata-combined")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.merge(%{visibility: :internal, archived: true, updated_at: DateTime.add(c.now, 1)})

    assert {:ok, %{action: :conflict, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert conflict.conflict_kind == "repository_archived_internal_unrepresentable"
    assert Repo.get!(RepositoryMirror, c.binding.id).github_archived == true
  end

  test "an unrepresentable remote change fences a previously marked outbound update", c do
    _baseline = confirm_baseline(c)
    _repository = update_description(c.binding.repository_id, "local update must not overwrite")
    claimed = claim_metadata_operation(c, "metadata:archive-race", "metadata-archive-race")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    observed_baseline =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.put(:updated_at, DateTime.add(c.now, 1))

    assert {:ok, %{action: :update_remote, operation: marked}} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed,
               observed_baseline,
               c.now
             )

    archived_remote =
      observed_baseline
      |> Map.put(:archived, true)
      |> Map.put(:updated_at, DateTime.add(c.now, 2))

    assert {:ok, %{action: :conflict, operation: failed, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(
               marked,
               archived_remote,
               DateTime.add(c.now, 2)
             )

    assert failed.state == :failed
    assert failed.external_effect_marker == nil
    assert conflict.conflict_kind == "repository_archived_unrepresentable"

    assert Repo.get!(Repository, c.binding.repository_id).description ==
             "local update must not overwrite"
  end

  test "a later representable observation recovers the provider path and resolves the policy conflict",
       c do
    _baseline = confirm_baseline(c)
    archived = claim_metadata_operation(c, "metadata:archive-rename", "metadata-archive-rename")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(archived)

    archived_remote =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.merge(%{
        name: "archived-renamed",
        archived: true,
        updated_at: DateTime.add(c.now, 1)
      })

    assert {:ok, %{action: :conflict, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(archived, archived_remote, c.now)

    assert Repo.get!(RepositoryMirror, c.binding.id).github_full_name ==
             remote_full_name(c.binding, "archived-renamed")

    recovery =
      claim_metadata_operation(c, "metadata:archive-recovery", "metadata-archive-recovery")

    assert {:ok, recovery_sync} =
             ForgeMirrors.repository_metadata_operation_context(recovery)

    assert recovery_sync.remote_repository == "archived-renamed"

    representable_remote =
      archived_remote
      |> Map.put(:archived, false)
      |> Map.put(:updated_at, DateTime.add(c.now, 2))

    assert {:ok, %{action: :confirmed, operation: completed}} =
             ForgeMirrors.record_repository_metadata_observation(
               recovery,
               representable_remote,
               DateTime.add(c.now, 2)
             )

    assert completed.state == :completed
    assert Repo.get!(Repository, c.binding.repository_id).slug == "archived-renamed"
    assert Repo.get!(RepositoryMirror, c.binding.id).github_archived == false

    assert %MirrorConflict{
             state: :resolved,
             resolution: %{"action" => "system_reconciled", "v" => 1},
             resolved_by_user_id: nil
           } = Repo.get!(MirrorConflict, conflict.id)
  end

  test "a remote-only representable change is applied locally and confirmed", c do
    baseline = confirm_baseline(c)
    claimed = claim_metadata_operation(c, "metadata:inbound", "repository-metadata-inbound")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote =
      sync
      |> remote("#{sync.local_snapshot["name"]}-remote", DateTime.add(c.now, 1))
      |> Map.put(:description, "changed on GitHub")

    assert {:ok,
            %{
              action: :confirmed,
              operation: %MirrorOperation{state: :completed},
              baseline: updated_baseline
            }} = ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    updated = Repo.get!(Repository, c.binding.repository_id)
    assert updated.name == remote.name
    assert updated.slug == ForgeRepos.Repository.normalize_slug(remote.name)
    assert updated.description == "changed on GitHub"
    assert updated.write_version == sync.local_write_version + 1
    assert updated_baseline.id == baseline.id
    assert updated_baseline.confirmed_local_version == updated.write_version
    assert updated_baseline.confirmed_snapshot["name"] == remote.name
  end

  test "a local-only change persists an exact outbound effect marker", c do
    _baseline = confirm_baseline(c)
    repository = Repo.get!(Repository, c.binding.repository_id)

    repository
    |> Ecto.Changeset.change(description: "changed in Fornacast")
    |> Ecto.Changeset.optimistic_lock(:write_version)
    |> Repo.update!()

    claimed = claim_metadata_operation(c, "metadata:outbound", "repository-metadata-outbound")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    observed_baseline =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.put(:updated_at, DateTime.add(c.now, 1))

    assert {:ok,
            %{
              action: :update_remote,
              operation: %MirrorOperation{state: :effect_pending} = marked,
              target: target
            }} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed,
               observed_baseline,
               c.now
             )

    assert target["description"] == "changed in Fornacast"
    assert marked.external_effect_marker["action"] == "update_remote_repository_metadata"
    assert marked.external_effect_marker["attempt_state"] == "prepared"
    assert marked.external_effect_marker["target"] == target
    assert marked.external_effect_marker["expected_remote"] == sync.baseline.confirmed_snapshot
  end

  test "outbound repository names use the canonical local slug rather than display name", c do
    _baseline = confirm_baseline(c)
    repository = Repo.get!(Repository, c.binding.repository_id)

    repository
    |> Ecto.Changeset.change(name: "Display Name", slug: "display-name")
    |> Ecto.Changeset.optimistic_lock(:write_version)
    |> Repo.update!()

    claimed = claim_metadata_operation(c, "metadata:slug", "repository-metadata-slug")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    observed_baseline =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.put(:updated_at, DateTime.add(c.now, 1))

    assert {:ok, %{action: :update_remote, target: target}} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed,
               observed_baseline,
               c.now
             )

    assert target["name"] == "display-name"
  end

  test "a legacy ambiguous outbound effect confirms from a canonical recovery read", c do
    _baseline = confirm_baseline(c)
    repository = Repo.get!(Repository, c.binding.repository_id)

    repository
    |> Ecto.Changeset.change(description: "recover me")
    |> Ecto.Changeset.optimistic_lock(:write_version)
    |> Repo.update!()

    claimed = claim_metadata_operation(c, "metadata:recover", "repository-metadata-recover")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    observed_baseline =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.put(:updated_at, DateTime.add(c.now, 1))

    assert {:ok, %{action: :update_remote, operation: marked, target: target}} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed,
               observed_baseline,
               c.now
             )

    legacy_marker = Map.delete(marked.external_effect_marker, "attempt_state")

    assert {1, _} =
             Repo.update_all(
               from(operation in MirrorOperation, where: operation.id == ^marked.id),
               set: [external_effect_marker: legacy_marker]
             )

    marked = %{marked | external_effect_marker: legacy_marker}

    assert {:ok, deferred} =
             ForgeMirrors.defer_repository_metadata_effect(
               marked,
               c.now,
               DateTime.add(c.now, 1),
               "network"
             )

    assert deferred.state == :effect_pending
    assert deferred.lease_owner == nil
    assert deferred.external_effect_marker == marked.external_effect_marker

    assert {:ok, [reclaimed]} =
             ForgeMirrors.claim_operations(
               "repository-metadata-reclaimed",
               DateTime.add(c.now, 1),
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    recovery_remote =
      target
      |> atomize_remote(sync)
      |> Map.put(:updated_at, DateTime.add(c.now, 2))

    assert {:ok, %{action: :confirmed, operation: %MirrorOperation{state: :completed}}} =
             ForgeMirrors.record_repository_metadata_observation(
               reclaimed,
               recovery_remote,
               DateTime.add(c.now, 2)
             )
  end

  test "a newer local edit remains pending after an older outbound effect is confirmed", c do
    _baseline = confirm_baseline(c)
    first_local = update_description(c.binding.repository_id, "first local edit")

    claimed =
      claim_metadata_operation(c, "metadata:ordered:first", "repository-metadata-ordered-1")

    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    observed_baseline =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.put(:updated_at, DateTime.add(c.now, 1))

    assert {:ok, %{action: :update_remote, operation: marked, target: first_target}} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed,
               observed_baseline,
               c.now
             )

    second_local = update_description(c.binding.repository_id, "second local edit")
    assert second_local.write_version == first_local.write_version + 1

    confirmed_remote =
      first_target
      |> atomize_remote(sync)
      |> Map.put(:updated_at, DateTime.add(c.now, 2))

    assert {:ok, %{action: :confirmed, baseline: confirmed}} =
             ForgeMirrors.record_repository_metadata_observation(
               marked,
               confirmed_remote,
               DateTime.add(c.now, 2)
             )

    assert confirmed.confirmed_local_version == first_local.write_version
    assert Repo.get!(Repository, c.binding.repository_id).description == "second local edit"

    next =
      claim_metadata_operation(c, "metadata:ordered:second", "repository-metadata-ordered-2")

    assert {:ok, next_sync} = ForgeMirrors.repository_metadata_operation_context(next)

    assert {:ok, %{action: :update_remote, target: next_target}} =
             ForgeMirrors.record_repository_metadata_observation(
               next,
               confirmed_remote,
               DateTime.add(c.now, 3)
             )

    assert next_target["description"] == "second local edit"
    assert next_sync.local_write_version == second_local.write_version
  end

  test "compatible changes to different fields apply locally and mark one remote target", c do
    _baseline = confirm_baseline(c)
    _local = update_description(c.binding.repository_id, "local description")

    claimed = claim_metadata_operation(c, "metadata:merge-fields", "repository-metadata-merge")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote =
      sync.baseline.confirmed_snapshot
      |> atomize_remote(sync)
      |> Map.put(:visibility, :public)
      |> Map.put(:updated_at, DateTime.add(c.now, 1))

    assert {:ok, %{action: :update_remote, operation: marked, target: target}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert marked.state == :effect_pending
    assert target["description"] == "local description"
    assert target["visibility"] == "public"

    updated = Repo.get!(Repository, c.binding.repository_id)
    assert updated.description == "local description"
    assert updated.visibility == :public
  end

  test "a remote rename collision becomes a namespace conflict without mutation", c do
    _baseline = confirm_baseline(c)
    repository = Repo.get!(Repository, c.binding.repository_id)

    Repo.insert!(%Repository{
      owner_user_id: repository.owner_user_id,
      slug: "occupied-name",
      name: "Occupied name",
      visibility: :private,
      storage_path: "/tmp/occupied-#{System.unique_integer([:positive])}.git",
      default_branch: "main"
    })

    claimed = claim_metadata_operation(c, "metadata:collision", "repository-metadata-collision")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    assert {:ok, %{action: :conflict, operation: failed, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed,
               remote(sync, "Occupied Name", DateTime.add(c.now, 1)),
               c.now
             )

    assert failed.failure_class == "namespace_collision"
    assert conflict.conflict_kind == "repository_namespace_collision"
    assert Repo.get!(Repository, repository.id).name == repository.name
  end

  test "changed evidence refreshes an open conflict and terminally completes the new operation",
       c do
    first = claim_metadata_operation(c, "metadata:refresh:first", "repository-metadata-first")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(first)

    assert {:ok, %{conflict: first_conflict, operation: %MirrorOperation{state: :failed}}} =
             ForgeMirrors.record_repository_metadata_observation(
               first,
               remote(sync, "remote-first", c.now),
               c.now
             )

    second = claim_metadata_operation(c, "metadata:refresh:second", "repository-metadata-second")

    assert {:ok, %{conflict: refreshed, operation: %MirrorOperation{state: :failed}}} =
             ForgeMirrors.record_repository_metadata_observation(
               second,
               remote(sync, "remote-second", DateTime.add(c.now, 1)),
               DateTime.add(c.now, 1)
             )

    assert refreshed.id == first_conflict.id
    assert refreshed.lock_version > first_conflict.lock_version
    assert refreshed.remote_snapshot["name"] == "remote-second"
    assert Repo.get!(MirrorOperation, second.id).state == :failed
  end

  defp claim_metadata_operation(c, sweep_key, owner) do
    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(c.binding, sweep_key, c.now)

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(owner, c.now, 60, 1, ["reconcile.repository.metadata"])

    claimed
  end

  defp remote(sync, name, updated_at) do
    %{
      id: sync.github_repository_id,
      node_id: sync.github_node_id,
      name: name,
      description: sync.local_snapshot["description"],
      visibility: String.to_atom(sync.local_snapshot["visibility"]),
      default_branch: sync.local_snapshot["default_branch"],
      archived: sync.local_snapshot["archived"],
      updated_at: updated_at
    }
  end

  defp confirm_baseline(c) do
    claimed = claim_metadata_operation(c, "metadata:baseline", "repository-metadata-baseline")
    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    assert {:ok, %{action: :confirmed, baseline: baseline}} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed,
               remote(sync, sync.local_snapshot["name"], c.now),
               c.now
             )

    baseline
  end

  defp atomize_remote(snapshot, sync) do
    %{
      id: sync.github_repository_id,
      node_id: sync.github_node_id,
      name: snapshot["name"],
      description: snapshot["description"],
      visibility: String.to_existing_atom(snapshot["visibility"]),
      default_branch: snapshot["default_branch"],
      archived: snapshot["archived"]
    }
  end

  defp update_description(repository_id, description) do
    repository_id
    |> then(&Repo.get!(Repository, &1))
    |> Ecto.Changeset.change(description: description)
    |> Ecto.Changeset.optimistic_lock(:write_version)
    |> Repo.update!()
  end

  defp repository_outbox_event?(repository_id) do
    Repo.exists?(
      from event in DomainOutboxEvent,
        where:
          event.aggregate_type == "repository" and
            event.aggregate_id == ^Integer.to_string(repository_id)
    )
  end

  defp remote_full_name(binding, name) do
    owner = binding.github_full_name |> String.split("/", parts: 2) |> hd()
    "#{owner}/#{name}"
  end
end
