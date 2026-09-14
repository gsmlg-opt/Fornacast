defmodule ForgeMirrors.ReleaseSyncPersistenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.{DomainOutboxEvent, Repo}
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, OrganizationMirror, ResourceInventory}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{capabilities: %{"releases" => "enabled"}})

    binding = repository_mirror_fixture(organization)
    release = release_fixture(binding.repository_id, organization_owner_fixture(organization).id)

    %{
      organization: organization,
      binding: binding,
      release: release,
      now: DateTime.utc_now(:second)
    }
  end

  test "local release events materialize one durable idempotent operation and GitHub echoes do not",
       c do
    event = release_event(c, "release.updated")

    assert {:ok, {:materialized, [operation]}} = ForgeMirrors.materialize_outbox_event(event)
    assert {:ok, {:materialized, [replay]}} = ForgeMirrors.materialize_outbox_event(event)
    assert replay.id == operation.id
    assert operation.kind == "sync.release"
    assert operation.repository_mirror_id == c.binding.id

    assert operation.cursor == %{
             "causation_id" => nil,
             "correlation_id" => nil,
             "deleted" => false,
             "event_type" => "release.updated",
             "local_resource_id" => c.release.id,
             "origin" => "fornacast",
             "outbox_event_id" => event.event_id,
             "repository_id" => c.binding.repository_id,
             "sync_version" => 1,
             "tag_name" => "v1.0.0",
             "trigger" => "local"
           }

    github_event = %{release_event(c, "release.updated") | origin: :github}

    assert {:ok, {:ignored, :non_local_event}} =
             ForgeMirrors.materialize_outbox_event(github_event)

    assert Repo.aggregate(
             from(operation in MirrorOperation, where: operation.kind == "sync.release"),
             :count
           ) == 1
  end

  test "release outbox identity is checked against the authoritative row", c do
    event = release_event(c, "release.updated")

    for forged <- [
          %{event | aggregate_id: "999999"},
          %{event | event_type: "release.asset_uploaded"},
          put_in(event.payload["repository_id"], c.binding.repository_id + 1),
          put_in(event.payload["release_id"], c.release.id + 1),
          put_in(event.payload["sync_version"], 0)
        ] do
      assert {:error, :invalid_payload} = ForgeMirrors.materialize_outbox_event(forged)
    end

    refute Repo.exists?(
             from operation in MirrorOperation, where: operation.kind == "sync.release"
           )
  end

  test "a stale release event cannot pin mutable tag state or poison repository FIFO", c do
    event = release_event(c, "release.updated")

    Ecto.Adapters.SQL.query!(
      Repo,
      "update releases set tag_name = 'v2.0.0', sync_version = 2 where id = $1",
      [c.release.id]
    )

    assert {:ok, {:materialized, [operation]}} = ForgeMirrors.materialize_outbox_event(event)
    operation = claim!(operation, c.now, ["sync.release"])

    assert {:ok, context} = ForgeMirrors.release_operation_context(operation)
    assert context.local_version == 2
    assert context.tag_name == "v2.0.0"
  end

  test "release capability, pause, binding, and revocation fence materialization", c do
    c.organization
    |> OrganizationMirror.update_changeset(%{capabilities: %{"releases" => "disabled"}})
    |> Repo.update!()

    assert {:ok, {:ignored, :capability_disabled}} =
             ForgeMirrors.materialize_outbox_event(release_event(c, "release.updated"))

    Repo.get!(OrganizationMirror, c.organization.id)
    |> OrganizationMirror.update_changeset(%{capabilities: %{"releases" => "enabled"}})
    |> Repo.update!()

    actor = organization_owner_fixture(c.organization)

    assert {:ok, _paused} =
             ForgeMirrors.pause(actor, Repo.get!(OrganizationMirror, c.organization.id))

    assert {:ok, {:materialized, [operation]}} =
             ForgeMirrors.materialize_outbox_event(release_event(c, "release.updated"))

    assert operation.state == :pending

    assert {:ok, []} =
             ForgeMirrors.claim_operations("paused-release", c.now, 30, 1, ["sync.release"])

    Repo.get!(OrganizationMirror, c.organization.id)
    |> Ecto.Changeset.change(state: :revoked, resume_state: nil)
    |> Repo.update!()

    assert {:ok, {:ignored, :unmirrored_owner}} =
             ForgeMirrors.materialize_outbox_event(release_event(c, "release.updated"))
  end

  test "signed release delivery retains immutable remote identity and deduplicates", c do
    delivery = release_delivery(c, "edited", 44_001, "v1.0.0")
    hints = release_hints(44_001, "v1.0.0")

    assert {:ok, {:scheduled, operation}} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, hints)

    assert {:ok, {:scheduled, replay}} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, hints)

    assert replay.id == operation.id
    assert operation.kind == "sync.release"

    assert operation.cursor == %{
             "delivery_guid" => delivery.delivery_guid,
             "github_object_id" => 44_001,
             "release_action" => "edited",
             "resource_kind" => "release",
             "tag_name" => "v1.0.0",
             "trigger" => "remote"
           }

    assert {:error, :invalid_delivery} =
             ForgeMirrors.retain_webhook_resource_trigger(
               delivery,
               release_hints(44_001, "forged")
             )

    assert {:error, :invalid_argument} =
             ForgeMirrors.retain_webhook_resource_trigger(
               delivery,
               Map.put(hints, "body", "untrusted mutable data")
             )
  end

  test "paused release delivery is retained but cannot reach an effect boundary", c do
    actor = organization_owner_fixture(c.organization)
    assert {:ok, _paused} = ForgeMirrors.pause(actor, c.organization)

    delivery = release_delivery(c, "published", 44_002, "v2.0.0")

    assert {:ok, {:scheduled, operation}} =
             ForgeMirrors.retain_webhook_resource_trigger(
               delivery,
               release_hints(44_002, "v2.0.0")
             )

    assert operation.state == :pending

    assert {:ok, []} =
             ForgeMirrors.claim_operations("paused-webhook-release", c.now, 30, 1, [
               "sync.release"
             ])
  end

  test "release reconciliation is capability-gated and emits bounded remote children", c do
    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: c.binding.id,
      resource_kind: :release,
      local_resource_type: "ForgeReleases.Release",
      local_resource_id: c.release.id,
      github_object_id: 44_004,
      github_node_id: "RE_44004",
      confirmed_local_version: 1,
      confirmed_remote_updated_at: c.now,
      confirmed_snapshot: %{
        "tag_name" => "v1.0.0",
        "name" => "One",
        "body" => "Body",
        "draft" => false,
        "prerelease" => false,
        "target_commitish" => "main",
        "published_at" => DateTime.to_iso8601(c.now)
      },
      state: :confirmed,
      lock_version: 1
    })
    |> Repo.insert!()

    assert {:ok, [sweep]} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(
               c.binding,
               "inventory:release",
               c.now
             )

    assert sweep.kind == "reconcile.repository.releases"
    assert sweep.cursor["resource_kind"] == "release"

    sweep = claim!(sweep, c.now, ["reconcile.repository.releases"])
    observed_at = DateTime.add(c.now, 1)

    assert {:ok, %{operation: yielded, operations: [child]}} =
             ForgeMirrors.record_resource_reconciliation_page(
               sweep,
               :release,
               [
                 %{
                   github_object_id: 44_003,
                   tag_name: "v3.0.0",
                   remote_updated_at: observed_at
                 }
               ],
               nil,
               c.now
             )

    assert yielded.state == :pending
    assert child.kind == "sync.release"
    assert child.cursor["trigger"] == "reconcile"
    assert child.cursor["tag_name"] == "v3.0.0"
    assert child.cursor["github_object_id"] == 44_003

    mapped_sweep = claim!(yielded, c.now, ["reconcile.repository.releases"])

    assert {:ok, %{phase: :mapped, mapping_cursor: nil}} =
             ForgeMirrors.release_operation_context(mapped_sweep)

    assert {:ok, %{observations: [mapped], next_cursor: nil}} =
             ResourceInventory.page(c.binding.id, :release)

    assert mapped == %{
             github_object_id: 44_004,
             tag_name: "v1.0.0",
             remote_updated_at: c.now
           }

    assert {:ok, %{operation: completed, operations: [mapped_child]}} =
             ForgeMirrors.record_resource_reconciliation_page(
               mapped_sweep,
               :release,
               [mapped],
               nil,
               c.now
             )

    assert completed.state == :completed
    assert mapped_child.kind == "sync.release"
    assert mapped_child.cursor["github_object_id"] == 44_004
    assert mapped_child.cursor["tag_name"] == "v1.0.0"

    assert {:error, :invalid_argument} =
             ForgeMirrors.record_resource_reconciliation_page(
               sweep,
               :release,
               [%{github_object_id: 44_003, tag_name: "v3.0.0", body: "not routing"}],
               nil,
               c.now
             )
  end

  test "release operation context exposes only authoritative domain state and mapping", c do
    event = release_event(c, "release.updated")
    assert {:ok, {:materialized, [operation]}} = ForgeMirrors.materialize_outbox_event(event)
    operation = claim!(operation, c.now, ["sync.release"])

    assert {:ok, context} = ForgeMirrors.release_operation_context(operation)
    assert context.resource_kind == :release
    assert context.repository_id == c.binding.repository_id
    assert context.local_resource_id == c.release.id
    assert context.local_version == 1
    assert context.local_deleted == false
    assert context.tag_name == "v1.0.0"
    assert context.tag_proof == :required
    assert context.baseline == :missing
    refute Map.has_key?(context, :author_user_id)
  end

  test "release mirror boundaries and inventory accept 255-character multibyte tags", c do
    tag_name = String.duplicate("界", 255)

    Ecto.Adapters.SQL.query!(
      Repo,
      "update releases set tag_name = $1 where id = $2",
      [tag_name, c.release.id]
    )

    event = put_in(release_event(c, "release.updated").payload["tag_name"], tag_name)

    assert {:ok, {:materialized, [local_operation]}} =
             ForgeMirrors.materialize_outbox_event(event)

    local_operation = claim!(local_operation, c.now, ["sync.release"])
    assert {:ok, %{state: :completed}} = ForgeMirrors.complete_operation(local_operation, c.now)

    delivery = release_delivery(c, "edited", 44_005, tag_name)

    assert {:ok, {:scheduled, remote_operation}} =
             ForgeMirrors.retain_webhook_resource_trigger(
               delivery,
               release_hints(44_005, tag_name)
             )

    remote_operation = claim!(remote_operation, c.now, ["sync.release"])
    assert {:ok, %{state: :completed}} = ForgeMirrors.complete_operation(remote_operation, c.now)

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: c.binding.id,
      resource_kind: :release,
      local_resource_type: "ForgeReleases.Release",
      local_resource_id: c.release.id,
      github_object_id: 44_006,
      github_node_id: "RE_44006",
      confirmed_local_version: 1,
      confirmed_remote_updated_at: c.now,
      confirmed_snapshot: %{"tag_name" => tag_name},
      state: :confirmed,
      lock_version: 1
    })
    |> Repo.insert!()

    assert {:ok, %{observations: [%{tag_name: ^tag_name}], next_cursor: nil}} =
             ResourceInventory.page(c.binding.id, :release)

    assert {:ok, [sweep]} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(
               c.binding,
               "inventory:multibyte-release",
               c.now
             )

    sweep = claim!(sweep, c.now, ["reconcile.repository.releases"])

    assert {:ok, %{operations: [%{cursor: %{"tag_name" => ^tag_name}}]}} =
             ForgeMirrors.record_resource_reconciliation_page(
               sweep,
               :release,
               [
                 %{
                   github_object_id: 44_007,
                   tag_name: tag_name,
                   remote_updated_at: c.now
                 }
               ],
               nil,
               c.now
             )
  end

  defp release_fixture(repository_id, author_user_id) do
    now = DateTime.utc_now(:second)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into releases (repository_id, tag_name, name, body, draft, prerelease, target_commitish, published_at, author_user_id, sync_version, inserted_at, updated_at) values ($1, 'v1.0.0', 'One', 'Body', false, false, 'main', $2, $3, 1, $2, $2) returning id",
        [repository_id, now, author_user_id]
      )

    %{id: id, repository_id: repository_id}
  end

  defp release_event(c, event_type) do
    %DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "release",
      aggregate_id: to_string(c.release.id),
      event_type: event_type,
      origin: :fornacast,
      available_at: c.now,
      payload: %{
        "repository_id" => c.binding.repository_id,
        "release_id" => c.release.id,
        "tag_name" => "v1.0.0",
        "sync_version" => 1,
        "deleted" => false
      }
    }
  end

  defp release_hints(id, tag_name),
    do: %{
      "resource_kind" => "release",
      "github_object_id" => id,
      "tag_name" => tag_name
    }

  defp release_delivery(c, action, id, tag_name) do
    payload = %{
      "action" => action,
      "installation" => %{"id" => c.organization.github_installation_id},
      "repository" => %{"id" => c.binding.github_repository_id},
      "release" => %{"id" => id, "tag_name" => tag_name, "body" => "not retained"}
    }

    {:ok, delivery, :enqueued} =
      ForgeMirrors.enqueue_webhook_delivery(
        %{
          organization_mirror_id: c.organization.id,
          delivery_guid: Ecto.UUID.generate(),
          hook_id: 1,
          event: "release",
          action: action,
          installation_id: c.organization.github_installation_id,
          github_repository_id: c.binding.github_repository_id,
          signature_version: "sha256",
          raw_payload: JSON.encode!(payload)
        },
        :pending_unsupported
      )

    delivery
  end

  defp claim!(operation, now, kinds) do
    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("release-persistence", now, 60, 1, kinds)

    assert claimed.id == operation.id
    claimed
  end
end
