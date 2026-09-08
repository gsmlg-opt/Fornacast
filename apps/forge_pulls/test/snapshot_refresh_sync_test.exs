defmodule ForgePulls.SnapshotRefreshSyncTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Multi
  alias ForgeIssues.Issue
  alias ForgePulls.{PullRequest, SnapshotRefresh}
  alias Fornacast.{DomainOutboxEvent, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "snapshot-#{suffix}",
        email: "snapshot-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{
        name: "snapshot",
        slug: "snapshot",
        visibility: :private
      })

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

    %{
      pull: pull,
      issue: issue,
      actor: actor,
      attrs: Map.take(pull, [:head_ref, :base_ref, :head_sha, :base_sha])
    }
  end

  test "changed snapshot bumps canonical version and emits bounded pull issue event once", c do
    attrs = %{c.attrs | head_sha: String.duplicate("c", 40)}
    assert {:ok, refreshed} = SnapshotRefresh.persist(c.pull, attrs)
    assert refreshed.head_sha == attrs.head_sha
    assert Repo.get!(Issue, c.issue.id).sync_version == c.issue.sync_version + 1
    assert [event] = events(c)
    assert event.event_type == "issue.updated"
    assert event.origin == :fornacast
    assert event.payload["issue_kind"] == "pull_request"
    assert event.payload["sync_version"] == c.issue.sync_version + 1
    refute Map.has_key?(event.payload, "body")
  end

  test "unchanged snapshot performs no version event or timestamp churn", c do
    assert {:ok, unchanged} = SnapshotRefresh.persist(c.pull, c.attrs)
    assert unchanged == c.pull
    assert Repo.get!(Issue, c.issue.id).sync_version == c.issue.sync_version
    assert events(c) == []
  end

  test "stale snapshot cannot bump canonical version or record an event", c do
    assert {:ok, _} =
             SnapshotRefresh.persist(c.pull, %{c.attrs | base_sha: String.duplicate("c", 40)})

    before = Repo.get!(Issue, c.issue.id).sync_version
    before_events = events(c)

    assert {:error, :ref_conflict} =
             SnapshotRefresh.persist(c.pull, %{c.attrs | head_sha: String.duplicate("d", 40)})

    assert Repo.get!(Issue, c.issue.id).sync_version == before
    assert events(c) == before_events
  end

  test "outer rollback reverts snapshot canonical version and outbox together", c do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        SnapshotRefresh.persist(c.pull, %{
                          c.attrs
                          | head_sha: String.duplicate("c", 40)
                        })

               Repo.rollback(:abort)
             end)

    assert Repo.get!(PullRequest, c.pull.id).head_sha == c.pull.head_sha
    assert Repo.get!(Issue, c.issue.id).sync_version == c.issue.sync_version
    assert events(c) == []
  end

  test "caller-owned update includes draft without double version or event", c do
    assert {:ok, %{pull_request: pull}} =
             Multi.new()
             |> ForgeIssues.update_identity(:issue, c.issue, c.actor, %{title: "Edited"})
             |> Multi.run(:pull_request, fn repo, _ ->
               SnapshotRefresh.persist_in_transaction(
                 repo,
                 c.pull,
                 Map.put(c.attrs, :draft, true)
               )
             end)
             |> ForgeIssues.SyncEvents.issue("issue.updated", [])
             |> Repo.transaction()

    assert pull.draft
    assert Repo.get!(Issue, c.issue.id).sync_version == c.issue.sync_version + 1
    assert [_] = events(c)
  end

  defp events(c),
    do:
      Repo.all(
        from e in DomainOutboxEvent,
          where: e.aggregate_type == "issue" and e.aggregate_id == ^to_string(c.issue.id),
          order_by: e.id
      )
end
