defmodule ForgePulls.HeadRepresentationTest do
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
        username: "head-representation-#{suffix}",
        email: "head-representation-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(
        actor,
        %{name: "base", slug: "base", visibility: :private}
      )

    {:ok, head} =
      ForgeRepos.create_repository(
        actor,
        %{name: "head", slug: "head", visibility: :private}
      )

    issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: 7,
        kind: :pull_request,
        title: "External metadata",
        body: "Retained",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%PullRequest{
        repository_id: repository.id,
        issue_id: issue.id,
        head_repository_id: nil,
        head_ref: "refs/heads/main",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40),
        draft: true,
        mergeable: false,
        mergeable_state: :conflicting
      })

    {:ok, projection} = ForgePulls.sync_projection(repository.id, :pull, pull.id)

    request = %{
      repository_id: repository.id,
      resource_kind: :pull,
      local_resource_id: pull.id,
      issue_id: issue.id,
      expected_local_version: projection.local_version,
      expected_fields: projection.fields,
      expected_merge_state: projection.merge_state,
      expected_head_repository_id: nil,
      head_repository_id: head.id,
      expected_repository_generation: repository.generation,
      expected_head_repository_generation: head.generation,
      provenance: %{
        origin: :github,
        causation_id: "remote-head",
        correlation_id: "reconciliation"
      }
    }

    %{
      actor: actor,
      repository: repository,
      head: head,
      issue: issue,
      pull: pull,
      projection: projection,
      request: request
    }
  end

  test "explicit nil-to-represented transition changes only head identity and canonical version",
       c do
    assert {:ok, %{resource: result}} = represent(c.request)
    assert result.head_repository_id == c.head.id
    assert result.local_version == c.issue.sync_version + 1
    assert result.fields == c.projection.fields
    assert result.merge_state == c.projection.merge_state
    current = Repo.get!(PullRequest, c.pull.id)

    assert Map.take(current, [
             :draft,
             :head_ref,
             :head_sha,
             :base_ref,
             :base_sha,
             :merged_at,
             :merge_commit_sha,
             :mergeable,
             :mergeable_state
           ]) ==
             Map.take(c.pull, [
               :draft,
               :head_ref,
               :head_sha,
               :base_ref,
               :base_sha,
               :merged_at,
               :merge_commit_sha,
               :mergeable,
               :mergeable_state
             ])

    assert Repo.get!(Issue, c.issue.id).author_user_id == c.actor.id
    assert [event] = events(c)
    assert event.origin == :github
    assert event.event_type == "issue.updated"
    assert event.causation_id == "remote-head"
    assert event.correlation_id == "reconciliation"
    assert event.payload["issue_id"] == c.issue.id
    assert event.payload["sync_version"] == result.local_version
    assert event.payload["issue_kind"] == "pull_request"
    refute Map.has_key?(event.payload, "body")
  end

  test "outer transaction rollback removes identity change version event and audit", c do
    before_audit = audit_count(c)

    assert {:error, :abort, :deliberate, _} =
             Multi.new()
             |> ForgePulls.append_sync_represent_head(:resource, c.request)
             |> Multi.error(:abort, :deliberate)
             |> Repo.transaction()

    assert Repo.get!(PullRequest, c.pull.id).head_repository_id == nil
    assert Repo.get!(Issue, c.issue.id).sync_version == c.issue.sync_version
    assert events(c) == []
    assert audit_count(c) == before_audit
  end

  test "stale version snapshot merge facts and canonical identity are rejected", c do
    for request <- [
          %{c.request | expected_local_version: c.issue.sync_version + 1},
          put_in(c.request, [:expected_fields, "head_sha"], String.duplicate("c", 40)),
          %{
            c.request
            | expected_merge_state: %{
                merged_at: ~U[2026-09-08 00:00:00Z],
                merge_commit_sha: String.duplicate("c", 40)
              }
          },
          %{c.request | issue_id: c.issue.id + 1},
          %{c.request | repository_id: c.head.id}
        ] do
      assert {:error, _, _, _} = represent(request)
    end

    assert events(c) == []
    assert Repo.get!(PullRequest, c.pull.id).head_repository_id == nil
  end

  test "deleted target or stale repository generation cannot be represented", c do
    for request <- [
          %{c.request | expected_repository_generation: c.repository.generation + 1},
          %{c.request | expected_head_repository_generation: c.head.generation + 1},
          %{c.request | head_repository_id: c.head.id + 9_000_000}
        ] do
      assert {:error, _, _, _} = represent(request)
    end

    c.head |> Changeset.change(deleted_at: DateTime.utc_now(:second)) |> Repo.update!()
    assert {:error, _, _, _} = represent(c.request)
    assert events(c) == []
  end

  test "provenance is trusted bounded input and extra attrs cannot alter content", c do
    for request <- [
          %{c.request | provenance: %{origin: :fornacast}},
          %{c.request | provenance: %{origin: :github, causation_id: String.duplicate("x", 256)}},
          %{c.request | provenance: %{origin: :github, actor_user_id: c.actor.id}},
          %{c.request | head_repository_id: nil},
          %{c.request | expected_head_repository_id: c.head.id},
          Map.put(c.request, :fields, %{"title" => "Injected"}),
          Map.put(c.request, :minimum_local_version, 1)
        ] do
      assert {:error, _, :invalid_sync_request, _} = represent(request)
    end

    assert events(c) == []
  end

  test "already represented head cannot be rebound or replayed as a second version", c do
    assert {:ok, %{resource: result}} = represent(c.request)
    request = %{c.request | expected_local_version: result.local_version}
    assert {:error, _, :immutable_identity, _} = represent(request)

    assert {:error, _, :immutable_identity, _} =
             represent(%{request | head_repository_id: c.repository.id})

    assert length(events(c)) == 1
    assert Repo.get!(Issue, c.issue.id).sync_version == result.local_version
  end

  test "merged metadata can become represented without changing merge facts", c do
    merged_at = ~U[2026-09-08 00:00:00Z]

    c.issue
    |> Changeset.change(state: :closed, state_reason: :completed, closed_at: merged_at)
    |> Repo.update!()

    c.pull
    |> Changeset.change(merged_at: merged_at, merge_commit_sha: String.duplicate("c", 40))
    |> Repo.update!()

    {:ok, projection} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)

    request = %{
      c.request
      | expected_fields: projection.fields,
        expected_merge_state: projection.merge_state
    }

    assert {:ok, %{resource: result}} = represent(request)
    assert result.merge_state == projection.merge_state
    assert result.fields == projection.fields
    assert result.local_version == projection.local_version + 1
  end

  test "same-name cross-repository refs remain valid but identical same-repository refs do not",
       c do
    assert {:error, _, :invalid_head_identity, _} =
             represent(%{
               c.request
               | head_repository_id: c.repository.id,
                 expected_head_repository_generation: c.repository.generation
             })

    assert {:ok, _} = represent(c.request)
  end

  test "ordinary update and import changesets retain immutable head guards", c do
    refute PullRequest.update_changeset(c.pull, %{head_repository_id: c.head.id}).valid?

    attrs =
      Map.merge(c.projection.fields, %{
        "inserted_at" => c.pull.inserted_at,
        "updated_at" => c.pull.updated_at
      })

    refute PullRequest.import_changeset(c.pull, attrs, c.issue, c.repository, c.head.id).valid?
  end

  defp represent(request),
    do:
      Multi.new()
      |> ForgePulls.append_sync_represent_head(:resource, request)
      |> Repo.transaction()

  defp events(c),
    do:
      Repo.all(
        from e in DomainOutboxEvent,
          where: e.aggregate_type == "issue" and e.aggregate_id == ^to_string(c.issue.id)
      )

  defp audit_count(c),
    do:
      Repo.aggregate(
        from(a in Fornacast.AuditEvent,
          where: a.target_type == "repository" and a.target_id == ^to_string(c.repository.id)
        ),
        :count
      )
end
