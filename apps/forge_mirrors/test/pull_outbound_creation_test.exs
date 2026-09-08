defmodule ForgeMirrors.PullOutboundCreationTest do
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

  test "local unmapped context derives both snapshots and represented proof", c do
    assert {:ok, context} = ForgeMirrors.outbound_pull_creation_context(c.operation)
    assert context.phase == :unmarked
    assert context.pull_id == c.pull.id
    assert context.issue_id == c.issue.id
    assert context.expected_issue_snapshot["label_github_ids"] == []
    assert context.git_proof.head.repository_id == c.head.repository_id
  end

  test "intent and compact marker commit once; retry cannot authorize another POST", c do
    expected = expected(c)
    assert {:ok, first} = mark(c, expected)
    assert first.newly_marked
    assert first.operation.state == :effect_pending
    assert first.marker["phase"] == "unresolved"
    intent = Repo.get!(PullCreationIntent, first.marker["intent_id"])
    assert intent.payload["pull_snapshot"] == expected.expected_fields
    assert intent.payload["issue_snapshot"] == expected.expected_issue_snapshot
    assert intent.payload_fingerprint == first.marker["intent_fingerprint"]
    assert {:ok, retry} = mark(%{c | operation: first.operation}, expected)
    refute retry.newly_marked
    assert retry.marker == first.marker

    assert Repo.aggregate(
             from(i in PullCreationIntent, where: i.operation_id == ^c.operation.id),
             :count
           ) == 1
  end

  test "maximum emoji bodies remain durable while marker stays compact", c do
    body = String.duplicate("😀", 65_536)
    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id), set: [body: body])
    assert {:ok, first} = mark(c, expected(c))
    intent = Repo.get!(PullCreationIntent, first.marker["intent_id"])
    assert intent.payload["pull_snapshot"]["body"] == body
    assert intent.payload["issue_snapshot"]["body"] == body
    assert byte_size(JSON.encode!(first.marker)) < 4096
  end

  test "local edit after mark cannot rewrite the original recovery intent", c do
    assert {:ok, first} = mark(c, expected(c))

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [body: "New body", sync_version: 2]
    )

    assert {:ok, context} = ForgeMirrors.outbound_pull_creation_context(first.operation)
    assert context.phase == :recovery
    assert context.intent.payload["pull_snapshot"]["body"] == "Original body"
    assert {:ok, retry} = mark(%{c | operation: first.operation}, %{})
    refute retry.newly_marked
  end

  test "stale snapshot fails without publishing intent or marker", c do
    stale = expected(c)

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [sync_version: 2]
    )

    assert {:error, :stale_baseline} = mark(c, stale)
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil

    assert Repo.aggregate(
             from(i in PullCreationIntent, where: i.operation_id == ^c.operation.id),
             :count
           ) == 0
  end

  test "caller transaction cannot receive a precommit creator capability", c do
    expected = expected(c)

    assert {:error, :cancel} =
             Repo.transaction(fn ->
               assert {:error, :transaction_not_allowed} = mark(c, expected)
               Repo.rollback(:cancel)
             end)

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  test "persisted nonlocal event cannot be spoofed by cursor origin", c do
    Repo.update_all(from(e in DomainOutboxEvent, where: e.id == ^c.event.id),
      set: [origin: :github]
    )

    assert {:error, :invalid_local_event} =
             ForgeMirrors.outbound_pull_creation_context(c.operation)
  end

  test "canonical issue mapping prevents duplicate pull creation", c do
    Repo.insert!(%MirrorResourceState{
      repository_mirror_id: c.base.id,
      resource_kind: :issue,
      local_resource_type: "ForgeIssues.Issue",
      local_resource_id: c.issue.id,
      state: :confirmed
    })

    assert {:error, :identity_conflict} = ForgeMirrors.outbound_pull_creation_context(c.operation)
  end

  test "unknown label is a prerequisite rather than an omitted desired set", c do
    label =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: c.base.repository_id,
        name: "new",
        normalized_name: "new",
        color: "abcdef"
      })

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.issue.id, label_id: label.id})

    assert {:error, {:unmapped_label, _}} =
             ForgeMirrors.outbound_pull_creation_context(c.operation)
  end

  test "unrepresented head and stale refs cannot receive POST admission", c do
    Repo.update_all(from(p in ForgePulls.PullRequest, where: p.id == ^c.pull.id),
      set: [head_repository_id: nil]
    )

    assert {:error, :ineligible_pull} = ForgeMirrors.outbound_pull_creation_context(c.operation)
  end

  test "closed unmerged intent retains desired state for post-create cleanup", c do
    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [state: :closed, state_reason: "completed"]
    )

    assert {:ok, first} = mark(c, expected(c))
    assert first.intent.payload["pull_snapshot"]["state"] == "closed"
    assert Repo.get!(ForgeIssues.Issue, c.issue.id).state == :closed
  end

  test "generic transitions cannot erase the unresolved creation evidence", c do
    assert {:ok, first} = mark(c, expected(c))
    assert {:error, :invalid_transition} = ForgeMirrors.complete_operation(first.operation, c.now)

    assert {:error, :invalid_transition} =
             ForgeMirrors.retry_operation(
               first.operation,
               c.now,
               DateTime.add(c.now, 5),
               "network",
               external_effect_reconciled: true
             )

    assert {:error, :invalid_transition} =
             ForgeMirrors.fail_operation(first.operation, c.now, "provider_validation")

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == first.marker
  end

  test "another operation cannot create this pull while an old intent remains", c do
    assert {:ok, first} = mark(c, expected(c))
    # Simulate a terminal review conflict; ordinary APIs cannot erase this marker.
    Repo.update_all(from(o in MirrorOperation, where: o.id == ^first.operation.id),
      set: [
        state: :failed,
        failure_class: "provider_validation",
        failure_disposition: :terminal,
        completed_at: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        external_effect_marker: nil,
        effect_marked_at: nil
      ]
    )

    op =
      operation_fixture(c.org, %{
        repository_mirror_id: c.base.id,
        kind: "sync.pull",
        cursor: c.operation.cursor,
        next_attempt_at: c.now
      })

    {:ok, claimed} = ForgeMirrors.claim_operations("later-create", c.now, 120, 100, ["sync.pull"])
    op = Enum.find(claimed, &(&1.id == op.id))
    assert {:error, :creation_reserved} = ForgeMirrors.outbound_pull_creation_context(op)
  end

  test "database rejects oversized intent payload even when changeset validation is bypassed",
       c do
    assert {:ok, first} = mark(c, expected(c))

    changeset =
      first.intent
      |> Ecto.Changeset.change(payload: %{"oversized" => String.duplicate("x", 2_000_001)})
      |> Ecto.Changeset.check_constraint(:payload,
        name: :mirror_pull_creation_intents_payload_check
      )

    assert {:error, rejected} = Repo.update(changeset, mode: :savepoint)
    assert rejected.errors[:payload]
    assert Repo.get!(PullCreationIntent, first.intent.id).payload == first.intent.payload
  end

  test "database rejects a nonobject payload and nonpositive local version", c do
    assert {:ok, first} = mark(c, expected(c))

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE mirror_pull_creation_intents SET payload = '[]'::jsonb WHERE id = $1",
               [first.intent.id],
               mode: :savepoint
             )

    changeset =
      first.intent
      |> Ecto.Changeset.change(local_version: 0)
      |> Ecto.Changeset.check_constraint(:local_version,
        name: :mirror_pull_creation_intents_version_check
      )

    assert {:error, rejected} = Repo.update(changeset, mode: :savepoint)
    assert rejected.errors[:local_version]

    assert Repo.get!(PullCreationIntent, first.intent.id).local_version ==
             first.intent.local_version
  end

  test "ordinary operation deletion cannot erase unresolved recovery ownership", c do
    assert {:ok, first} = mark(c, expected(c))

    changeset =
      first.operation
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:id,
        name: :mirror_pull_creation_intents_operation_id_fkey
      )

    assert {:error, rejected} = Repo.delete(changeset, mode: :savepoint)
    assert rejected.errors[:id]
    assert Repo.get!(PullCreationIntent, first.intent.id).operation_id == first.operation.id
    assert Repo.get!(MirrorOperation, first.operation.id).external_effect_marker == first.marker
  end

  test "expired lease produces neither an intent nor a creator grant", c do
    expected = expected(c)
    expired = DateTime.add(c.now, -1, :second)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [lease_expires_at: expired]
    )

    c = %{c | operation: %{c.operation | lease_expires_at: expired}}
    assert {:error, :lost_lease} = mark(c, expected)

    assert Repo.aggregate(
             from(i in PullCreationIntent, where: i.operation_id == ^c.operation.id),
             :count
           ) == 0

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  test "intent changeset rejects rewriting recovery snapshots", c do
    assert {:ok, first} = mark(c, expected(c))
    changeset = PullCreationIntent.create_changeset(first.intent, %{payload: %{}})
    refute changeset.valid?
    assert changeset.errors[:payload]
  end

  test "fresh recovery proof allows newer scalar edits without granting POST", c do
    assert {:ok, first} = mark(c, expected(c))

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [body: "New", sync_version: 2]
    )

    assert {:ok, recovery} = ForgeMirrors.outbound_pull_creation_recovery_context(first.operation)
    assert recovery.current_projection.local_version == 2
    assert recovery.current_projection.fields["body"] == "New"
    assert recovery.intent.payload["pull_snapshot"]["body"] == "Original body"
    assert recovery.git_proof.head.repository_id == c.head.repository_id
    assert recovery.routing.head.github_node_id == c.head.github_node_id
    refute Map.has_key?(recovery, :newly_marked)
  end

  test "changed refs cannot acquire recovery effect proof", c do
    assert {:ok, first} = mark(c, expected(c))

    Repo.update_all(from(p in ForgePulls.PullRequest, where: p.id == ^c.pull.id),
      set: [head_sha: String.duplicate("c", 40)]
    )

    assert {:error, :ineligible_pull} =
             ForgeMirrors.outbound_pull_creation_recovery_context(first.operation)
  end

  test "scan checkpoints persist cursor and marker while releasing the lease", c do
    assert {:ok, first} = mark(c, expected(c))
    next = %{"page" => 2, "candidate" => nil, "complete" => false}
    assert {:ok, op} = checkpoint(c, first.operation, initial_scan(), next)
    assert op.state == :effect_pending
    assert op.lease_owner == nil
    assert op.external_effect_marker == first.marker
    assert op.checkpoint["pull_creation_recovery"] == next
    assert {:error, :lost_lease} = checkpoint(c, first.operation, initial_scan(), next)
  end

  test "stale checkpoint cannot overwrite persisted scan progress", c do
    assert {:ok, first} = mark(c, expected(c))
    stale = %{"page" => 2, "candidate" => nil, "complete" => false}

    assert {:error, :invalid_recovery_checkpoint} =
             checkpoint(c, first.operation, stale, %{stale | "page" => 3})

    assert Repo.get!(MirrorOperation, first.operation.id).checkpoint == %{}
  end

  test "completed scan cannot reopen or substitute its candidate", c do
    assert {:ok, first} = mark(c, expected(c))
    candidate = %{"github_object_id" => 900, "github_node_id" => "PR_900", "github_number" => 9}
    complete = %{"page" => 1, "candidate" => candidate, "complete" => true}

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^first.operation.id),
      set: [checkpoint: %{"pull_creation_recovery" => complete}]
    )

    op = Repo.get!(MirrorOperation, first.operation.id)

    assert {:error, :invalid_recovery_checkpoint} =
             checkpoint(c, op, complete, %{complete | "complete" => false, "page" => 2})

    assert {:error, :invalid_recovery_checkpoint} =
             checkpoint(c, op, complete, put_in(complete["candidate"]["github_object_id"], 901))

    assert {:ok, deferred} = checkpoint(c, op, complete, complete)
    assert deferred.checkpoint["pull_creation_recovery"] == complete
  end

  test "inactive head prevents cleanup proof but not marker-preserving defer", c do
    assert {:ok, first} = mark(c, expected(c))

    Repo.update_all(from(b in ForgeMirrors.RepositoryMirror, where: b.id == ^c.head.id),
      set: [state: :discovered]
    )

    assert {:error, :ineligible_pull} =
             ForgeMirrors.outbound_pull_creation_recovery_context(first.operation)

    assert {:ok, deferred} = checkpoint(c, first.operation, initial_scan(), initial_scan())
    assert deferred.external_effect_marker == first.marker
  end

  test "expired lease cannot persist a scan checkpoint", c do
    assert {:ok, first} = mark(c, expected(c))
    expired = DateTime.add(c.now, -1)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^first.operation.id),
      set: [lease_expires_at: expired]
    )

    assert {:error, :lost_lease} =
             checkpoint(
               c,
               %{first.operation | lease_expires_at: expired},
               initial_scan(),
               initial_scan()
             )

    assert Repo.get!(MirrorOperation, first.operation.id).checkpoint == %{}
  end

  test "replacement installation cannot authorize cleanup of an older creation intent", c do
    assert {:ok, first} = mark(c, expected(c))
    replacement_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, _} =
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

    assert {:error, :ineligible_pull} =
             ForgeMirrors.outbound_pull_creation_recovery_context(first.operation)

    assert Repo.get!(MirrorOperation, first.operation.id).external_effect_marker == first.marker
  end

  defp initial_scan, do: %{"page" => 1, "candidate" => nil, "complete" => false}

  defp checkpoint(c, op, expected, next),
    do:
      ForgeMirrors.checkpoint_outbound_pull_creation(
        op,
        expected,
        next,
        DateTime.add(c.now, 5),
        c.now
      )

  defp expected(c) do
    {:ok, context} = ForgeMirrors.outbound_pull_creation_context(c.operation)

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
  end

  defp mark(c, expected),
    do: ForgeMirrors.mark_outbound_pull_creation(c.operation, c.now, expected)
end
