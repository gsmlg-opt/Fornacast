defmodule ForgePulls.SyncTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.Issue
  alias ForgePulls.PullRequest
  alias Fornacast.{DomainOutboxEvent, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "pull-sync-#{suffix}",
        email: "pull-sync-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{name: "sync", slug: "sync", visibility: :private})

    {:ok, %{issue: issue}} =
      Multi.new()
      |> ForgeIssues.insert_numbered_identity(:issue, repository, actor, :pull_request, %{
        title: "Original"
      })
      |> Repo.transaction()

    pull =
      %PullRequest{}
      |> PullRequest.create_changeset(%{
        issue_id: issue.id,
        repository_id: repository.id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })
      |> Repo.insert!()

    fields = %{
      "title" => "Original",
      "body" => nil,
      "state" => "open",
      "state_reason" => nil,
      "draft" => false,
      "head_ref" => pull.head_ref,
      "base_ref" => pull.base_ref,
      "head_sha" => pull.head_sha,
      "base_sha" => pull.base_sha
    }

    request = %{
      repository_id: repository.id,
      resource_kind: :pull,
      local_resource_id: pull.id,
      expected_local_version: issue.sync_version,
      expected_merge_state: %{merged_at: nil, merge_commit_sha: nil},
      expected_fields: fields,
      fields: %{fields | "title" => "Remote", "draft" => true},
      action: :update,
      provenance: %{origin: :github, causation_id: "delivery", correlation_id: "operation"}
    }

    %{
      actor: actor,
      repository: repository,
      issue: issue,
      pull: pull,
      fields: fields,
      request: request
    }
  end

  test "projection uses canonical issue version and immutable routing identity", ctx do
    assert {:ok, projection} = ForgePulls.sync_projection(ctx.repository.id, :pull, ctx.pull.id)
    assert projection.fields == ctx.fields
    assert projection.issue_id == ctx.issue.id
    assert projection.local_version == ctx.issue.sync_version
    assert projection.local_resource_type == "ForgePulls.PullRequest"
    assert projection.head_repository_id == ctx.repository.id

    assert {:error, :not_found} =
             ForgePulls.sync_projection(ctx.repository.id + 1000, :pull, ctx.pull.id)
  end

  test "sync locks canonical issue before its pull extension", ctx do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:fornacast, :repo, :query],
        fn _, _, metadata, pid ->
          if String.contains?(metadata.query, "FOR UPDATE"),
            do: send(pid, {:sync_lock_source, metadata.source})
        end,
        parent
      )

    try do
      assert {:ok, _} = ForgePulls.sync_projection(ctx.repository.id, :pull, ctx.pull.id)
      assert_receive {:sync_lock_source, first}
      assert first == "issues"
      assert_receive {:sync_lock_source, second}
      assert second == "pull_requests"
    after
      :telemetry.detach(handler)
    end
  end

  test "apply atomically advances canonical version and records trusted github provenance", ctx do
    assert {:ok, %{resource: projection}} = apply_request(ctx.request)
    assert projection.fields["draft"]
    assert projection.fields["title"] == "Remote"
    assert projection.local_version == ctx.issue.sync_version + 1
    assert Repo.get!(Issue, ctx.issue.id).author_user_id == ctx.actor.id
    assert [event] = github_events(ctx)
    assert event.causation_id == "delivery"
    assert event.payload["issue_kind"] == "pull_request"
    refute Map.has_key?(event.payload, "title")
  end

  test "observe requires exact full snapshot even when ref refresh did not advance version",
       ctx do
    assert {:ok, %{resource: observed}} = observe(ctx.request)
    assert observed.local_version == ctx.issue.sync_version
    Repo.update!(Changeset.change(ctx.pull, head_sha: String.duplicate("c", 40)))
    assert {:error, :resource, :stale_local_snapshot, _} = observe(ctx.request)
    assert {:error, _, :stale_local_snapshot, _} = apply_request(ctx.request)
    assert github_events(ctx) == []
  end

  test "recovery observation preserves newer local metadata but requires matching refs and merge state",
       ctx do
    expected =
      ctx.request
      |> Map.delete(:expected_local_version)
      |> Map.put(:minimum_local_version, ctx.issue.sync_version)

    updated = ctx.issue |> Issue.update_changeset(%{title: "New local edit"}) |> Repo.update!()
    assert {:ok, %{resource: projection}} = observe(expected)
    assert projection.local_version == updated.sync_version
    assert projection.fields["title"] == "New local edit"
    assert github_events(ctx) == []

    assert {:error, _, :invalid_sync_request, _} = apply_request(expected)

    assert {:error, _, :invalid_sync_request, _} =
             observe(Map.put(expected, :expected_local_version, ctx.issue.sync_version))

    assert {:error, _, :stale_local_version, _} =
             observe(%{expected | minimum_local_version: updated.sync_version + 1})

    Repo.update!(Changeset.change(ctx.pull, head_sha: String.duplicate("c", 40)))
    assert {:error, _, :stale_local_snapshot, _} = observe(expected)

    Repo.get!(PullRequest, ctx.pull.id)
    |> Changeset.change(
      head_sha: ctx.pull.head_sha,
      merged_at: ~U[2026-09-08 00:00:00Z],
      merge_commit_sha: String.duplicate("d", 40)
    )
    |> Repo.update!()

    assert {:error, _, :stale_local_snapshot, _} = observe(expected)
  end

  test "stale versions and later transaction errors preserve both rows", ctx do
    assert {:error, _, :stale_local_version, _} =
             apply_request(%{ctx.request | expected_local_version: ctx.issue.sync_version + 1})

    assert {:error, :later, :rollback, _} =
             Multi.new()
             |> ForgePulls.append_sync_apply(:resource, ctx.request)
             |> Multi.error(:later, :rollback)
             |> Repo.transaction()

    assert Repo.get!(Issue, ctx.issue.id).title == "Original"
    refute Repo.get!(PullRequest, ctx.pull.id).draft
    assert github_events(ctx) == []
  end

  test "immutable heads, merge effects and forged provenance are rejected", ctx do
    assert {:error, _, :immutable_identity, _} =
             apply_request(%{
               ctx.request
               | fields: %{ctx.request.fields | "head_ref" => "refs/heads/other"}
             })

    for request <- [
          %{ctx.request | action: :create},
          %{ctx.request | provenance: %{origin: :fornacast}},
          %{
            ctx.request
            | fields: Map.put(ctx.request.fields, "merge_commit_sha", String.duplicate("c", 40))
          }
        ] do
      assert {:error, _, :invalid_sync_request, _} = apply_request(request)
    end

    merged =
      Repo.update!(
        Changeset.change(ctx.pull,
          merge_commit_sha: String.duplicate("d", 40),
          merged_at: DateTime.utc_now(:second)
        )
      )

    assert {:error, :resource, :stale_local_snapshot, _} = observe(ctx.request)
    expected_merge_state = Map.take(merged, [:merged_at, :merge_commit_sha])
    request = %{ctx.request | expected_merge_state: expected_merge_state}
    assert {:ok, %{resource: projection}} = observe(request)
    assert projection.merge_state == expected_merge_state
    assert {:error, _, :unsupported_merge_state, _} = apply_request(request)
  end

  test "body limits permit the full multibyte domain body and reject excess codepoints", ctx do
    body = String.duplicate("🙂", 65_536)

    assert {:ok, %{resource: projection}} =
             apply_request(%{ctx.request | fields: %{ctx.request.fields | "body" => body}})

    assert projection.fields["body"] == body

    request = %{
      ctx.request
      | expected_fields: projection.fields,
        expected_local_version: projection.local_version,
        fields: %{projection.fields | "body" => body <> "x"}
    }

    assert {:error, _, :invalid_sync_request, _} = apply_request(request)
  end

  test "invalid pull refs roll back prior canonical issue changes", ctx do
    assert {:error, _, %Changeset{}, _} =
             apply_request(%{
               ctx.request
               | fields: %{ctx.request.fields | "base_ref" => "not-a-canonical-ref"}
             })

    assert Repo.get!(Issue, ctx.issue.id).sync_version == ctx.issue.sync_version
    assert Repo.get!(Issue, ctx.issue.id).title == "Original"
    assert github_events(ctx) == []
  end

  test "scalar draft and relationships apply once while retaining unmanaged assignees", ctx do
    identity = relationship_identity(ctx)
    label = relationship_label(ctx)
    assign(ctx, :user_id, ctx.actor.id)
    assign(ctx, :github_identity_id, identity.id)
    expected = %{label_ids: [], managed_assignee_identity_ids: [identity.id]}
    request = relationships_request(ctx, expected, [label.id], [])
    assert {:ok, %{resource: projection}} = apply_request(request)
    assert projection.label_ids == [label.id]
    assert projection.assignee_refs == [%{kind: :local_user, id: ctx.actor.id}]

    assert projection.relationship_preimage == %{
             label_ids: [label.id],
             managed_assignee_identity_ids: []
           }

    assert projection.fields["draft"]
    assert projection.fields["title"] == "Remote"
    assert projection.local_version == ctx.issue.sync_version + 1
    assert [event] = github_events(ctx)
    assert event.payload["sync_version"] == projection.local_version
    assert event.origin == :github
  end

  test "relationship-only edit increments once and transaction failure rolls back every set",
       ctx do
    label = relationship_label(ctx)

    request =
      relationships_request(ctx, empty_relationships(), [label.id], [])
      |> Map.put(:fields, ctx.fields)

    assert {:error, :later, :rollback, _} =
             Multi.new()
             |> ForgePulls.append_sync_apply(:resource, request)
             |> Multi.error(:later, :rollback)
             |> Repo.transaction()

    assert Repo.all(from l in ForgeIssues.IssueLabel, where: l.issue_id == ^ctx.issue.id) == []
    assert github_events(ctx) == []
    assert {:ok, %{resource: projection}} = apply_request(request)
    assert projection.fields == ctx.fields
    assert projection.local_version == 2
    assert projection.label_ids == [label.id]
    assert length(github_events(ctx)) == 1
  end

  test "relationship preimage rejects changes even when scalar version is unchanged", ctx do
    label = relationship_label(ctx)
    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: ctx.issue.id, label_id: label.id})
    request = relationships_request(ctx, empty_relationships(), [], [])
    assert {:error, _, :stale_local_relationships, _} = apply_request(request)
    assert {:error, _, :stale_local_relationships, _} = observe(request)
    assert Repo.get!(Issue, ctx.issue.id).title == "Original"
    assert Repo.get!(Issue, ctx.issue.id).sync_version == 1
    assert github_events(ctx) == []
  end

  test "verified linked user and identity representations share one managed preimage", ctx do
    identity = relationship_identity(ctx)
    {:ok, identity} = ForgeAccounts.link_github_identity(ctx.actor, identity)
    assign(ctx, :github_identity_id, identity.id)
    assert {:ok, original} = ForgePulls.sync_projection(ctx.repository.id, :pull, ctx.pull.id)
    assert original.relationship_preimage.managed_assignee_identity_ids == [identity.id]
    Repo.delete_all(from a in ForgeIssues.IssueAssignee, where: a.issue_id == ^ctx.issue.id)
    assign(ctx, :user_id, ctx.actor.id)

    request =
      relationships_request(ctx, original.relationship_preimage, [], [
        %{kind: :github_identity, id: identity.id}
      ])

    assert {:ok, %{resource: result}} = apply_request(request)
    assert result.relationship_preimage == original.relationship_preimage
    assert result.assignee_refs == [%{kind: :github_identity, id: identity.id}]
  end

  test "unlink invalidates old managed preimage then retains the newly unmanaged local member",
       ctx do
    identity = relationship_identity(ctx)
    {:ok, identity} = ForgeAccounts.link_github_identity(ctx.actor, identity)
    assign(ctx, :user_id, ctx.actor.id)
    {:ok, before} = ForgePulls.sync_projection(ctx.repository.id, :pull, ctx.pull.id)
    {:ok, _} = ForgeAccounts.unlink_github_identity(ctx.actor, identity)

    request =
      relationships_request(ctx, before.relationship_preimage, [], [
        %{kind: :github_identity, id: identity.id}
      ])

    assert {:error, _, :stale_local_relationships, _} = apply_request(request)
    {:ok, fresh} = ForgePulls.sync_projection(ctx.repository.id, :pull, ctx.pull.id)
    assert fresh.relationship_preimage == empty_relationships()

    assert {:ok, %{resource: result}} =
             apply_request(%{request | expected_relationships: fresh.relationship_preimage})

    assert result.assignee_refs == [
             %{kind: :github_identity, id: identity.id},
             %{kind: :local_user, id: ctx.actor.id}
           ]

    assert result.relationship_preimage.managed_assignee_identity_ids == [identity.id]
  end

  test "partial relationship requests and invalid targets cannot mutate scalar metadata", ctx do
    request = relationships_request(ctx, empty_relationships(), [], [])

    for key <- [:expected_relationships, :local_label_ids, :assignee_refs] do
      assert {:error, _, :invalid_sync_request, _} = apply_request(Map.delete(request, key))
    end

    assert {:error, _, :invalid_relationship, _} =
             apply_request(%{request | local_label_ids: [9_223_372_036_854_775_806]})

    assert Repo.get!(Issue, ctx.issue.id).sync_version == 1
    assert Repo.get!(Issue, ctx.issue.id).title == "Original"
    assert github_events(ctx) == []
  end

  test "recovery observes newer relationships without acknowledging them as the older version",
       ctx do
    identity = relationship_identity(ctx)

    request =
      relationships_request(ctx, empty_relationships(), [], [])
      |> Map.delete(:expected_local_version)
      |> Map.put(:minimum_local_version, 1)

    assign(ctx, :github_identity_id, identity.id)
    assert {:error, _, :stale_local_relationships, _} = observe(request)
    Repo.update!(Issue.update_changeset(ctx.issue, %{title: "New local edit"}))
    assert {:ok, %{resource: current}} = observe(request)
    assert current.local_version == 2
    assert current.relationship_preimage.managed_assignee_identity_ids == [identity.id]
    assert github_events(ctx) == []
  end

  defp empty_relationships, do: %{label_ids: [], managed_assignee_identity_ids: []}

  defp relationships_request(ctx, expected, labels, refs),
    do:
      Map.merge(
        ctx.request,
        %{expected_relationships: expected, local_label_ids: labels, assignee_refs: refs}
      )

  defp relationship_identity(ctx) do
    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{id: System.unique_integer([:positive]), login: ctx.actor.username},
        DateTime.utc_now(:second)
      )

    identity
  end

  defp relationship_label(ctx),
    do:
      Repo.insert!(%ForgeIssues.Label{
        repository_id: ctx.repository.id,
        name: "Label",
        normalized_name: "label",
        color: "abcdef"
      })

  defp assign(ctx, key, id),
    do:
      Repo.insert!(
        struct(
          ForgeIssues.IssueAssignee,
          Map.put(%{issue_id: ctx.issue.id}, key, id)
        )
      )

  defp apply_request(request),
    do: Multi.new() |> ForgePulls.append_sync_apply(:resource, request) |> Repo.transaction()

  defp observe(request),
    do: Multi.new() |> ForgePulls.append_sync_observe(:resource, request) |> Repo.transaction()

  defp github_events(ctx),
    do:
      Repo.all(
        from e in DomainOutboxEvent,
          where:
            e.origin == :github and e.aggregate_id == ^to_string(ctx.issue.id) and
              e.aggregate_type == "issue"
      )
end
