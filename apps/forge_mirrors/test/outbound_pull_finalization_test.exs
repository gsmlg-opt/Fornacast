defmodule ForgeMirrors.OutboundPullFinalizationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Ecto.Multi
  alias ForgeMirrors.{MirrorOperation, MirrorRefState, MirrorResourceState}
  alias Fornacast.Repo

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(org)
    head = repository_mirror_fixture(org)
    now = DateTime.utc_now(:second)
    actor = organization_owner_fixture(org)
    repository = Repo.get!(ForgeRepos.Repository, base.repository_id)

    {:ok, %{issue: issue}} =
      Multi.new()
      |> ForgeIssues.insert_numbered_identity(:issue, repository, actor, :pull_request, %{
        title: "Desired",
        body: String.duplicate("界", 65_536)
      })
      |> Repo.transaction()

    issue =
      if tags[:empty_body], do: Repo.update!(Ecto.Changeset.change(issue, body: "")), else: issue

    issue =
      if tags[:closed],
        do: Repo.update!(Ecto.Changeset.change(issue, state: :closed, state_reason: :completed)),
        else: issue

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: base.repository_id,
        head_repository_id: head.repository_id,
        head_ref: "refs/heads/feature",
        head_sha: String.duplicate("b", 40),
        base_ref: "refs/heads/main",
        base_sha: String.duplicate("a", 40)
      })

    for {binding, ref, oid} <- [
          {base, pull.base_ref, pull.base_sha},
          {head, pull.head_ref, pull.head_sha}
        ] do
      Repo.insert!(%MirrorRefState{
        repository_mirror_id: binding.id,
        ref_name: ref,
        ref_kind: :branch,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        state: :confirmed,
        last_confirmed_at: now
      })
    end

    {:ok, local} = ForgePulls.sync_projection(base.repository_id, :pull, pull.id)

    repositories = %{
      "base_repository" => %{"id" => base.github_repository_id, "node_id" => base.github_node_id},
      "head_repository" => %{"id" => head.github_repository_id, "node_id" => head.github_node_id}
    }

    event =
      %Fornacast.DomainOutboxEvent{}
      |> Fornacast.DomainOutboxEvent.record_changeset(%{
        event_id: Ecto.UUID.generate(),
        aggregate_type: "issue",
        aggregate_id: to_string(issue.id),
        event_type: "issue.created",
        origin: :fornacast,
        payload: %{
          "repository_id" => base.repository_id,
          "issue_id" => issue.id,
          "issue_number" => issue.number,
          "issue_kind" => "pull_request",
          "sync_version" => issue.sync_version
        }
      })
      |> Repo.insert!()

    {:ok, {:materialized, [operation]}} = ForgeMirrors.materialize_outbox_event(event)

    {:ok, claimed} =
      ForgeMirrors.claim_operations("outbound-finalize", now, 120, 100, ["sync.pull"])

    operation = Enum.find(claimed, &(&1.id == operation.id))
    {:ok, context} = ForgeMirrors.outbound_pull_creation_context(operation)

    expected =
      Map.take(
        context,
        ~w(pull_id issue_id expected_local_version expected_fields expected_issue_snapshot expected_merge_state provider_repositories pull_eligibility_proof)a
      )

    {:ok, %{operation: operation, intent: intent, marker: marker, newly_marked: true}} =
      ForgeMirrors.mark_outbound_pull_creation(operation, now, expected)

    payload = intent.payload
    uuid = intent.creation_uuid

    identity =
      Map.merge(repositories, %{
        "github_issue_object_id" => 700,
        "github_issue_node_id" => "I_700",
        "github_number" => 7
      })

    desired = %{
      pull: %{
        github_object_id: 1700,
        github_node_id: "PR_1700",
        github_number: 7,
        remote_updated_at: now,
        confirmed_snapshot: payload["pull_snapshot"],
        confirmed_merge_state: payload["merge_state"],
        provider_identity: identity
      },
      issue: %{
        github_object_id: 700,
        github_node_id: "I_700",
        github_number: 7,
        remote_updated_at: now,
        confirmed_snapshot: payload["issue_snapshot"]
      }
    }

    {:ok, body} = ForgeMirrors.CorrelationMarker.append(nil, uuid)

    transport = %{
      desired
      | pull: %{
          desired.pull
          | confirmed_snapshot:
              Map.merge(desired.pull.confirmed_snapshot, %{
                "body" => body,
                "state" => "open",
                "state_reason" => nil
              })
        },
        issue: %{
          desired.issue
          | confirmed_snapshot:
              Map.merge(desired.issue.confirmed_snapshot, %{
                "body" => body,
                "state" => "open",
                "state_reason" => nil,
                "label_github_ids" => [],
                "assignee_github_ids" => []
              })
        }
    }

    %{
      org: org,
      base: base,
      head: head,
      now: now,
      operation: operation,
      marker: marker,
      intent: intent,
      local: local,
      issue: issue,
      pull: pull,
      desired: desired,
      transport: transport
    }
  end

  test "pins both immutable identities before full-body cleanup and confirms both mappings", c do
    assert {:ok, identified} = identify(c)
    assert identified.operation.state == :effect_pending
    assert identified.operation.external_effect_marker["phase"] == "identified"
    assert identified.operation.external_effect_marker["intent_id"] == c.intent.id

    assert identified.operation.external_effect_marker["remote_identity"] == %{
             "github_object_id" => 1700,
             "github_node_id" => "PR_1700",
             "github_issue_object_id" => 700,
             "github_issue_node_id" => "I_700",
             "github_number" => 7
           }

    refute Repo.exists?(
             from m in MirrorResourceState, where: m.repository_mirror_id == ^c.base.id
           )

    assert {:ok, result} = confirm(c, identified.operation)
    assert result.operation.state == :completed
    assert result.operation.external_effect_marker == nil
    assert result.pull_state.confirmed_snapshot == c.intent.payload["pull_snapshot"]
    assert result.issue_state.confirmed_snapshot == c.intent.payload["issue_snapshot"]
    assert result.pull_state.github_number == 7
    assert c.issue.number == 1
    assert result.issue_state.github_object_id == 700
    assert result.pull_state.github_object_id == 1700
  end

  test "newer local metadata survives while mappings retain old durable intent version and body",
       c do
    c.issue
    |> ForgeIssues.Issue.update_changeset(%{title: "Newer local", body: "Do not overwrite"})
    |> Repo.update!()

    assert {:ok, identified} = identify(c)
    assert {:ok, result} = confirm(c, identified.operation)
    assert result.resource.local_version == 2
    assert result.pull_state.confirmed_local_version == 1
    assert result.issue_state.confirmed_local_version == 1
    assert result.pull_state.confirmed_snapshot["title"] == "Desired"
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).body == "Do not overwrite"
  end

  test "cleanup result cannot confirm before durable identification", c do
    assert {:error, _} = confirm(c, c.operation)
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == c.marker
  end

  test "identification rejects wrong correlation, canonical issue identity and routed head", c do
    for observation <- [
          put_in(c.transport, [:issue, :github_object_id], 701),
          put_in(c.transport, [:issue, :confirmed_snapshot, "body"], "different"),
          put_in(c.transport, [:pull, :provider_identity, "head_repository", "node_id"], "wrong")
        ] do
      assert {:error, _} =
               ForgeMirrors.identify_outbound_pull_creation(
                 c.operation,
                 c.now,
                 c.marker,
                 observation
               )

      assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == c.marker
    end
  end

  test "identified phase is idempotent only for the exact pinned identities", c do
    assert {:ok, identified} = identify(c)
    marker = identified.operation.external_effect_marker

    assert {:ok, repeated} =
             ForgeMirrors.identify_outbound_pull_creation(
               identified.operation,
               c.now,
               marker,
               c.transport
             )

    assert repeated.operation.external_effect_marker == marker
    conflicting = put_in(c.transport, [:pull, :github_object_id], 1701)

    assert {:error, _} =
             ForgeMirrors.identify_outbound_pull_creation(
               repeated.operation,
               c.now,
               marker,
               conflicting
             )
  end

  test "changed refs or foreign cleanup metadata preserve identified recovery evidence", c do
    assert {:ok, identified} = identify(c)
    mismatched = put_in(c.desired, [:pull, :confirmed_snapshot, "body"], "third-party change")
    assert {:error, _} = confirm(c, identified.operation, mismatched)

    Repo.update_all(from(p in "pull_requests", where: p.id == ^c.pull.id),
      set: [head_sha: String.duplicate("c", 40)]
    )

    assert {:error, _} = confirm(c, identified.operation)

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker ==
             identified.operation.external_effect_marker
  end

  test "callback lease loss rolls back BOTH mappings and keeps identified intent", c do
    assert {:ok, identified} = identify(c)

    callback = fn multi ->
      observe(c, multi)
      |> Multi.run(:expire, fn repo, _ ->
        repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
          set: [lease_expires_at: DateTime.add(c.now, -1)]
        )

        {:ok, :expired}
      end)
    end

    assert {:error, :lost_lease} =
             ForgeMirrors.confirm_outbound_pull_creation(
               identified.operation,
               c.now,
               identified.operation.external_effect_marker,
               c.desired,
               callback
             )

    refute Repo.exists?(
             from m in MirrorResourceState, where: m.repository_mirror_id == ^c.base.id
           )

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker ==
             identified.operation.external_effect_marker
  end

  test "inactive head permits identity recovery but not confirmation until fresh eligibility returns",
       c do
    Repo.update_all(from(b in ForgeMirrors.RepositoryMirror, where: b.id == ^c.head.id),
      set: [state: :discovered],
      inc: [lock_version: 1]
    )

    assert {:ok, identified} = identify(c)
    assert {:error, :ineligible_pull} = confirm(c, identified.operation)

    Repo.update_all(from(b in ForgeMirrors.RepositoryMirror, where: b.id == ^c.head.id),
      set: [state: :active],
      inc: [lock_version: 1]
    )

    assert {:ok, _} = confirm(c, identified.operation)
  end

  @tag empty_body: true
  test "actual admission normalizes an empty desired body without changing the local empty string",
       c do
    assert c.intent.payload["pull_snapshot"]["body"] == nil
    assert {:ok, identified} = identify(c)
    assert {:ok, result} = confirm(c, identified.operation)
    assert result.pull_state.confirmed_snapshot["body"] == nil
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).body == ""
  end

  @tag closed: true
  test "closed desired intent is identified as initially open then confirms closed cleanup", c do
    assert c.transport.pull.confirmed_snapshot["state"] == "open"
    assert c.desired.pull.confirmed_snapshot["state"] == "closed"
    assert {:ok, identified} = identify(c)
    assert {:ok, result} = confirm(c, identified.operation)
    assert result.pull_state.confirmed_snapshot["state"] == "closed"
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state == :closed
  end

  test "observation callback cannot change local relationships without a canonical version", c do
    label =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: c.base.repository_id,
        name: "unexpected",
        normalized_name: "unexpected",
        color: "abcdef"
      })

    assert {:ok, identified} = identify(c)

    callback = fn multi ->
      observe(c, multi)
      |> Multi.insert(:unexpected_relationship, %ForgeIssues.IssueLabel{
        issue_id: c.issue.id,
        label_id: label.id
      })
    end

    assert {:error, :invalid_projection} =
             ForgeMirrors.confirm_outbound_pull_creation(
               identified.operation,
               c.now,
               identified.marker,
               c.desired,
               callback
             )

    refute Repo.exists?(from l in ForgeIssues.IssueLabel, where: l.issue_id == ^c.issue.id)
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == identified.marker
  end

  defp identify(c),
    do: ForgeMirrors.identify_outbound_pull_creation(c.operation, c.now, c.marker, c.transport)

  defp confirm(c, operation, observation \\ nil),
    do:
      ForgeMirrors.confirm_outbound_pull_creation(
        operation,
        c.now,
        operation.external_effect_marker,
        observation || c.desired,
        &observe(c, &1)
      )

  defp observe(c, multi),
    do:
      ForgePulls.append_sync_observe(multi, :resource, %{
        repository_id: c.base.repository_id,
        resource_kind: :pull,
        local_resource_id: c.pull.id,
        minimum_local_version: c.intent.local_version,
        expected_fields: c.intent.payload["pull_snapshot"],
        expected_merge_state: %{merged_at: nil, merge_commit_sha: nil}
      })
end
