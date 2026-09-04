defmodule ForgeMirrors.PersistenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.Multi
  alias Fornacast.{DomainOutbox, DomainOutboxEvent, Repo}

  alias ForgeMirrors.{
    MirrorConflict,
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    MirrorWebhookDelivery,
    OrganizationMirror
  }

  @moduletag :persistence

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "organization lifecycle exposes only the approved graph" do
    assert OrganizationMirror.transitions() == %{
             pending_installation: [:ready_to_bootstrap, :revoked],
             ready_to_bootstrap: [:bootstrapping, :paused, :revoked],
             bootstrapping: [:catching_up, :paused, :degraded, :conflicted, :revoked],
             catching_up: [:active, :paused, :degraded, :conflicted, :revoked],
             active: [:paused, :degraded, :conflicted, :revoked],
             degraded: [:active, :paused, :conflicted, :revoked],
             conflicted: [:active, :paused, :degraded, :revoked],
             paused: [
               :ready_to_bootstrap,
               :bootstrapping,
               :catching_up,
               :active,
               :degraded,
               :conflicted,
               :revoked
             ],
             revoked: []
           }

    mirror = organization_mirror_fixture()

    assert {:error, :invalid_transition} =
             ForgeMirrors.transition_organization_mirror(mirror, :active)

    assert {:ok, revoked} = ForgeMirrors.transition_organization_mirror(mirror, :revoked)

    assert {:error, :invalid_transition} =
             ForgeMirrors.transition_organization_mirror(revoked, :active)
  end

  test "repository lifecycle is conservative, recoverable with identities, and tombstoned terminal" do
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    assert {:ok, orphaned} =
             ForgeMirrors.transition_repository_mirror(repository_mirror, :orphaned)

    assert {:ok, active} = ForgeMirrors.transition_repository_mirror(orphaned, :active)
    assert {:ok, revoked} = ForgeMirrors.transition_repository_mirror(active, :revoked)
    assert {:ok, active_again} = ForgeMirrors.transition_repository_mirror(revoked, :active)

    assert {:ok, tombstoned} =
             ForgeMirrors.transition_repository_mirror(active_again, :tombstoned)

    assert {:error, :invalid_transition} =
             ForgeMirrors.transition_repository_mirror(tombstoned, :active)
  end

  test "partial organization uniqueness permits reconnect only after revocation" do
    organization_id = organization_fixture()

    first =
      organization_mirror_fixture(%{
        organization_id: organization_id,
        github_installation_id: 90_001,
        github_account_id: 91_001
      })

    assert {:error, duplicate} =
             ForgeMirrors.create_organization_mirror(%{
               organization_id: organization_id,
               provider: "github"
             })

    assert "has already been taken" in errors_on(duplicate).organization_id
    assert {:ok, _revoked} = ForgeMirrors.transition_organization_mirror(first, :revoked)

    assert {:ok, replacement} =
             ForgeMirrors.create_organization_mirror(%{
               organization_id: organization_id,
               provider: "github",
               github_installation_id: 90_001,
               github_account_id: 91_001
             })

    assert replacement.id != first.id
  end

  test "installation and GitHub account IDs have partial active uniqueness" do
    first =
      organization_mirror_fixture(%{github_installation_id: 92_001, github_account_id: 93_001})

    assert {:error, installation_duplicate} =
             ForgeMirrors.create_organization_mirror(%{
               organization_id: organization_fixture(),
               provider: "github",
               github_installation_id: 92_001,
               github_account_id: 93_002
             })

    assert "has already been taken" in errors_on(installation_duplicate).provider

    assert {:error, account_duplicate} =
             ForgeMirrors.create_organization_mirror(%{
               organization_id: organization_fixture(),
               provider: "github",
               github_installation_id: 92_002,
               github_account_id: 93_001
             })

    assert "has already been taken" in errors_on(account_duplicate).provider
    assert first.state == :pending_installation
  end

  test "local and remote repository identities remain unique until tombstoned" do
    organization_mirror = active_organization_mirror_fixture()
    repository_id = repository_fixture(organization_mirror.organization_id)

    first =
      repository_mirror_fixture(organization_mirror, %{
        repository_id: repository_id,
        github_repository_id: 94_001
      })

    assert {:error, local_duplicate} =
             ForgeMirrors.bind_repository(%{
               organization_mirror_id: organization_mirror.id,
               repository_id: repository_id,
               github_repository_id: 94_002
             })

    assert "has already been taken" in errors_on(local_duplicate).repository_id
    assert {:ok, tombstoned} = ForgeMirrors.transition_repository_mirror(first, :tombstoned)
    assert tombstoned.state == :tombstoned

    assert {:ok, replacement} =
             ForgeMirrors.bind_repository(%{
               organization_mirror_id: organization_mirror.id,
               repository_id: repository_id,
               github_repository_id: 94_001
             })

    assert replacement.id != first.id
  end

  test "stale lifecycle updates lose their version capability" do
    mirror = organization_mirror_fixture()

    assert {:ok, _updated} =
             ForgeMirrors.update_organization_mirror(mirror, %{policy: %{"all" => true}})

    assert {:error, :stale} =
             ForgeMirrors.update_organization_mirror(mirror, %{policy: %{"all" => false}})
  end

  test "immutable local/provider identities can be filled but never rebound" do
    organization_mirror = organization_mirror_fixture()

    assert {:error, organization_changeset} =
             ForgeMirrors.update_organization_mirror(organization_mirror, %{
               github_installation_id: organization_mirror.github_installation_id + 1
             })

    assert "is immutable once bound" in errors_on(organization_changeset).github_installation_id

    discovered =
      organization_mirror
      |> repository_mirror_fixture()
      |> then(fn active ->
        {:ok, orphaned} = ForgeMirrors.transition_repository_mirror(active, :orphaned)
        orphaned
      end)

    assert {:error, repository_changeset} =
             ForgeMirrors.update_repository_mirror(discovered, %{
               github_repository_id: discovered.github_repository_id + 1
             })

    assert "is immutable once bound" in errors_on(repository_changeset).github_repository_id
  end

  test "database directly rejects an illegal organization state" do
    mirror = organization_mirror_fixture()

    assert_raise Postgrex.Error, ~r/organization_mirrors_state_check/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "update organization_mirrors set state = 'impossible' where id = $1",
        [mirror.id]
      )
    end
  end

  test "database directly rejects processing without a lease" do
    organization_mirror = active_organization_mirror_fixture()
    operation = operation_fixture(organization_mirror)

    assert_raise Postgrex.Error, ~r/mirror_operations_lease_check/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "update mirror_operations set state = 'processing' where id = $1",
        [operation.id]
      )
    end
  end

  test "minimal ref and resource persistence enforces immutable identities" do
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    assert {:ok, ref_state} =
             %MirrorRefState{}
             |> MirrorRefState.persistence_changeset(%{
               repository_mirror_id: repository_mirror.id,
               ref_name: "refs/heads/main",
               ref_kind: :branch,
               state: :pending,
               lock_version: 1
             })
             |> Repo.insert()

    assert ref_state.ref_name == "refs/heads/main"

    assert {:error, resource_changeset} =
             %MirrorResourceState{}
             |> MirrorResourceState.persistence_changeset(%{
               repository_mirror_id: repository_mirror.id,
               resource_kind: :issue,
               state: :pending,
               lock_version: 1
             })
             |> Repo.insert()

    assert "requires an immutable identity" in errors_on(resource_changeset).local_resource_id
  end

  test "webhook inbox persistence has GUID dedupe and no processing behavior" do
    mirror = organization_mirror_fixture()
    now = DateTime.utc_now(:second)

    attrs = %{
      organization_mirror_id: mirror.id,
      delivery_guid: Ecto.UUID.generate(),
      event: "repository",
      installation_id: 10,
      signature_version: "sha256",
      raw_payload: %{"action" => "created"},
      state: :pending,
      attempt_count: 0,
      next_attempt_at: now,
      received_at: now,
      lock_version: 1
    }

    assert {:ok, _delivery} =
             %MirrorWebhookDelivery{}
             |> MirrorWebhookDelivery.persistence_changeset(attrs)
             |> Repo.insert()

    assert {:error, duplicate} =
             %MirrorWebhookDelivery{}
             |> MirrorWebhookDelivery.persistence_changeset(attrs)
             |> Repo.insert()

    assert "has already been taken" in errors_on(duplicate).delivery_guid
  end

  test "conflicts are idempotent, resolve with CAS, and appear in status" do
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)
    now = DateTime.utc_now(:second)

    attrs = %{
      organization_mirror_id: organization_mirror.id,
      repository_mirror_id: repository_mirror.id,
      resource_kind: "repository",
      resource_identity: "repo:#{repository_mirror.id}",
      conflict_kind: "namespace_collision",
      baseline_snapshot: %{"name" => "before"},
      local_snapshot: %{"name" => "local"},
      remote_snapshot: %{"name" => "remote"}
    }

    assert {:ok, conflict} = ForgeMirrors.record_conflict(attrs)
    assert {:ok, replay} = ForgeMirrors.record_conflict(attrs)
    assert replay.id == conflict.id

    assert {:error, :dedupe_conflict} =
             ForgeMirrors.record_conflict(%{attrs | remote_snapshot: %{"name" => "different"}})

    assert {:ok, status} = ForgeMirrors.organization_status(organization_mirror.id)
    assert status.open_conflicts == 1

    assert {:ok, resolved} =
             ForgeMirrors.resolve_conflict(conflict, %{"choice" => "local"}, nil, now)

    assert resolved.state == :resolved

    assert {:ok, replayed_resolution} =
             ForgeMirrors.resolve_conflict(conflict, %{"choice" => "local"}, nil, now)

    assert replayed_resolution.id == resolved.id

    assert {:ok, ^resolved} =
             ForgeMirrors.resolve_conflict(resolved, %{"choice" => "local"}, nil, now)
  end

  test "periodic reconciliation schedules due work and advances its checkpoint" do
    now = DateTime.utc_now(:second)
    mirror = active_organization_mirror_fixture(%{next_reconcile_at: now})

    assert {:ok, [{:ok, operation}]} =
             ForgeMirrors.PeriodicReconciler.run_once(now,
               batch_size: 1,
               reconcile_interval_seconds: 60
             )

    assert operation.kind == "reconcile.organization_inventory"
    assert Repo.get!(OrganizationMirror, mirror.id).next_reconcile_at == DateTime.add(now, 60)

    assert {:ok, []} =
             ForgeMirrors.PeriodicReconciler.run_once(now,
               batch_size: 1,
               reconcile_interval_seconds: 60
             )
  end

  test "outbox dispatcher materializes durable work while paused and only then acknowledges" do
    Repo.delete_all(DomainOutboxEvent)
    now = DateTime.utc_now(:second)
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)
    assert {:ok, _paused} = ForgeMirrors.pause(organization_mirror)
    event_id = Ecto.UUID.generate()

    assert {:ok, %{event: event}} =
             Multi.new()
             |> DomainOutbox.record_multi(:event, %{
               event_id: event_id,
               aggregate_type: "repository",
               aggregate_id: Integer.to_string(repository_mirror.repository_id),
               event_type: "repository.updated",
               origin: :fornacast,
               payload: %{"repository_id" => repository_mirror.repository_id},
               available_at: now
             })
             |> Repo.transaction()

    assert {:ok, [{:ok, ^event_id, [operation_id]}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("outbox-test", now,
               lease_seconds: 30,
               batch_size: 1
             )

    assert Repo.get!(DomainOutboxEvent, event.id).state == :completed
    operation = Repo.get!(MirrorOperation, operation_id)
    assert operation.repository_mirror_id == repository_mirror.id
    assert operation.state == :pending
    assert {:ok, []} = ForgeMirrors.claim_operations("worker", now, 30, 1)
  end

  test "conflict database uniqueness coalesces organization-level null repository IDs" do
    organization_mirror = active_organization_mirror_fixture()

    attrs = %{
      organization_mirror_id: organization_mirror.id,
      resource_kind: "organization",
      resource_identity: "inventory",
      conflict_kind: "permission_missing",
      baseline_snapshot: %{},
      local_snapshot: %{},
      remote_snapshot: %{}
    }

    assert {:ok, %MirrorConflict{}} = ForgeMirrors.record_conflict(attrs)
    assert {:ok, %MirrorConflict{}} = ForgeMirrors.record_conflict(attrs)

    assert Repo.aggregate(
             from(conflict in MirrorConflict,
               where:
                 conflict.organization_mirror_id == ^organization_mirror.id and
                   conflict.state == :open
             ),
             :count
           ) == 1
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
