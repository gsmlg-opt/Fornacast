defmodule ForgeMirrors.PullCreationConflictBoundaryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.{DomainOutboxEvent, Repo}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    PullCreationIntent,
    MirrorConflict
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(org)
    head = repository_mirror_fixture(org)
    actor = organization_owner_fixture(org)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Local pull",
        body: "Original body",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: base.repository_id,
        head_repository_id: head.repository_id,
        base_ref: "refs/heads/main",
        head_ref: "refs/heads/feature",
        base_sha: String.duplicate("a", 40),
        head_sha: String.duplicate("b", 40),
        draft: true
      })

    now = DateTime.utc_now(:second)

    for {binding, ref, oid} <- [
          {base, pull.base_ref, pull.base_sha},
          {head, pull.head_ref, pull.head_sha}
        ] do
      Repo.insert!(%MirrorRefState{
        repository_mirror_id: binding.id,
        ref_name: ref,
        ref_kind: :branch,
        state: :confirmed,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        last_confirmed_at: now
      })
    end

    event =
      %DomainOutboxEvent{}
      |> DomainOutboxEvent.record_changeset(%{
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

    {:ok, {:materialized, [op]}} = ForgeMirrors.materialize_outbox_event(event)
    # The operation gets its due time during materialization, not at setup start.
    now = DateTime.utc_now(:second)

    {:ok, claimed} =
      ForgeMirrors.claim_operations("outbound-create", now, 120, 100, ["sync.pull"])

    %{
      org: org,
      base: base,
      head: head,
      issue: issue,
      pull: pull,
      event: event,
      now: now,
      operation: Enum.find(claimed, &(&1.id == op.id))
    }
  end

  test "empty completed scan records visible conflict and preserves intent and scan", c do
    c = marked(c)
    scan = %{"page" => 2, "candidate" => nil, "complete" => true}

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [checkpoint: %{"pull_creation_recovery" => scan}]
    )

    assert {:ok, result} =
             conflict(c, "ambiguous_external_effect", %{"reason" => "zero_complete_scan"})

    assert result.conflict.state == :open
    assert result.conflict.resource_kind == "pull"
    assert result.conflict.resource_identity == "#{c.base.id}:pull:local:#{c.pull.id}"
    assert result.operation.state == :failed
    assert result.operation.failure_disposition == :conflict
    assert result.operation.external_effect_marker == nil
    assert result.operation.checkpoint["conflicted_effect_marker"] == c.marker
    assert result.operation.checkpoint["pull_creation_recovery"] == scan
    assert Repo.get!(PullCreationIntent, c.intent.id) == c.intent

    refute Repo.exists?(
             from(m in MirrorResourceState,
               where: m.repository_mirror_id == ^c.base.id and m.resource_kind in [:pull, :issue]
             )
           )
  end

  test "multiple UUID candidates remain evidence rather than an invented mapping", c do
    c = marked(c)

    evidence = %{
      "reason" => "multiple_uuid_matches",
      "candidates" => [
        %{"github_object_id" => 900, "github_node_id" => "PR_900", "github_number" => 9},
        %{"github_object_id" => 901, "github_node_id" => "PR_901", "github_number" => 10}
      ]
    }

    assert {:ok, result} = conflict(c, "ambiguous_external_effect", evidence)
    assert result.conflict.remote_snapshot == evidence

    refute Repo.exists?(
             from(m in MirrorResourceState,
               where: m.repository_mirror_id == ^c.base.id and m.resource_kind == :pull
             )
           )
  end

  test "identified third-party metadata keeps paired identity evidence", c do
    c = marked(c)

    marker =
      c.marker
      |> Map.put("phase", "identified")
      |> Map.put("remote_identity", %{
        "github_object_id" => 900,
        "github_node_id" => "PR_900",
        "github_number" => 9,
        "github_issue_object_id" => 901,
        "github_issue_node_id" => "I_901"
      })

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [external_effect_marker: marker]
    )

    c = %{c | marker: marker, operation: Repo.get!(MirrorOperation, c.operation.id)}

    evidence = %{
      "reason" => "third_party_metadata",
      "observation" => %{"body" => "Third-party text"}
    }

    assert {:ok, result} = conflict(c, "third_party_metadata", evidence)

    assert result.operation.checkpoint["conflicted_effect_marker"]["remote_identity"] ==
             marker["remote_identity"]

    assert result.conflict.remote_snapshot == evidence
  end

  test "stale marker and expired lease cannot create a conflict", c do
    c = marked(c)

    assert {:error, :invalid_creation_intent} =
             conflict(
               %{c | marker: Map.put(c.marker, "creation_uuid", Ecto.UUID.generate())},
               "identity_conflict",
               %{"reason" => "pair_mismatch"}
             )

    expired = DateTime.add(c.now, -1)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [lease_expires_at: expired]
    )

    assert {:error, :lost_lease} =
             conflict(
               %{c | operation: %{c.operation | lease_expires_at: expired}},
               "identity_conflict",
               %{"reason" => "pair_mismatch"}
             )

    refute Repo.exists?(from(x in MirrorConflict, where: x.repository_mirror_id == ^c.base.id))
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == c.marker
  end

  test "conflicted intent still blocks later local operations", c do
    c = marked(c)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [
        checkpoint: %{
          "pull_creation_recovery" => %{"page" => 1, "candidate" => nil, "complete" => true}
        }
      ]
    )

    assert {:ok, _} =
             conflict(c, "ambiguous_external_effect", %{"reason" => "zero_complete_scan"})

    op =
      operation_fixture(c.org, %{
        repository_mirror_id: c.base.id,
        kind: "sync.pull",
        cursor: c.operation.cursor,
        next_attempt_at: c.now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("post-conflict", c.now, 120, 100, ["sync.pull"])

    later = Enum.find(claimed, &(&1.id == op.id))
    assert {:error, :creation_reserved} = ForgeMirrors.outbound_pull_creation_context(later)
  end

  test "inactive head and divergent refs remain reportable with fresh local snapshot", c do
    c = marked(c)

    Repo.update_all(from(b in ForgeMirrors.RepositoryMirror, where: b.id == ^c.head.id),
      set: [state: :discovered]
    )

    Repo.update_all(from(p in ForgePulls.PullRequest, where: p.id == ^c.pull.id),
      set: [head_sha: String.duplicate("c", 40)]
    )

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [body: "Edited local", sync_version: 2]
    )

    assert {:ok, result} = conflict(c, "identity_conflict", %{"reason" => "refs_changed"})
    assert result.conflict.local_snapshot["local_version"] == 2
    assert result.conflict.local_snapshot["pull_snapshot"]["body"] == "Edited local"

    assert result.conflict.local_snapshot["pull_snapshot"]["head_sha"] ==
             String.duplicate("c", 40)

    assert result.conflict.baseline_snapshot["pull_snapshot"]["body"] == "Original body"
  end

  test "zero-match conflict requires the completed empty persisted scan", c do
    c = marked(c)

    assert {:error, :invalid_conflict_evidence} =
             conflict(c, "ambiguous_external_effect", %{"reason" => "zero_complete_scan"})

    refute Repo.exists?(from(x in MirrorConflict, where: x.repository_mirror_id == ^c.base.id))
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == c.marker
  end

  test "duplicate candidate evidence cannot claim multiple UUID matches", c do
    c = marked(c)
    candidate = %{"github_object_id" => 900, "github_node_id" => "PR_900", "github_number" => 9}
    evidence = %{"reason" => "multiple_uuid_matches", "candidates" => [candidate, candidate]}

    assert {:error, :invalid_conflict_evidence} =
             conflict(c, "ambiguous_external_effect", evidence)

    refute Repo.exists?(from(x in MirrorConflict, where: x.repository_mirror_id == ^c.base.id))
  end

  test "unbounded observations and arbitrary error strings are rejected", c do
    c = marked(c)

    assert {:error, :invalid_conflict_evidence} =
             conflict(c, "identity_conflict", %{"reason" => "raw exception text"})

    assert {:error, :invalid_conflict_evidence} =
             conflict(c, "third_party_metadata", %{
               "reason" => "third_party_metadata",
               "observation" => %{"body" => String.duplicate("x", 2_000_001)}
             })

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == c.marker
  end

  defp marked(c) do
    {:ok, context} = ForgeMirrors.outbound_pull_creation_context(c.operation)

    expected =
      Map.take(context, [
        :pull_id,
        :issue_id,
        :expected_local_version,
        :expected_fields,
        :expected_issue_snapshot,
        :expected_merge_state,
        :provider_repositories,
        :pull_eligibility_proof
      ])

    {:ok, result} = ForgeMirrors.mark_outbound_pull_creation(c.operation, c.now, expected)
    Map.merge(c, %{operation: result.operation, marker: result.marker, intent: result.intent})
  end

  defp conflict(c, kind, evidence),
    do: ForgeMirrors.conflict_outbound_pull_creation(c.operation, c.now, c.marker, kind, evidence)
end
