defmodule ForgeMirrors.IssueOutboxMaterializationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.{DomainOutboxEvent, Repo}
  alias ForgeMirrors.{MirrorOperation, OrganizationMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(DomainOutboxEvent)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"issues" => "enabled", "pulls" => "disabled"}
      })

    binding = repository_mirror_fixture(organization)
    issue = issue_fixture(binding.repository_id, organization_owner_fixture(organization).id)
    %{organization: organization, binding: binding, issue: issue}
  end

  test "issue events become idempotent durable versioned operations before acknowledgement",
       context do
    event = %{event(context) | causation_id: "delivery-1", correlation_id: "operation-1"}
    assert {:ok, {:materialized, [operation]}} = ForgeMirrors.materialize_outbox_event(event)
    assert {:ok, {:materialized, [replay]}} = ForgeMirrors.materialize_outbox_event(event)
    assert replay.id == operation.id
    assert operation.kind == "sync.issue"
    assert operation.repository_mirror_id == context.binding.id
    assert operation.cursor["issue_id"] == context.issue.id
    assert operation.cursor["sync_version"] == 1
    assert operation.cursor["outbox_event_id"] == event.event_id
    assert operation.cursor["origin"] == "fornacast"
    assert operation.cursor["causation_id"] == "delivery-1"
    assert operation.cursor["correlation_id"] == "operation-1"
    assert Repo.get!(MirrorOperation, operation.id).state == :pending
  end

  test "comment deletion materializes its tombstone without requiring the vanished row",
       context do
    event = comment_event(context, "issue_comment.deleted")
    assert {:ok, {:materialized, [operation]}} = ForgeMirrors.materialize_outbox_event(event)
    assert operation.kind == "sync.issue_comment"
    assert operation.cursor["comment_id"] == 9_000_001
    assert operation.cursor["deleted"] == true
    assert operation.cursor["issue_id"] == context.issue.id
    assert operation.cursor["sync_version"] == 3

    assert operation.cursor["author_user_id"] ==
             organization_owner_fixture(context.organization).id
  end

  test "malformed identity and cross-repository issue references are rejected", context do
    original = event(context)
    other_repository_id = repository_fixture(context.organization.organization_id)

    for forged <- [
          %{original | aggregate_id: "999999"},
          %{original | event_type: "issue_comment.updated"},
          put_in(original.payload["repository_id"], other_repository_id),
          put_in(original.payload["issue_kind"], "pull_request"),
          put_in(original.payload["issue_number"], 400),
          put_in(original.payload["sync_version"], 0)
        ] do
      assert {:error, :invalid_payload} = ForgeMirrors.materialize_outbox_event(forged)
    end

    refute Repo.exists?(from operation in MirrorOperation, where: operation.kind == "sync.issue")
  end

  test "GitHub origin never echoes outbound", context do
    assert {:ok, {:ignored, :non_local_event}} =
             ForgeMirrors.materialize_outbox_event(%{event(context) | origin: :github})

    refute Repo.exists?(from operation in MirrorOperation, where: operation.kind == "sync.issue")
  end

  test "issues and shared pull conversations obey separate capability policies", context do
    context.organization
    |> OrganizationMirror.update_changeset(%{
      capabilities: %{"issues" => "disabled", "pulls" => "enabled"}
    })
    |> Repo.update!()

    assert {:ok, {:ignored, :capability_disabled}} =
             ForgeMirrors.materialize_outbox_event(event(context))

    pull =
      issue_fixture(
        context.binding.repository_id,
        organization_owner_fixture(context.organization).id,
        "pull_request",
        2
      )

    pull_context = %{context | issue: pull}

    assert {:ok, {:materialized, [%{kind: "sync.pull"}]}} =
             ForgeMirrors.materialize_outbox_event(event(pull_context))

    assert {:ok, {:materialized, [%{kind: "sync.issue_comment"}]}} =
             ForgeMirrors.materialize_outbox_event(
               comment_event(pull_context, "issue_comment.deleted")
             )
  end

  test "paused organizations retain intent without making it claimable", context do
    actor = organization_owner_fixture(context.organization)
    assert {:ok, _paused} = ForgeMirrors.pause(actor, context.organization)

    assert {:ok, {:materialized, [_operation]}} =
             ForgeMirrors.materialize_outbox_event(event(context))

    assert {:ok, []} =
             ForgeMirrors.claim_operations("paused-issues", DateTime.utc_now(:second), 30, 1, [
               "sync.issue"
             ])
  end

  test "unbound repositories retain retryable intent instead of acknowledging it", context do
    Repo.delete!(context.binding)
    assert {:error, :unbound_repository} = ForgeMirrors.materialize_outbox_event(event(context))
  end

  test "dispatcher acknowledges only after the issue operation is durable", context do
    event = Repo.insert!(event(context))
    now = DateTime.utc_now(:second)

    assert {:ok, [{:ok, event_id, {:materialized, [operation_id]}}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("issue-dispatch", now, batch_size: 1)

    assert event_id == event.event_id
    assert Repo.get!(DomainOutboxEvent, event.id).state == :completed
    assert Repo.get!(MirrorOperation, operation_id).cursor["issue_id"] == context.issue.id
  end

  test "earlier vanished-comment events advance when a durable later tombstone proves identity",
       context do
    tombstone = comment_event(context, "issue_comment.deleted")
    Repo.insert!(tombstone)

    earlier =
      comment_event(context, "issue_comment.created")
      |> put_in([Access.key!(:payload), "sync_version"], 1)

    assert {:ok, {:materialized, [operation]}} = ForgeMirrors.materialize_outbox_event(earlier)
    assert operation.cursor["deleted"] == false
    assert operation.cursor["sync_version"] == 1
    assert operation.cursor["comment_id"] == tombstone.payload["comment_id"]
  end

  test "malformed later deletion metadata does not authorize a vanished comment event", context do
    comment_event(context, "issue_comment.deleted")
    |> put_in([Access.key!(:payload), "deleted"], false)
    |> Repo.insert!()

    earlier =
      comment_event(context, "issue_comment.created")
      |> put_in([Access.key!(:payload), "sync_version"], 1)

    assert {:error, :invalid_payload} = ForgeMirrors.materialize_outbox_event(earlier)
  end

  defp event(context) do
    %DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "issue",
      aggregate_id: to_string(context.issue.id),
      event_type: "issue.updated",
      origin: :fornacast,
      available_at: DateTime.utc_now(:second),
      payload: %{
        "repository_id" => context.binding.repository_id,
        "issue_id" => context.issue.id,
        "issue_number" => context.issue.number,
        "issue_kind" => context.issue.kind,
        "sync_version" => 1
      }
    }
  end

  defp comment_event(context, type) do
    original = event(context)

    %{
      original
      | aggregate_type: "issue_comment",
        aggregate_id: "9000001",
        event_type: type,
        payload:
          Map.merge(original.payload, %{
            "comment_id" => 9_000_001,
            "deleted" => type == "issue_comment.deleted",
            "sync_version" => 3,
            "author_user_id" => organization_owner_fixture(context.organization).id,
            "author_github_identity_id" => nil
          })
    }
  end

  defp issue_fixture(repository_id, actor_id, kind \\ "issue", number \\ 1) do
    now = DateTime.utc_now(:second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "issues",
        [
          %{
            repository_id: repository_id,
            number: number,
            kind: kind,
            title: "Resource",
            state: "open",
            author_user_id: actor_id,
            sync_version: 1,
            inserted_at: now,
            updated_at: now
          }
        ], returning: [:id])

    %{id: id, kind: kind, number: number}
  end
end
