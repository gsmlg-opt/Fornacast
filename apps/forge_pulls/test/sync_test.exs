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
