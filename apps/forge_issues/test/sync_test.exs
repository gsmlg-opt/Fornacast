defmodule ForgeIssues.SyncTest do
  use ExUnit.Case, async: false
  import ForgeIssues.Fixtures
  import Ecto.Query
  alias Ecto.Multi
  alias ForgeIssues.{Comment, Issue, IssueAssignee}
  alias Fornacast.{DomainOutboxEvent, Repo}

  setup do
    reset_database!()
    actor = user_fixture("sync-domain-#{System.unique_integer([:positive])}")
    repository = repository_fixture(actor)

    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{"id" => 8123, "login" => "remote"},
        DateTime.utc_now()
      )

    %{actor: actor, repository: repository, identity: identity}
  end

  test "remote create preserves namespace, attribution and sequence with github provenance",
       ctx do
    assert {:ok, %{sync: projection}} = apply_request(request(ctx))
    assert projection.fields["title"] == "Remote"
    assert projection.local_version == 1
    issue = Repo.get!(Issue, projection.local_resource_id)
    assert issue.number == 42
    assert issue.author_user_id == nil
    assert issue.author_github_identity_id == ctx.identity.id
    assert [event] = events("issue", issue.id)
    assert event.origin == :github
    assert event.causation_id == "delivery"
    assert event.correlation_id == "operation"

    assert {:ok, local} =
             ForgeIssues.create(
               ctx.actor,
               ctx.actor.username,
               ctx.repository.slug,
               %{title: "Next"},
               %{}
             )

    assert local.number == 43
    assert {:error, _, :namespace_collision, _} = apply_request(request(ctx))
  end

  test "issue projection uses domain relationship identities and update rechecks version", ctx do
    {:ok, %{sync: projection}} = apply_request(request(ctx))
    [label | _] = ForgeIssues.list_labels(ctx.repository)

    update =
      request(ctx)
      |> Map.merge(%{
        action: :update,
        local_resource_id: projection.local_resource_id,
        expected_local_version: 1,
        local_label_ids: [label.id],
        assignee_refs: [%{kind: :github_identity, id: ctx.identity.id}]
      })

    assert {:ok, %{sync: changed}} = apply_request(update)
    assert changed.local_version == 2
    assert changed.label_ids == [label.id]
    assert changed.assignee_refs == [%{kind: :github_identity, id: ctx.identity.id}]

    assert {:ok, ^changed} =
             ForgeIssues.sync_projection(ctx.repository.id, :issue, changed.local_resource_id)

    assert {:error, _, :stale_local_version, _} = apply_request(update)

    assert {:error, _, :stale_local_version, _} =
             Multi.new()
             |> ForgeIssues.append_sync_observe(:observed, update)
             |> Repo.transaction()

    assert {:ok, %{observed: ^changed}} =
             Multi.new()
             |> ForgeIssues.append_sync_observe(:observed, %{update | expected_local_version: 2})
             |> Repo.transaction()
  end

  test "remote full-set replacement preserves local-only assignees", ctx do
    {:ok, issue} =
      ForgeIssues.create(
        ctx.actor,
        ctx.actor.username,
        ctx.repository.slug,
        %{title: "Local", assignees: [ctx.actor.username]},
        %{}
      )

    update =
      request(ctx)
      |> Map.merge(%{action: :update, local_resource_id: issue.id, expected_local_version: 1})

    assert {:ok, %{sync: result}} = apply_request(update)
    assert result.assignee_refs == [%{kind: :local_user, id: ctx.actor.id}]

    assert Repo.exists?(
             from a in IssueAssignee,
               where: a.issue_id == ^issue.id and a.user_id == ^ctx.actor.id
           )
  end

  test "outbound observation can retain a proven older baseline without overwriting a newer edit",
       ctx do
    {:ok, issue} =
      ForgeIssues.create(
        ctx.actor,
        ctx.actor.username,
        ctx.repository.slug,
        %{title: "Original local"},
        %{}
      )

    {:ok, original} = ForgeIssues.sync_projection(ctx.repository.id, :issue, issue.id)

    update =
      Map.merge(request(ctx), %{
        action: :update,
        local_resource_id: original.local_resource_id,
        expected_local_version: 1,
        fields: %{request(ctx).fields | "title" => "Newer local edit"}
      })

    {:ok, _} =
      ForgeIssues.update(
        ctx.actor,
        ctx.actor.username,
        ctx.repository.slug,
        issue.number,
        %{title: "Newer local edit"},
        %{}
      )

    {:ok, current} =
      ForgeIssues.sync_projection(ctx.repository.id, :issue, original.local_resource_id)

    expected = update |> Map.delete(:expected_local_version) |> Map.put(:minimum_local_version, 1)

    assert {:ok, %{observed: ^current}} =
             Multi.new()
             |> ForgeIssues.append_sync_observe(:observed, expected)
             |> Repo.transaction()

    assert {:error, _, :stale_local_version, _} =
             Multi.new()
             |> ForgeIssues.append_sync_observe(:observed, %{expected | minimum_local_version: 3})
             |> Repo.transaction()

    assert {:error, _, :invalid_sync_request, _} =
             Multi.new()
             |> ForgeIssues.append_sync_observe(
               :observed,
               Map.put(expected, :expected_local_version, 2)
             )
             |> Repo.transaction()

    assert {:error, _, :invalid_sync_request, _} = apply_request(expected)
    assert Repo.get!(Issue, current.local_resource_id).title == "Newer local edit"
  end

  test "relationship validation and downstream failure roll back issue and events", ctx do
    other = repository_fixture(ctx.actor)
    [foreign_label | _] = ForgeIssues.list_labels(other)

    assert {:error, _, :invalid_relationship, _} =
             apply_request(%{request(ctx) | local_label_ids: [foreign_label.id]})

    assert Repo.aggregate(Issue, :count) == 0

    assert {:error, :later, :rollback, _} =
             Multi.new()
             |> ForgeIssues.append_sync_apply(:sync, request(ctx))
             |> Multi.error(:later, :rollback)
             |> Repo.transaction()

    assert Repo.aggregate(Issue, :count) == 0
    refute Repo.exists?(from e in DomainOutboxEvent, where: e.aggregate_type == "issue")
  end

  test "comment create edit delete retains immutable author and versioned tombstone", ctx do
    {:ok, %{sync: parent}} = apply_request(request(ctx))

    create =
      request(ctx)
      |> Map.merge(%{
        resource_kind: :issue_comment,
        parent_issue_id: parent.local_resource_id,
        fields: %{"body" => "Comment"}
      })

    assert {:ok, %{sync: comment}} = apply_request(create)
    assert comment.parent_issue_id == parent.local_resource_id
    assert comment.issue_number == 42
    assert comment.issue_kind == :issue

    update =
      create
      |> Map.merge(%{
        action: :update,
        local_resource_id: comment.local_resource_id,
        expected_local_version: 1,
        fields: %{"body" => "Edited"},
        author_github_identity_id: nil
      })

    assert {:ok, %{sync: edited}} = apply_request(update)
    assert edited.local_version == 2

    assert Repo.get!(Comment, comment.local_resource_id).author_github_identity_id ==
             ctx.identity.id

    assert {:error, _, :stale_local_version, _} = apply_request(%{update | action: :delete})

    assert {:ok, %{sync: tombstone}} =
             apply_request(%{update | action: :delete, expected_local_version: 2})

    assert tombstone.deleted
    assert tombstone.local_version == 3
    assert tombstone.parent_issue_id == parent.local_resource_id

    assert {:error, :not_found} =
             ForgeIssues.sync_projection(
               ctx.repository.id,
               :issue_comment,
               comment.local_resource_id
             )

    assert Enum.map(
             events("issue_comment", comment.local_resource_id),
             & &1.payload["sync_version"]
           ) == [1, 2, 3]
  end

  test "repository membership, resource kind and provenance are fail closed", ctx do
    {:ok, %{sync: issue}} = apply_request(request(ctx))
    other = repository_fixture(ctx.actor)

    assert {:error, :not_found} =
             ForgeIssues.sync_projection(other.id, :issue, issue.local_resource_id)

    update =
      request(ctx)
      |> Map.merge(%{
        action: :update,
        local_resource_id: issue.local_resource_id,
        expected_local_version: 1,
        repository_id: other.id
      })

    assert {:error, _, :not_found, _} = apply_request(update)

    assert {:error, _, :invalid_sync_request, _} =
             apply_request(%{request(ctx) | provenance: %{origin: :fornacast}})

    assert {:error, _, :invalid_sync_request, _} =
             apply_request(%{request(ctx) | action: :delete})
  end

  test "unlinking does not silently delete an independently local assignee", ctx do
    {:ok, identity} = ForgeAccounts.link_github_identity(ctx.actor, ctx.identity)

    {:ok, issue} =
      ForgeIssues.create(
        ctx.actor,
        ctx.actor.username,
        ctx.repository.slug,
        %{title: "Local", assignees: [ctx.actor.username]},
        %{}
      )

    assert {:ok, _} = ForgeAccounts.unlink_github_identity(ctx.actor, identity)

    update =
      request(ctx)
      |> Map.merge(%{
        action: :update,
        local_resource_id: issue.id,
        expected_local_version: 1,
        assignee_refs: [%{kind: :github_identity, id: identity.id}]
      })

    assert {:ok, %{sync: result}} = apply_request(update)

    assert result.assignee_refs == [
             %{kind: :github_identity, id: identity.id},
             %{kind: :local_user, id: ctx.actor.id}
           ]
  end

  test "known linked assignees can be removed by the full remote set", ctx do
    {:ok, _} = ForgeAccounts.link_github_identity(ctx.actor, ctx.identity)

    {:ok, issue} =
      ForgeIssues.create(
        ctx.actor,
        ctx.actor.username,
        ctx.repository.slug,
        %{title: "Local", assignees: [ctx.actor.username]},
        %{}
      )

    update =
      request(ctx)
      |> Map.merge(%{action: :update, local_resource_id: issue.id, expected_local_version: 1})

    assert {:ok, %{sync: result}} = apply_request(update)
    assert result.assignee_refs == []
  end

  test "pull identities reserve the same namespace but accept conversation comments", ctx do
    {:ok, %{pull: pull}} =
      Multi.new()
      |> ForgeIssues.insert_numbered_identity(:pull, ctx.repository, ctx.actor, :pull_request, %{
        title: "Pull"
      })
      |> Repo.transaction()

    assert {:error, _, :namespace_collision, _} =
             apply_request(%{request(ctx) | github_number: pull.number})

    assert {:error, :not_found} = ForgeIssues.sync_projection(ctx.repository.id, :issue, pull.id)

    create =
      request(ctx)
      |> Map.merge(%{
        resource_kind: :issue_comment,
        parent_issue_id: pull.id,
        fields: %{"body" => "Conversation"}
      })

    assert {:ok, %{sync: result}} = apply_request(create)
    assert result.repository_id == ctx.repository.id
    assert [event] = events("issue_comment", result.local_resource_id)
    assert event.payload["issue_kind"] == "pull_request"
    other = repository_fixture(ctx.actor)
    assert {:error, _, :not_found, _} = apply_request(%{create | repository_id: other.id})
  end

  test "invalid provenance and unknown assignees roll back all changes", ctx do
    assert {:error, _, :invalid_relationship, _} =
             apply_request(%{
               request(ctx)
               | assignee_refs: [%{kind: :github_identity, id: 9_223_372_036_854_775_806}]
             })

    assert {:error, _, _, _} =
             apply_request(%{
               request(ctx)
               | provenance: %{origin: :github, causation_id: String.duplicate("x", 2048)}
             })

    assert Repo.aggregate(Issue, :count) == 0

    assert {:error, _, :invalid_sync_request, _} =
             apply_request(%{request(ctx) | fields: %{"title" => "Partial"}})

    assert {:error, _, :invalid_author, _} =
             apply_request(%{request(ctx) | author_github_identity_id: 9_223_372_036_854_775_806})
  end

  test "numeric and relationship work bounds fail before database writes", ctx do
    for change <- [
          %{github_number: 9_223_372_036_854_775_807},
          %{repository_id: 9_223_372_036_854_775_808},
          %{author_github_identity_id: 9_223_372_036_854_775_808},
          %{local_label_ids: Enum.to_list(1..513)},
          %{assignee_refs: Enum.map(1..513, &%{kind: :github_identity, id: &1})}
        ] do
      assert {:error, _, :invalid_sync_request, _} =
               apply_request(Map.merge(request(ctx), change))
    end

    assert Repo.aggregate(Issue, :count) == 0
  end

  defp request(ctx) do
    %{
      repository_id: ctx.repository.id,
      resource_kind: :issue,
      action: :create,
      local_resource_id: nil,
      expected_local_version: :missing,
      fields: %{"title" => "Remote", "body" => "Body", "state" => "open", "state_reason" => nil},
      local_label_ids: [],
      assignee_refs: [],
      github_number: 42,
      author_github_identity_id: ctx.identity.id,
      inserted_at: ~U[2026-09-01 00:00:00Z],
      updated_at: ~U[2026-09-02 00:00:00Z],
      provenance: %{origin: :github, causation_id: "delivery", correlation_id: "operation"}
    }
  end

  defp apply_request(request),
    do: Multi.new() |> ForgeIssues.append_sync_apply(:sync, request) |> Repo.transaction()

  defp events(type, id),
    do:
      Repo.all(
        from e in DomainOutboxEvent,
          where: e.aggregate_type == ^type and e.aggregate_id == ^to_string(id),
          order_by: e.id
      )
end
