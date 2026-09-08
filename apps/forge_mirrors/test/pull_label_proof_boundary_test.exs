defmodule ForgeMirrors.PullLabelProofBoundaryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.{DomainOutboxEvent, Repo}
  alias ForgeMirrors.{MirrorOperation, MirrorRefState, MirrorResourceState, PullCreationIntent}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(org)
    head = repository_mirror_fixture(org)
    actor = organization_owner_fixture(org)
    now = DateTime.utc_now(:second)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Local pull",
        body: "Original",
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
        head_sha: String.duplicate("b", 40)
      })

    mappings =
      for index <- 1..2 do
        label =
          Repo.insert!(%ForgeIssues.Label{
            repository_id: base.repository_id,
            name: "label#{index}",
            normalized_name: "label#{index}",
            color: "abcdef"
          })

        Repo.insert!(%ForgeIssues.IssueLabel{issue_id: issue.id, label_id: label.id})
        snapshot = %{"name" => label.name, "color" => label.color, "description" => nil}
        {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(snapshot)

        Repo.insert!(%MirrorResourceState{
          repository_mirror_id: base.id,
          resource_kind: :label,
          local_resource_type: "ForgeIssues.Label",
          local_resource_id: label.id,
          github_object_id: System.unique_integer([:positive, :monotonic]),
          state: :confirmed,
          confirmed_local_version: 1,
          confirmed_snapshot: snapshot,
          confirmed_fingerprint: fingerprint,
          confirmed_remote_updated_at: now
        })
      end

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
          "issue_number" => 7,
          "issue_kind" => "pull_request",
          "sync_version" => 1
        }
      })
      |> Repo.insert!()

    {:ok, {:materialized, [queued]}} = ForgeMirrors.materialize_outbox_event(event)
    now = DateTime.utc_now(:second)
    {:ok, claimed} = ForgeMirrors.claim_operations("label-proof", now, 120, 100, ["sync.pull"])
    op = Enum.find(claimed, &(&1.id == queued.id))
    {:ok, initial} = ForgeMirrors.outbound_pull_creation_context(op)

    expected =
      Map.take(initial, [
        :pull_id,
        :issue_id,
        :expected_local_version,
        :expected_fields,
        :expected_issue_snapshot,
        :expected_merge_state,
        :provider_repositories,
        :pull_eligibility_proof
      ])

    {:ok, marked} = ForgeMirrors.mark_outbound_pull_creation(op, now, expected)

    %{
      marked: marked,
      now: now,
      mappings: mappings,
      base: base,
      head: head,
      issue: issue,
      org: org
    }
  end

  test "one page seeds numeric matches without rebaselining and resumes at the next page", c do
    [first, second] = c.mappings
    assert {:ok, context} = context(c)
    assert context.status == :scanning
    assert length(context.targets) == 2
    assert {:ok, %{operation: yielded, status: :scanning}} = seed(c, context, [label(first)], 2)
    updated = Repo.get!(MirrorResourceState, first.id)
    assert updated.github_node_id == label_node(first)
    assert updated.lock_version == first.lock_version + 1

    assert Map.drop(Map.from_struct(updated), [:github_node_id, :lock_version, :updated_at]) ==
             Map.drop(Map.from_struct(first), [:github_node_id, :lock_version, :updated_at])

    assert Repo.get!(MirrorResourceState, second.id).github_node_id == nil
    assert yielded.external_effect_marker == c.marked.marker
    assert yielded.state == :effect_pending
    assert yielded.lease_owner == nil
    assert Repo.get!(PullCreationIntent, c.marked.intent.id) == c.marked.intent
    next = reclaim(c, yielded)
    assert {:ok, resumed} = context(next)
    assert resumed.checkpoint["page"] == 2
    assert {:ok, %{status: :ready}} = seed(next, resumed, [label(second)], nil)
  end

  test "inventory exhaustion persists unavailable evidence and does not restart", c do
    {:ok, before} = context(c)

    assert {:ok, %{operation: op, status: :unavailable, missing_github_ids: missing}} =
             seed(c, before, [], nil)

    assert missing == Enum.map(c.mappings, & &1.github_object_id)
    next = reclaim(c, op)
    assert {:ok, %{status: :unavailable, checkpoint: checkpoint} = after_scan} = context(next)
    assert checkpoint["complete"]
    assert {:error, :label_inventory_complete} = seed(next, after_scan, [], 2)
  end

  test "known nodes need no scan and unrelated inventory identities are never mapped", c do
    for mapping <- c.mappings do
      Repo.update_all(from(m in MirrorResourceState, where: m.id == ^mapping.id),
        set: [github_node_id: label_node(mapping)]
      )
    end

    assert {:ok, %{status: :ready}} = context(c)
  end

  test "later local membership edits cannot replace the durable desired label set", c do
    Repo.delete_all(from(l in ForgeIssues.IssueLabel, where: l.issue_id == ^c.issue.id))
    {:ok, before} = context(c)

    assert Enum.map(before.targets, & &1.github_object_id) ==
             Enum.map(c.mappings, & &1.github_object_id)

    unrelated = %{
      "id" => 9_223_372_036_854_775_807,
      "node_id" => "Unrelated",
      "name" => "label1",
      "color" => "abcdef",
      "description" => nil
    }

    assert {:ok, %{status: :unavailable}} = seed(c, before, [unrelated], nil)
    assert Enum.all?(c.mappings, &is_nil(Repo.get!(MirrorResourceState, &1.id).github_node_id))
  end

  test "replacement installation cannot provide proof for the original intent", c do
    replacement_id =
      (Repo.aggregate(ForgeMirrors.GitHubAppInstallation, :max, :github_installation_id) || 0) + 1

    {:ok, _} =
      ForgeMirrors.observe_github_app_installation(%{
        github_installation_id: replacement_id,
        github_account_id: c.org.github_account_id,
        github_account_login: c.org.github_account_login,
        account_type: :organization,
        repository_selection: :all,
        permissions: %{"metadata" => "read"},
        state: :active,
        last_verified_at: DateTime.utc_now()
      })

    Repo.update_all(from(o in ForgeMirrors.OrganizationMirror, where: o.id == ^c.org.id),
      set: [github_installation_id: replacement_id],
      inc: [lock_version: 1]
    )

    assert {:error, :ineligible_pull} = context(c)
    assert Enum.all?(c.mappings, &is_nil(Repo.get!(MirrorResourceState, &1.id).github_node_id))
  end

  test "stale mapping version or checkpoint rolls back the entire page", c do
    {:ok, before} = context(c)
    [first | _] = c.mappings

    Repo.update_all(from(m in MirrorResourceState, where: m.id == ^first.id),
      inc: [lock_version: 1]
    )

    assert {:error, :stale_label_proof} = seed(c, before, Enum.map(c.mappings, &label/1), nil)
    assert Enum.all?(c.mappings, &is_nil(Repo.get!(MirrorResourceState, &1.id).github_node_id))
    {:ok, fresh} = context(c)
    stale = put_in(fresh.checkpoint["page"], 2)
    assert {:error, :stale_label_proof} = seed(c, stale, [], nil)
  end

  test "repository identity mismatch cannot seed or advance", c do
    {:ok, before} = context(c)
    page = page(c, Enum.map(c.mappings, &label/1), nil)
    page = put_in(page.repository.github_node_id, "wrong")

    assert {:error, :identity_conflict} =
             ForgeMirrors.seed_outbound_pull_label_nodes(
               c.marked.operation,
               c.now,
               expected(before),
               page
             )

    assert Repo.get!(MirrorOperation, c.marked.operation.id).checkpoint ==
             c.marked.operation.checkpoint
  end

  test "node collision and replacing a known node are rejected atomically", c do
    [first, second] = c.mappings

    Repo.update_all(from(m in MirrorResourceState, where: m.id == ^second.id),
      set: [github_node_id: label_node(first)]
    )

    {:ok, before} = context(c)
    assert {:error, :identity_conflict} = seed(c, before, [label(first)], nil)
    assert {:error, :identity_conflict} = seed(c, before, [label(second)], nil)
    assert Repo.get!(MirrorResourceState, first.id).github_node_id == nil
  end

  test "target nodes obey mapping byte bound and malformed pages cannot progress", c do
    {:ok, before} = context(c)
    [first | _] = c.mappings

    for labels <- [
          [Map.put(label(first), "node_id", String.duplicate("😀", 64))],
          [Map.put(label(first), "node_id", " padded")],
          [label(first), label(first)],
          Enum.map(1..101, fn id -> %{"id" => id, "node_id" => "L_#{id}"} end)
        ] do
      assert {:error, :invalid_label_page} = seed(c, before, labels, nil)
    end

    assert {:error, :invalid_label_page} = seed(c, before, [], 3)
  end

  test "desired mappings must remain confirmed and local to the base repository", c do
    [first | _] = c.mappings

    Repo.update_all(from(m in MirrorResourceState, where: m.id == ^first.id),
      set: [state: :pending]
    )

    assert {:error, :label_mapping_unavailable} = context(c)

    Repo.update_all(from(m in MirrorResourceState, where: m.id == ^first.id),
      set: [state: :confirmed]
    )

    Repo.update_all(from(l in ForgeIssues.Label, where: l.id == ^first.local_resource_id),
      set: [repository_id: c.head.repository_id]
    )

    assert {:error, :label_mapping_unavailable} = context(c)
  end

  test "expired lease prevents both proof retrieval and persistence", c do
    {:ok, before} = context(c)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.marked.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, -1)]
    )

    assert {:error, :lost_lease} = context(c)
    assert {:error, :lost_lease} = seed(c, before, Enum.map(c.mappings, &label/1), nil)
  end

  test "exhausted missing labels become visible conflict with persisted derived evidence", c do
    c = exhausted(c)
    checkpoint = c.marked.operation.checkpoint
    assert {:ok, %{operation: failed, conflict: conflict}} = missing_conflict(c)
    assert conflict.conflict_kind == "relationship_unavailable"
    assert conflict.state == :open

    assert conflict.remote_snapshot == %{
             "reason" => "missing_labels",
             "missing_label_github_ids" => Enum.map(c.mappings, & &1.github_object_id),
             "label_inventory" => checkpoint["pull_creation_label_nodes"]
           }

    assert failed.state == :failed
    assert failed.failure_disposition == :conflict
    assert failed.external_effect_marker == nil
    assert failed.checkpoint == Map.put(checkpoint, "conflicted_effect_marker", c.marked.marker)
    assert Repo.get!(PullCreationIntent, c.marked.intent.id) == c.marked.intent

    refute Repo.exists?(
             from m in MirrorResourceState,
               where: m.repository_mirror_id == ^c.base.id and m.resource_kind in [:issue, :pull]
           )
  end

  test "missing-label conflict requires a complete inventory for this exact intent", c do
    assert {:error, :invalid_conflict_evidence} = missing_conflict(c)
    c = exhausted(c)

    checkpoint =
      put_in(
        c.marked.operation.checkpoint,
        ["pull_creation_label_nodes", "intent_id"],
        c.marked.intent.id + 1
      )

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.marked.operation.id),
      set: [checkpoint: checkpoint]
    )

    assert {:error, :invalid_conflict_evidence} = missing_conflict(c)
  end

  test "missing-label conflict rechecks mappings instead of believing old scan status", c do
    c = exhausted(c)

    for mapping <- c.mappings do
      Repo.update_all(from(m in MirrorResourceState, where: m.id == ^mapping.id),
        set: [github_node_id: label_node(mapping)]
      )
    end

    assert {:error, :invalid_conflict_evidence} = missing_conflict(c)
    assert Repo.get!(MirrorOperation, c.marked.operation.id).state == :effect_pending
  end

  test "caller supplied missing IDs or observation cannot forge relationship evidence", c do
    c = exhausted(c)

    for evidence <- [
          %{"reason" => "missing_labels", "missing_label_github_ids" => [1]},
          %{"reason" => "missing_labels", "observation" => %{"missing_label_github_ids" => [1]}}
        ] do
      assert {:error, :invalid_conflict_evidence} =
               ForgeMirrors.conflict_outbound_pull_creation(
                 c.marked.operation,
                 c.now,
                 c.marked.marker,
                 "relationship_unavailable",
                 evidence
               )
    end
  end

  defp exhausted(c) do
    {:ok, context} = context(c)
    {:ok, %{operation: operation, status: :unavailable}} = seed(c, context, [], nil)
    reclaim(c, operation)
  end

  test "already known duplicate nodes cannot be reported ready", c do
    for mapping <- c.mappings do
      Repo.update_all(from(m in MirrorResourceState, where: m.id == ^mapping.id),
        set: [github_node_id: "Duplicate"]
      )
    end

    assert {:error, :identity_conflict} = context(c)
  end

  test "already known nodes colliding with another repository cannot be reported ready", c do
    for mapping <- c.mappings do
      Repo.update_all(from(m in MirrorResourceState, where: m.id == ^mapping.id),
        set: [github_node_id: label_node(mapping)]
      )
    end

    [first | _] = c.mappings

    Repo.insert!(%MirrorResourceState{
      repository_mirror_id: c.head.id,
      resource_kind: :label,
      github_object_id: 9_223_372_036_854_775_807,
      github_node_id: label_node(first),
      state: :pending
    })

    assert {:error, :identity_conflict} = context(c)
  end

  defp missing_conflict(c),
    do:
      ForgeMirrors.conflict_outbound_pull_creation(
        c.marked.operation,
        c.now,
        c.marked.marker,
        "relationship_unavailable",
        %{"reason" => "missing_labels"}
      )

  defp context(c), do: ForgeMirrors.outbound_pull_label_node_context(c.marked.operation)
  defp expected(context), do: Map.take(context, [:marker, :targets, :checkpoint])

  defp seed(c, context, labels, next),
    do:
      ForgeMirrors.seed_outbound_pull_label_nodes(
        c.marked.operation,
        c.now,
        expected(context),
        page(c, labels, next)
      )

  defp page(c, labels, next),
    do: %{
      labels: labels,
      next_cursor: next,
      repository: %{
        github_object_id: c.base.github_repository_id,
        github_node_id: c.base.github_node_id
      }
    }

  defp label(mapping),
    do: %{
      "id" => mapping.github_object_id,
      "node_id" => label_node(mapping),
      "name" => "Renamed remotely",
      "color" => "123456",
      "description" => nil
    }

  defp label_node(mapping), do: "L_#{mapping.github_object_id}"

  defp reclaim(c, operation) do
    {:ok, claimed} = ForgeMirrors.claim_operations("label-next", c.now, 120, 100, ["sync.pull"])
    op = Enum.find(claimed, &(&1.id == operation.id))
    %{c | marked: %{c.marked | operation: op}}
  end
end
