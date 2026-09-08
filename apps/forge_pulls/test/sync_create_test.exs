defmodule ForgePulls.SyncCreateTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Multi
  alias ForgeIssues.{Issue, NumberSequence}
  alias ForgePulls.PullRequest
  alias Fornacast.{AuditEvent, DomainOutboxEvent, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "pull-create-#{suffix}",
        email: "pull-create-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{
        name: "sync-create",
        slug: "sync-create",
        visibility: :private
      })

    author =
      %ForgeAccounts.GitHubIdentity{}
      |> ForgeAccounts.GitHubIdentity.observed_changeset(%{
        github_user_id: suffix,
        login: "remote-#{suffix}"
      })
      |> Repo.insert!()

    request = %{
      repository_id: repository.id,
      resource_kind: :pull,
      head_repository_id: repository.id,
      author_github_identity_id: author.id,
      local_label_ids: [],
      assignee_refs: [],
      fields: %{
        "title" => "Remote pull",
        "body" => "Body",
        "state" => "open",
        "state_reason" => nil,
        "draft" => true,
        "head_ref" => "refs/heads/feature",
        "base_ref" => "refs/heads/main",
        "head_sha" => String.duplicate("a", 40),
        "base_sha" => String.duplicate("b", 40)
      },
      merge_state: %{merged_at: nil, merge_commit_sha: nil},
      inserted_at: ~U[2026-09-01 00:00:00Z],
      updated_at: ~U[2026-09-02 00:00:00Z],
      provenance: %{
        origin: :github,
        causation_id: "delivery-create",
        correlation_id: "sync-create"
      }
    }

    %{actor: actor, repository: repository, author: author, request: request}
  end

  test "allocates a local shared number independently of provider hints and returns canonical identity",
       ctx do
    assert {:ok, %{occupied: occupied}} =
             Multi.new()
             |> ForgeIssues.insert_numbered_identity(
               :occupied,
               ctx.repository,
               ctx.actor,
               :issue,
               %{title: "Already here"}
             )
             |> Repo.transaction()

    assert {:ok, %{resource: result}} = create(ctx.request)
    assert result.issue_number == occupied.number + 1
    assert result.local_version == 1
    assert result.resource_kind == :pull
    assert result.fields == ctx.request.fields

    assert %Issue{kind: :pull_request, author_user_id: nil, author_github_identity_id: author_id} =
             Repo.get!(Issue, result.issue_id)

    assert author_id == ctx.author.id

    assert %PullRequest{issue_id: issue_id, draft: true} =
             Repo.get!(PullRequest, result.local_resource_id)

    assert issue_id == result.issue_id

    event =
      Repo.one!(
        from e in DomainOutboxEvent,
          where: e.aggregate_type == "issue" and e.aggregate_id == ^to_string(issue_id)
      )

    assert event.origin == :github
    assert event.event_type == "issue.created"
    assert event.causation_id == "delivery-create"
    assert event.payload["issue_number"] == result.issue_number

    assert Repo.exists?(
             from a in AuditEvent,
               where:
                 a.action == "github_sync.applied" and
                   a.target_id == ^to_string(ctx.repository.id) and
                   fragment("?->>'action'", a.metadata) == "create"
           )
  end

  test "explicit cross-repository and nil heads preserve distinct same-named ref identities",
       ctx do
    {:ok, head} =
      ForgeRepos.create_repository(ctx.actor, %{name: "head", slug: "head", visibility: :private})

    for head_id <- [head.id, nil] do
      request = %{
        ctx.request
        | head_repository_id: head_id,
          fields: %{ctx.request.fields | "head_ref" => "refs/heads/main"}
      }

      assert {:ok, %{resource: result}} = create(request)
      assert result.head_repository_id == head_id
      assert result.fields["head_ref"] == result.fields["base_ref"]
    end
  end

  test "downstream failure rolls back aggregate, number allocation, event and audit", ctx do
    before_events = Repo.aggregate(DomainOutboxEvent, :count)
    before_audits = Repo.aggregate(AuditEvent, :count)

    assert {:error, :mapping, :mapping_conflict, _} =
             Multi.new()
             |> ForgePulls.append_sync_create(:resource, ctx.request)
             |> Multi.error(:mapping, :mapping_conflict)
             |> Repo.transaction()

    refute Repo.exists?(from i in Issue, where: i.repository_id == ^ctx.repository.id)
    refute Repo.get(NumberSequence, ctx.repository.id)
    assert Repo.aggregate(DomainOutboxEvent, :count) == before_events
    assert Repo.aggregate(AuditEvent, :count) == before_audits
    assert {:ok, %{resource: %{issue_number: 1}}} = create(ctx.request)
  end

  test "invalid fields and untrusted provenance fail without consuming a number", ctx do
    for request <- [
          Map.put(ctx.request, :github_number, 900),
          Map.put(ctx.request, :issue_number, 900),
          Map.put(ctx.request, :origin, :fornacast),
          Map.delete(ctx.request, :head_repository_id),
          %{ctx.request | provenance: %{origin: :fornacast}},
          %{ctx.request | fields: Map.put(ctx.request.fields, "origin", "github")},
          %{ctx.request | fields: %{ctx.request.fields | "title" => ""}}
        ] do
      assert {:error, :resource, _, _} = create(request)
      refute Repo.exists?(from i in Issue, where: i.repository_id == ^ctx.repository.id)
    end

    assert {:ok, %{resource: %{issue_number: 1}}} = create(ctx.request)
  end

  test "relationships are part of the version-one aggregate and reject foreign labels", ctx do
    label =
      %ForgeIssues.Label{}
      |> ForgeIssues.Label.changeset(%{
        repository_id: ctx.repository.id,
        name: "sync",
        normalized_name: "sync",
        color: "abcdef"
      })
      |> Repo.insert!()

    refs = [%{kind: :github_identity, id: ctx.author.id}, %{kind: :local_user, id: ctx.actor.id}]

    assert {:ok, %{resource: result}} =
             create(%{ctx.request | local_label_ids: [label.id, label.id], assignee_refs: refs})

    assert result.label_ids == [label.id]
    assert Enum.sort(result.assignee_refs) == Enum.sort(refs)
    assert result.local_version == 1

    assert Repo.aggregate(
             from(l in ForgeIssues.IssueLabel, where: l.issue_id == ^result.issue_id),
             :count
           ) == 1

    assert {:error, :resource, :invalid_relationship, _} =
             create(%{ctx.request | local_label_ids: [9_223_372_036_854_775_000]})

    assert {:ok, %{resource: %{issue_number: 2}}} = create(ctx.request)
  end

  test "missing author, unavailable base or deleted represented head fails closed", ctx do
    assert {:error, :resource, _, _} =
             create(%{ctx.request | author_github_identity_id: 9_223_372_036_854_775_000})

    {:ok, head} =
      ForgeRepos.create_repository(ctx.actor, %{
        name: "gone-head",
        slug: "gone-head",
        visibility: :private
      })

    Repo.update_all(from(r in ForgeRepos.Repository, where: r.id == ^head.id),
      set: [deleted_at: ~U[2026-09-02 00:00:00Z]]
    )

    assert {:error, :resource, :not_found, _} =
             create(%{ctx.request | head_repository_id: head.id})

    Repo.update_all(from(r in ForgeRepos.Repository, where: r.id == ^ctx.repository.id),
      set: [lifecycle: :importing]
    )

    assert {:error, :resource, :not_found, _} = create(ctx.request)
  end

  test "newly discovered closed pull retains coherent merge facts but rejects an open merged aggregate",
       ctx do
    merge = %{merged_at: ~U[2026-09-02 00:00:00Z], merge_commit_sha: String.duplicate("c", 40)}

    assert {:error, :resource, :invalid_sync_request, _} =
             create(%{ctx.request | merge_state: merge})

    request = %{
      ctx.request
      | merge_state: merge,
        fields: %{
          ctx.request.fields
          | "state" => "closed",
            "state_reason" => "completed",
            "draft" => false
        }
    }

    assert {:ok, %{resource: result}} = create(request)
    assert result.merge_state == merge
    assert result.issue_number == 1
  end

  defp create(request),
    do: Multi.new() |> ForgePulls.append_sync_create(:resource, request) |> Repo.transaction()
end
