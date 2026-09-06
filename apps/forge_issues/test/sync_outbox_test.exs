defmodule ForgeIssues.SyncOutboxTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeIssues.Fixtures
  alias Ecto.Multi
  alias ForgeIssues.{Comment, Issue}
  alias Fornacast.{DomainOutboxEvent, Repo}

  setup do
    reset_database!()
    actor = user_fixture("issue-outbox-#{System.unique_integer([:positive])}")
    repository = repository_fixture(actor)
    %{actor: actor, repository: repository}
  end

  test "issue creation and relationship-only updates produce ordered immutable versions", %{
    actor: actor,
    repository: repository
  } do
    assert {:ok, issue} =
             ForgeIssues.create(
               actor,
               actor.username,
               repository.slug,
               %{"title" => "Sync", "origin" => "github", "sync_version" => 800},
               %{"origin" => "github"}
             )

    assert issue.sync_version == 1

    assert {:ok, updated} =
             ForgeIssues.update(
               actor,
               actor.username,
               repository.slug,
               issue.number,
               %{"labels" => ["bug"], "assignees" => [actor.username]},
               %{}
             )

    assert updated.sync_version == 2
    assert [%{name: "bug"}] = ForgeIssues.load_labels(updated)
    assert [%{id: id}] = ForgeIssues.load_assignees(updated)
    assert id == actor.id
    assert [created, changed] = events("issue", issue.id)
    assert created.origin == :fornacast
    assert created.event_type == "issue.created"
    assert created.payload["sync_version"] == 1
    assert changed.event_type == "issue.updated"
    assert changed.payload["sync_version"] == 2
    assert changed.payload["repository_id"] == repository.id
  end

  test "outbox failure rolls back the domain mutation and its version", %{
    actor: actor,
    repository: repository
  } do
    assert {:ok, issue} =
             ForgeIssues.create(actor, actor.username, repository.slug, %{title: "Before"}, %{})

    assert {:error, :outbox, _changeset, _changes} =
             ForgeIssues.update_multi(actor, repository, issue.number, %{title: "After"}, %{},
               origin: :invalid
             )
             |> ForgeIssues.transaction()

    assert %{title: "Before", sync_version: 1} = Repo.get!(Issue, issue.id)
    assert [_created] = events("issue", issue.id)
  end

  test "internal provenance cannot be supplied via public attributes", %{
    actor: actor,
    repository: repository
  } do
    assert {:ok, %{issue: issue}} =
             ForgeIssues.create_multi(actor, repository, %{title: "Remote"}, %{},
               origin: :github,
               causation_id: "delivery-1",
               correlation_id: "operation-1"
             )
             |> ForgeIssues.transaction()

    assert [%{origin: :github, causation_id: "delivery-1", correlation_id: "operation-1"}] =
             events("issue", issue.id)
  end

  test "comment tombstones retain identity and next version after the row is deleted", %{
    actor: actor,
    repository: repository
  } do
    assert {:ok, issue} =
             ForgeIssues.create(actor, actor.username, repository.slug, %{title: "Parent"}, %{})

    assert {:ok, comment} =
             ForgeIssues.create_comment(
               actor,
               actor.username,
               repository.slug,
               issue.number,
               %{body: String.duplicate("x", 70_000), origin: :github, sync_version: 99},
               %{}
             )

    assert comment.sync_version == 1

    assert {:ok, updated} =
             ForgeIssues.update_comment(
               actor,
               actor.username,
               repository.slug,
               comment.id,
               %{body: "Edited"},
               %{}
             )

    assert updated.sync_version == 2

    assert :ok =
             ForgeIssues.delete_comment(actor, actor.username, repository.slug, comment.id, %{})

    assert Repo.get(Comment, comment.id) == nil
    assert [created, changed, deleted] = events("issue_comment", comment.id)
    assert Enum.map([created, changed, deleted], & &1.payload["sync_version"]) == [1, 2, 3]
    assert deleted.event_type == "issue_comment.deleted"
    assert deleted.payload["deleted"] == true
    assert deleted.payload["issue_id"] == issue.id
    assert deleted.payload["issue_number"] == issue.number
    assert deleted.payload["repository_id"] == repository.id
    assert deleted.payload["author_user_id"] == actor.id
    refute Map.has_key?(created.payload, "body")
  end

  test "an enclosing transaction failure removes both issue and outbox", %{
    actor: actor,
    repository: repository
  } do
    assert {:error, :later, :rollback, _changes} =
             ForgeIssues.create_multi(actor, repository, %{title: "Rolled back"}, %{})
             |> Multi.error(:later, :rollback)
             |> ForgeIssues.transaction()

    assert Repo.aggregate(Issue, :count) == 0
    refute Repo.exists?(from event in DomainOutboxEvent, where: event.aggregate_type == "issue")
  end

  test "shared pull identities keep one row and identify pull comments", %{
    actor: actor,
    repository: repository
  } do
    assert {:ok, %{issue: pull_identity}} =
             Multi.new()
             |> ForgeIssues.insert_numbered_identity(:issue, repository, actor, :pull_request, %{
               title: "Pull"
             })
             |> ForgeIssues.transaction()

    assert {:ok, updated} =
             ForgeIssues.update(
               actor,
               actor.username,
               repository.slug,
               pull_identity.number,
               %{title: "Edited pull identity"},
               %{}
             )

    assert updated.id == pull_identity.id
    assert updated.sync_version == 2
    assert Repo.aggregate(Issue, :count) == 1
    assert [event] = events("issue", updated.id)
    assert event.payload["issue_kind"] == "pull_request"

    assert {:ok, comment} =
             ForgeIssues.create_comment(
               actor,
               actor.username,
               repository.slug,
               updated.number,
               %{body: "Pull conversation"},
               %{}
             )

    assert [comment_event] = events("issue_comment", comment.id)
    assert comment_event.payload["issue_id"] == updated.id
    assert comment_event.payload["issue_kind"] == "pull_request"
  end

  test "a stale internal issue update cannot reuse an already committed version", %{
    actor: actor,
    repository: repository
  } do
    assert {:ok, original} =
             ForgeIssues.create(actor, actor.username, repository.slug, %{title: "Original"}, %{})

    assert {:ok, current} =
             ForgeIssues.update(
               actor,
               actor.username,
               repository.slug,
               original.number,
               %{title: "Current"},
               %{}
             )

    assert {:error, :issue, changeset, _changes} =
             Multi.new()
             |> ForgeIssues.update_identity(:issue, original, actor, %{title: "Stale"})
             |> ForgeIssues.SyncEvents.issue("issue.updated", [])
             |> ForgeIssues.transaction()

    assert Keyword.has_key?(changeset.errors, :id)
    assert Repo.get!(Issue, original.id).sync_version == current.sync_version
    assert Repo.get!(Issue, original.id).title == "Current"
    assert [_created, _changed] = events("issue", original.id)
  end

  defp events(type, id) do
    Repo.all(
      from event in DomainOutboxEvent,
        where: event.aggregate_type == ^type and event.aggregate_id == ^to_string(id),
        order_by: [asc: event.id]
    )
  end
end
