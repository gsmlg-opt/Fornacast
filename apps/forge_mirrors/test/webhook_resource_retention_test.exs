defmodule ForgeMirrors.WebhookResourceRetentionTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{MirrorOperation, OrganizationMirror}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"issues" => "enabled", "pulls" => "disabled"}
      })

    binding = repository_mirror_fixture(organization)
    %{organization: organization, binding: binding}
  end

  test "persisted signed issue hints create idempotent remote work without mutable payload",
       context do
    hints = issue_hints()

    delivery =
      delivery(context, "issues", %{
        "issue" => %{"id" => 123, "number" => 7, "body" => "never persist this body"}
      })

    assert {:ok, {:scheduled, operation}} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, hints)

    assert {:ok, {:scheduled, replay}} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, hints)

    assert operation.id == replay.id
    assert operation.kind == "sync.issue"

    assert operation.cursor ==
             Map.merge(hints, %{"trigger" => "remote", "delivery_guid" => delivery.delivery_guid})
  end

  test "distinct duplicate and out-of-order resource deliveries retain only immutable triggers",
       context do
    context.organization
    |> OrganizationMirror.update_changeset(%{
      capabilities: %{"issues" => "enabled", "pulls" => "enabled", "releases" => "enabled"}
    })
    |> Repo.update!()

    for {event, resource, hints, kind} <- [
          {"issues", %{"issue" => %{"id" => 123, "number" => 7}}, issue_hints(), "sync.issue"},
          {"issue_comment",
           %{"issue" => %{"id" => 123, "number" => 7}, "comment" => %{"id" => 456}},
           %{
             "resource_kind" => "issue_comment",
             "github_object_id" => 456,
             "github_number" => 7,
             "github_issue_id" => 123,
             "issue_kind" => "issue"
           }, "sync.issue_comment"},
          {"pull_request", %{"pull_request" => %{"id" => 789, "number" => 7}},
           %{
             "resource_kind" => "pull",
             "github_object_id" => 789,
             "github_number" => 7,
             "issue_kind" => "pull_request"
           }, "sync.pull"},
          {"release", %{"release" => %{"id" => 987, "tag_name" => "v1.0.0"}},
           %{"resource_kind" => "release", "github_object_id" => 987, "tag_name" => "v1.0.0"},
           "sync.release"}
        ] do
      newer = delivery(context, event, put_mutable_body(resource, "newer payload"))
      older = delivery(context, event, put_mutable_body(resource, "older payload"))

      assert {:ok, {:scheduled, first}} =
               ForgeMirrors.retain_webhook_resource_trigger(newer, hints)

      assert {:ok, {:scheduled, second}} =
               ForgeMirrors.retain_webhook_resource_trigger(older, hints)

      assert first.id != second.id
      assert first.kind == kind
      assert second.kind == kind

      for operation <- [first, second] do
        expected_cursor =
          hints
          |> Map.merge(%{
            "trigger" => "remote",
            "delivery_guid" => operation.cursor["delivery_guid"]
          })
          |> then(fn cursor ->
            if kind == "sync.release",
              do: Map.put(cursor, "release_action", "edited"),
              else: cursor
          end)

        assert operation.cursor ==
                 expected_cursor

        refute Map.has_key?(operation.cursor, "body")
        refute Map.has_key?(operation.cursor, "title")
      end
    end
  end

  test "forged routes or object identities cannot borrow a persisted delivery", context do
    delivery = delivery(context, "issues", %{"issue" => %{"id" => 123, "number" => 7}})
    hints = issue_hints()

    for forged <- [
          %{delivery | installation_id: delivery.installation_id + 1},
          %{delivery | github_repository_id: delivery.github_repository_id + 1},
          %{delivery | raw_payload: "{}"},
          %{delivery | id: nil}
        ] do
      assert {:error, :invalid_delivery} =
               ForgeMirrors.retain_webhook_resource_trigger(forged, hints)
    end

    assert {:error, :invalid_delivery} =
             ForgeMirrors.retain_webhook_resource_trigger(
               delivery,
               %{hints | "github_object_id" => 321}
             )

    assert {:error, :invalid_argument} =
             ForgeMirrors.retain_webhook_resource_trigger(
               delivery,
               Map.put(hints, "body", "untrusted mutable content")
             )
  end

  test "pull comments require pulls capability and preserve immutable parent issue identity",
       context do
    delivery =
      delivery(context, "issue_comment", %{
        "issue" => %{"id" => 123, "number" => 7, "pull_request" => %{}},
        "comment" => %{"id" => 456}
      })

    hints = %{
      "resource_kind" => "issue_comment",
      "github_object_id" => 456,
      "github_number" => 7,
      "github_issue_id" => 123,
      "issue_kind" => "pull_request"
    }

    assert {:ok, :deferred} = ForgeMirrors.retain_webhook_resource_trigger(delivery, hints)

    context.organization
    |> OrganizationMirror.update_changeset(%{
      capabilities: %{"issues" => "disabled", "pulls" => "enabled"}
    })
    |> Repo.update!()

    assert {:ok, {:scheduled, %{kind: "sync.issue_comment", cursor: cursor}}} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, hints)

    assert cursor["github_issue_id"] == 123
  end

  test "persisted organization and raw route must agree with the installation", context do
    delivery = delivery(context, "issues", %{"issue" => %{"id" => 123, "number" => 7}})
    other = active_organization_mirror_fixture()

    mismatched =
      delivery |> Ecto.Changeset.change(organization_mirror_id: other.id) |> Repo.update!()

    assert {:error, :invalid_delivery} =
             ForgeMirrors.retain_webhook_resource_trigger(mismatched, issue_hints())

    payload = JSON.decode!(delivery.raw_payload) |> Map.put("repository", %{"id" => 999_999})

    mismatched =
      mismatched
      |> Ecto.Changeset.change(
        organization_mirror_id: context.organization.id,
        raw_payload: JSON.encode!(payload)
      )
      |> Repo.update!()

    assert {:error, :invalid_delivery} =
             ForgeMirrors.retain_webhook_resource_trigger(mismatched, issue_hints())
  end

  test "pull identities use the PR object id and never the shared issue id", context do
    context.organization
    |> OrganizationMirror.update_changeset(%{capabilities: %{"pulls" => "enabled"}})
    |> Repo.update!()

    delivery =
      delivery(context, "pull_request", %{"pull_request" => %{"id" => 789, "number" => 7}})

    hints = %{
      "resource_kind" => "pull",
      "github_object_id" => 789,
      "github_number" => 7,
      "issue_kind" => "pull_request"
    }

    assert {:ok, {:scheduled, %{kind: "sync.pull"}}} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, hints)
  end

  test "comment routing treats a null pull marker as an issue and rejects malformed markers",
       context do
    hints = %{
      "resource_kind" => "issue_comment",
      "github_object_id" => 456,
      "github_number" => 7,
      "github_issue_id" => 123,
      "issue_kind" => "issue"
    }

    for marker <- [nil, "invalid"] do
      delivery =
        delivery(context, "issue_comment", %{
          "issue" => %{"id" => 123, "number" => 7, "pull_request" => marker},
          "comment" => %{"id" => 456}
        })

      result = ForgeMirrors.retain_webhook_resource_trigger(delivery, hints)

      if is_nil(marker),
        do: assert(match?({:ok, {:scheduled, _}}, result)),
        else: assert(result == {:error, :invalid_delivery})
    end
  end

  test "action mismatches reject and conflicted organizations retain independent triggers",
       context do
    delivery = delivery(context, "issues", %{"issue" => %{"id" => 123, "number" => 7}})
    mismatched = delivery |> Ecto.Changeset.change(action: "deleted") |> Repo.update!()

    assert {:error, :invalid_delivery} =
             ForgeMirrors.retain_webhook_resource_trigger(mismatched, issue_hints())

    restored = mismatched |> Ecto.Changeset.change(action: "edited") |> Repo.update!()
    context.organization |> Ecto.Changeset.change(state: :conflicted) |> Repo.update!()

    assert {:ok, {:scheduled, _}} =
             ForgeMirrors.retain_webhook_resource_trigger(restored, issue_hints())
  end

  test "paused retains work but bootstrap and revoked connections defer", context do
    delivery = delivery(context, "issues", %{"issue" => %{"id" => 123, "number" => 7}})
    actor = organization_owner_fixture(context.organization)
    assert {:ok, paused} = ForgeMirrors.pause(actor, context.organization)

    assert {:ok, {:scheduled, _operation}} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, issue_hints())

    assert {:ok, []} =
             ForgeMirrors.claim_operations("paused-resources", DateTime.utc_now(:second), 30, 1, [
               "sync.issue"
             ])

    for state <- [:bootstrapping, :revoked] do
      paused |> Ecto.Changeset.change(state: state, resume_state: nil) |> Repo.update!()

      assert {:ok, :deferred} =
               ForgeMirrors.retain_webhook_resource_trigger(delivery, issue_hints())
    end
  end

  test "unpublished local bindings defer without creating an operation", context do
    delivery = delivery(context, "issues", %{"issue" => %{"id" => 123, "number" => 7}})

    context.binding
    |> Ecto.Changeset.change(repository_id: nil, state: :discovered)
    |> Repo.update!()

    assert {:ok, :deferred} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, issue_hints())

    refute Repo.exists?(from operation in MirrorOperation, where: operation.kind == "sync.issue")
  end

  test "an importing local repository cannot receive metadata operations", context do
    delivery = delivery(context, "issues", %{"issue" => %{"id" => 123, "number" => 7}})

    Repo.get!(ForgeRepos.Repository, context.binding.repository_id)
    |> Ecto.Changeset.change(lifecycle: :importing)
    |> Repo.update!()

    assert {:ok, :deferred} =
             ForgeMirrors.retain_webhook_resource_trigger(delivery, issue_hints())
  end

  defp issue_hints,
    do: %{
      "resource_kind" => "issue",
      "github_object_id" => 123,
      "github_number" => 7,
      "issue_kind" => "issue"
    }

  defp put_mutable_body(%{"comment" => comment} = resource, body),
    do: %{resource | "comment" => Map.put(comment, "body", body)}

  defp put_mutable_body(%{"issue" => issue} = resource, body),
    do: %{resource | "issue" => Map.put(issue, "body", body)}

  defp put_mutable_body(%{"pull_request" => pull} = resource, body),
    do: %{resource | "pull_request" => Map.put(pull, "body", body)}

  defp put_mutable_body(%{"release" => release} = resource, body),
    do: %{resource | "release" => Map.put(release, "body", body)}

  defp delivery(context, event, resource) do
    payload =
      Map.merge(resource, %{
        "installation" => %{"id" => context.organization.github_installation_id},
        "repository" => %{"id" => context.binding.github_repository_id},
        "action" => "edited"
      })

    {:ok, delivery, :enqueued} =
      ForgeMirrors.enqueue_webhook_delivery(
        %{
          organization_mirror_id: context.organization.id,
          delivery_guid: Ecto.UUID.generate(),
          hook_id: 1,
          event: event,
          action: "edited",
          installation_id: context.organization.github_installation_id,
          github_repository_id: context.binding.github_repository_id,
          signature_version: "sha256",
          raw_payload: JSON.encode!(payload)
        },
        :pending_unsupported
      )

    delivery
  end
end
