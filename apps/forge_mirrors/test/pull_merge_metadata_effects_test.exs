defmodule ForgeMirrors.PullMergeMetadataEffectsTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  import Ecto.Query
  alias Ecto.{Changeset, Multi}

  alias ForgeMirrors.{
    MirrorConflict,
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    PullEligibility,
    PullMergeBoundary,
    PullMergeConfirmation,
    PullMergeMetadataEffects,
    PullMetadataIntent
  }

  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: organization.github_installation_id
    )
    |> Changeset.change(
      permissions: %{
        "contents" => "write",
        "pull_requests" => "write",
        "issues" => "read",
        "metadata" => "read"
      }
    )
    |> Repo.update!()

    binding = repository_mirror_fixture(organization)
    head = repository_mirror_fixture(organization)
    actor = organization_owner_fixture(organization)

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: binding.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Merge",
        body: "original",
        author_user_id: actor.id
      })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: binding.repository_id,
        head_repository_id: head.repository_id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    now = DateTime.utc_now(:second)

    for {mirror, ref, oid} <- [
          {binding, pull.base_ref, pull.base_sha},
          {head, pull.head_ref, pull.head_sha}
        ] do
      %MirrorRefState{}
      |> MirrorRefState.persistence_changeset(%{
        repository_mirror_id: mirror.id,
        ref_name: ref,
        ref_kind: :branch,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        state: :confirmed,
        last_confirmed_at: now
      })
      |> Repo.insert!()
    end

    {:ok, local} = ForgePulls.sync_projection(binding.repository_id, :pull, pull.id)

    identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => %{
        "id" => binding.github_repository_id,
        "node_id" => binding.github_node_id
      },
      "head_repository" => %{"id" => head.github_repository_id, "node_id" => head.github_node_id}
    }

    pull_mapping =
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: binding.id,
        resource_kind: :pull,
        local_resource_type: "ForgePulls.PullRequest",
        local_resource_id: pull.id,
        github_object_id: 902,
        github_node_id: "PR_902",
        github_number: 7,
        confirmed_local_version: local.local_version,
        confirmed_remote_updated_at: now,
        confirmed_snapshot: local.fields,
        confirmed_merge_state: %{"merged_at" => nil, "merge_commit_sha" => nil},
        provider_identity: identity,
        state: :confirmed
      })
      |> Repo.insert!()

    {:ok, pull_fingerprint} = ForgeMirrors.resource_fingerprint(local.fields)
    pull_mapping |> Changeset.change(confirmed_fingerprint: pull_fingerprint) |> Repo.update!()

    issue_snapshot =
      Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
        "label_github_ids" => [],
        "assignee_github_ids" => []
      })

    {:ok, issue_fingerprint} = ForgeMirrors.resource_fingerprint(issue_snapshot)

    issue_mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: binding.id,
        resource_kind: :issue,
        local_resource_type: "ForgeIssues.Issue",
        local_resource_id: issue.id,
        github_object_id: 901,
        github_node_id: "I_901",
        github_number: 7,
        confirmed_local_version: local.local_version,
        confirmed_remote_updated_at: now,
        confirmed_snapshot: issue_snapshot,
        confirmed_fingerprint: issue_fingerprint,
        state: :confirmed
      })

    operation =
      operation_fixture(organization, %{
        repository_mirror_id: binding.id,
        kind: "merge.pull",
        cursor: %{"issue_id" => issue.id, "pull_id" => pull.id},
        next_attempt_at: now
      })

    {:ok, claimed} = ForgeMirrors.claim_operations("merge-metadata", now, 60, 100, ["merge.pull"])
    operation = Enum.find(claimed, &(&1.id == operation.id))

    {:ok, proof} =
      PullEligibility.check(
        binding.id,
        head.repository_id,
        Map.take(pull, [:base_ref, :head_ref, :base_sha, :head_sha])
      )

    expected = %{
      pull_id: pull.id,
      issue_id: issue.id,
      local_version: local.local_version,
      fields: local.fields,
      provider_identity: identity,
      resource_state_lock_version: pull_mapping.lock_version,
      pull_eligibility_proof: json(proof)
    }

    signature = %{
      "name" => actor.username,
      "email" => actor.email,
      "seconds" => 1_750_000_000,
      "offset_minutes" => 0
    }

    request = %{
      repository_id: binding.repository_id,
      resource_kind: :pull,
      local_resource_id: pull.id,
      expected_local_version: local.local_version,
      expected_fields: local.fields,
      expected_merge_state: local.merge_state,
      expected_head_repository_id: head.repository_id,
      coordinator_operation_id: operation.id,
      actor_user_id: actor.id,
      request_id: "merge-#{operation.id}",
      commit_intent: %{"message" => "Merge", "author" => signature, "committer" => signature}
    }

    %{
      organization: organization,
      binding: binding,
      head: head,
      issue: issue,
      issue_mapping: issue_mapping,
      now: now,
      operation: operation,
      pull: pull,
      expected: expected,
      request: request
    }
  end

  test "atomically replaces the merge marker with a compact metadata pointer", c do
    {operation, intent} = marked(c)
    original_marker = operation.external_effect_marker
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    assert result.operation.state == :effect_pending
    assert result.marker == result.operation.external_effect_marker
    assert result.marker["phase"] == "metadata_issue_pending"
    assert result.marker["action"] == "update_remote_pull_issue"
    assert result.marker["merge_operation_id"] == intent.id
    assert result.marker["merge_oid"] == intent.merge_oid
    assert result.marker["metadata_intent_id"] == result.intent.id
    assert result.marker["metadata_intent_hash"] == result.intent.payload_fingerprint
    assert result.marker["expected_remote_updated_at"] == DateTime.to_iso8601(c.now)
    assert result.marker["expected_remote_issue_updated_at"] == DateTime.to_iso8601(c.now)

    assert Map.drop(result.marker, [
             "phase",
             "action",
             "metadata_intent_id",
             "metadata_intent_hash",
             "expected_remote_updated_at",
             "expected_remote_issue_updated_at"
           ]) == Map.delete(original_marker, "phase")

    refute Map.has_key?(result.marker, "target_issue")
    assert result.intent.payload["target_issue"] == target
    assert Repo.aggregate(PullMetadataIntent, :count) == 1
  end

  test "the same exact effect is idempotent", c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, first} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    assert {:ok, replay} =
             PullMergeMetadataEffects.mark(
               first.operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    assert replay.operation.id == first.operation.id
    assert replay.operation.lock_version == first.operation.lock_version
    assert replay.intent.id == first.intent.id
    assert Repo.aggregate(PullMetadataIntent, :count) == 1
  end

  test "invalid observation target local version and lease create no metadata intent", c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    invalid = [
      {Map.put(observation, :remote_base_oid, intent.expected_base_oid), version, target},
      {observation, version, Map.put(target, "title", "not the exact target")},
      {observation, version - 1, target}
    ]

    Enum.each(invalid, fn {observed, local_version, proposed} ->
      assert {:error, _} =
               PullMergeMetadataEffects.mark(
                 operation,
                 c.now,
                 intent,
                 observed,
                 local_version,
                 proposed
               )

      assert Repo.aggregate(PullMetadataIntent, :count) == 0

      assert Repo.get!(MirrorOperation, operation.id).external_effect_marker ==
               operation.external_effect_marker
    end)

    assert {:error, _} =
             PullMergeMetadataEffects.mark(
               %{operation | lease_owner: "forged"},
               c.now,
               intent,
               observation,
               version,
               target
             )

    assert Repo.aggregate(PullMetadataIntent, :count) == 0
  end

  test "recovery validates hash scope and immutable payload while allowing newer local edits",
       c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    c.issue
    |> Changeset.change(title: "newer local edit", sync_version: version + 1)
    |> Repo.update!()

    assert {:ok, recovered} = PullMergeMetadataEffects.recovery_context(result.operation, c.now)
    assert recovered.metadata_intent.id == result.intent.id
    assert recovered.local_projection.local_version == version + 1

    tamper_intent(result.intent, payload: Map.put(result.intent.payload, "v", 2))

    assert {:error, :stale_merge_identity} =
             PullMergeMetadataEffects.recovery_context(result.operation, c.now)
  end

  test "recovery rejects intent scope and marker hash tampering", c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    tamper_intent(result.intent, repository_mirror_id: c.head.id)

    assert {:error, :stale_merge_identity} =
             PullMergeMetadataEffects.recovery_context(result.operation, c.now)

    Repo.update_all(from(i in PullMetadataIntent, where: i.id == ^result.intent.id),
      set: [repository_mirror_id: c.binding.id]
    )

    marker = Map.put(result.marker, "metadata_intent_hash", String.duplicate("0", 64))

    operation =
      result.operation |> Changeset.change(external_effect_marker: marker) |> Repo.update!()

    assert {:error, :stale_merge_identity} =
             PullMergeMetadataEffects.recovery_context(operation, c.now)
  end

  test "recovery rejects altered merge proof unexpected keys timestamps and every intent scope",
       c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    marker_variants = [
      Map.delete(result.marker, "expected_base_oid"),
      Map.put(result.marker, "merge_oid", String.duplicate("e", 40)),
      Map.put(result.marker, "unexpected", true),
      Map.put(
        result.marker,
        "expected_remote_issue_updated_at",
        DateTime.to_iso8601(DateTime.add(c.now, -1, :second))
      ),
      Map.put(result.marker, "metadata_intent_id", nil),
      Map.put(result.marker, "metadata_intent_id", "1"),
      Map.put(result.marker, "metadata_intent_id", [result.intent.id])
    ]

    Enum.each(marker_variants, fn marker ->
      tampered = replace_marker(result.operation, marker)

      assert {:error, :stale_merge_identity} =
               PullMergeMetadataEffects.recovery_context(tampered, c.now)

      replace_marker(tampered, result.marker)
    end)

    other_operation =
      operation_fixture(c.organization, %{
        repository_mirror_id: c.binding.id,
        kind: "merge.pull",
        cursor: %{"issue_id" => c.issue.id, "pull_id" => c.pull.id},
        next_attempt_at: c.now
      })

    other_issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: c.binding.repository_id,
        number: 8,
        kind: :issue,
        title: "Other",
        author_user_id: c.issue.author_user_id
      })

    scope_variants = [
      [operation_id: other_operation.id],
      [repository_mirror_id: c.head.id],
      [issue_id: other_issue.id],
      [sequence: 2]
    ]

    Enum.each(scope_variants, fn attrs ->
      tamper_intent(result.intent, attrs)

      assert {:error, :stale_merge_identity} =
               PullMergeMetadataEffects.recovery_context(result.operation, c.now)

      tamper_intent(result.intent,
        operation_id: result.operation.id,
        repository_mirror_id: c.binding.id,
        issue_id: c.issue.id,
        sequence: 1
      )
    end)
  end

  test "metadata recovery survives lease release and reclaim", c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    retry_at = DateTime.add(c.now, 2, :second)
    assert {:ok, yielded} = PullMergeBoundary.defer(result.operation, c.now, retry_at, :timeout)
    assert yielded.lease_owner == nil

    assert {:ok, claimed} =
             ForgeMirrors.claim_operations("merge-metadata-recovery", retry_at, 60, 100, [
               "merge.pull"
             ])

    reclaimed = Enum.find(claimed, &(&1.id == operation.id))
    assert {:ok, recovered} = PullMergeMetadataEffects.recovery_context(reclaimed, retry_at)
    assert recovered.metadata_intent.id == result.intent.id
  end

  test "a maximum body remains outside the bounded operation marker", c do
    {operation, intent} = marked(c)
    body = String.duplicate("x", 65_536)
    {version, target, observation} = local_edit(c, intent, body: body)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    assert byte_size(JSON.encode!(result.marker)) < 65_536
    assert result.intent.payload["target_issue"]["body"] == body
  end

  test "merge confirmation accepts a valid metadata marker and clears it", c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    confirmed_observation = put_in(observation.issue.confirmed_snapshot, target)

    confirmed_observation =
      update_in(
        confirmed_observation.pull.confirmed_snapshot,
        &Map.merge(&1, Map.take(target, ~w(title body)))
      )

    assert {:ok, confirmed} =
             Repo.transaction(fn ->
               assert :ok =
                        PullMergeConfirmation.authorize(
                          result.operation,
                          c.now,
                          intent,
                          confirmed_observation
                        )

               actual = merge_locally(c, intent, target)

               assert {:ok, confirmed} =
                        PullMergeConfirmation.confirm(
                          result.operation,
                          c.now,
                          intent,
                          confirmed_observation,
                          actual
                        )

               confirmed
             end)

    assert confirmed.operation.state == :completed
    assert confirmed.operation.external_effect_marker == nil
    assert Repo.get!(PullMetadataIntent, result.intent.id).id == result.intent.id
  end

  test "merge confirmation cannot clear a metadata marker before the remote target is observed",
       c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    assert {:ok, {:error, :merge_metadata_unconfirmed}} =
             Repo.transaction(fn ->
               assert {:error, :merge_metadata_unconfirmed} =
                        PullMergeConfirmation.authorize(
                          result.operation,
                          c.now,
                          intent,
                          observation
                        )

               actual = merge_locally(c, intent, target)
               PullMergeConfirmation.confirm(result.operation, c.now, intent, observation, actual)
             end)

    persisted = Repo.get!(MirrorOperation, result.operation.id)
    assert persisted.state == :effect_pending
    assert persisted.external_effect_marker == result.marker
  end

  test "merge confirmation is intrinsically bound to the current metadata intent target", c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               version,
               target
             )

    third = target |> Map.put("title", "Third state") |> Map.put("body", "third body")

    c.issue
    |> Changeset.change(title: third["title"], body: third["body"], sync_version: version + 1)
    |> Repo.update!()

    third_observation = applied_observation(observation, third, c.now)

    assert {:ok, {:error, :merge_metadata_unconfirmed}} =
             Repo.transaction(fn ->
               PullMergeConfirmation.authorize(
                 result.operation,
                 c.now,
                 intent,
                 third_observation
               )
             end)

    assert {:ok, {:error, :merge_metadata_unconfirmed}} =
             Repo.transaction(fn ->
               actual = merge_locally(c, intent, third)

               PullMergeConfirmation.confirm(
                 result.operation,
                 c.now,
                 intent,
                 third_observation,
                 actual
               )
             end)

    persisted = Repo.get!(MirrorOperation, result.operation.id)
    assert persisted.state == :effect_pending
    assert persisted.external_effect_marker == result.marker
  end

  test "a newer local scalar edit appends sequence N plus 1 only after the prior target is observed",
       c do
    {operation, intent} = marked(c)
    {version, target_a, initial_observation} = local_edit(c, intent)

    assert {:ok, first} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               initial_observation,
               version,
               target_a
             )

    title_c = "Second local title"
    body_c = "second local body"

    c.issue
    |> Changeset.change(title: title_c, body: body_c, sync_version: version + 1)
    |> Repo.update!()

    target_c = target_a |> Map.put("title", title_c) |> Map.put("body", body_c)
    observed_at = DateTime.add(c.now, 1, :second)
    observed_a = applied_observation(initial_observation, target_a, observed_at)

    assert {:ok, second} =
             PullMergeMetadataEffects.mark(
               first.operation,
               observed_at,
               intent,
               observed_a,
               version + 1,
               target_c
             )

    assert second.intent.sequence == 2
    assert second.intent.payload["expected_remote_issue"] == target_a
    assert second.intent.payload["target_issue"] == target_c
    assert second.marker["metadata_intent_id"] == second.intent.id
    assert second.marker["metadata_intent_id"] != first.intent.id
    assert Repo.get!(PullMetadataIntent, first.intent.id).payload["target_issue"] == target_a
    assert Repo.aggregate(PullMetadataIntent, :count) == 2
  end

  test "stale and third remote states cannot advance the metadata intent sequence", c do
    {operation, intent} = marked(c)
    {version, target_a, initial_observation} = local_edit(c, intent)

    assert {:ok, first} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               initial_observation,
               version,
               target_a
             )

    c.issue
    |> Changeset.change(title: "Next local", sync_version: version + 1)
    |> Repo.update!()

    target_c = Map.put(target_a, "title", "Next local")
    observed_at = DateTime.add(c.now, 1, :second)

    stale = %{
      initial_observation
      | pull: %{initial_observation.pull | remote_updated_at: observed_at}
    }

    stale = put_in(stale.issue.remote_updated_at, observed_at)

    third =
      initial_observation
      |> applied_observation(Map.put(target_a, "title", "Third remote"), observed_at)

    for remote <- [stale, third] do
      assert {:error, :merge_metadata_unconfirmed} =
               PullMergeMetadataEffects.mark(
                 first.operation,
                 observed_at,
                 intent,
                 remote,
                 version + 1,
                 target_c
               )
    end

    assert Repo.aggregate(PullMetadataIntent, :count) == 1
    assert Repo.get!(MirrorOperation, operation.id).external_effect_marker == first.marker
  end

  test "third remote state records durable ambiguous external effect and preserves merge evidence",
       c do
    {operation, intent} = marked(c)
    {version, target, initial_observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               initial_observation,
               version,
               target
             )

    third = Map.put(initial_observation.issue.confirmed_snapshot, "title", "Third remote")
    third_observation = applied_observation(initial_observation, third, c.now)
    retry_at = DateTime.add(c.now, 2, :second)

    assert {:ok, yielded} =
             PullMergeConfirmation.record_ambiguous_effect(
               result.operation,
               c.now,
               retry_at,
               third_observation
             )

    assert yielded.lease_owner == nil
    assert yielded.external_effect_marker == result.marker
    assert Repo.get!(ForgePulls.MergeOperation, intent.id).state == :merge_written

    conflict =
      Repo.get_by!(MirrorConflict,
        organization_mirror_id: result.operation.organization_mirror_id,
        resource_kind: "pull_merge",
        resource_identity: to_string(intent.id),
        state: :open
      )

    assert conflict.conflict_kind == "ambiguous_external_effect"
    assert conflict.baseline_snapshot == result.intent.payload["expected_remote_issue"]
    assert conflict.local_snapshot == result.intent.payload["target_issue"]
    assert conflict.remote_snapshot == third
  end

  test "ambiguity rejects target and exact preimage but accepts preimage with a changed timestamp",
       c do
    {operation, intent} = marked(c)
    {version, target, initial_observation} = local_edit(c, intent)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               initial_observation,
               version,
               target
             )

    target_observation = applied_observation(initial_observation, target, c.now)
    retry_at = DateTime.add(c.now, 2, :second)

    for remote <- [target_observation, initial_observation] do
      assert {:error, :external_effect_not_ambiguous} =
               PullMergeConfirmation.record_ambiguous_effect(
                 result.operation,
                 c.now,
                 retry_at,
                 remote
               )
    end

    changed_timestamp =
      put_in(initial_observation.issue.remote_updated_at, DateTime.add(c.now, 1, :second))

    assert {:ok, yielded} =
             PullMergeConfirmation.record_ambiguous_effect(
               result.operation,
               c.now,
               retry_at,
               changed_timestamp
             )

    assert yielded.failure_disposition == :conflict
    assert yielded.failure_detail == "ambiguous_external_effect"
    assert yielded.external_effect_marker == result.marker
  end

  test "target with a regressed pull timestamp cannot confirm and records ambiguity", c do
    assert_target_timestamp_ambiguity(c, :pull)
  end

  test "target with a regressed issue timestamp cannot confirm and records ambiguity", c do
    assert_target_timestamp_ambiguity(c, :issue)
  end

  test "remote-already-equal and incompatible concurrent remote edits create no effect", c do
    {operation, intent} = marked(c)
    {version, target, observation} = local_edit(c, intent)

    already_equal =
      observation
      |> put_in([:issue, :confirmed_snapshot], target)
      |> update_in([:pull, :confirmed_snapshot], &Map.merge(&1, Map.take(target, ~w(title body))))

    assert {:error, _} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               already_equal,
               version,
               target
             )

    concurrent_issue = Map.put(observation.issue.confirmed_snapshot, "title", "Remote retitle")

    concurrent =
      observation
      |> put_in([:issue, :confirmed_snapshot], concurrent_issue)
      |> put_in([:pull, :confirmed_snapshot, "title"], "Remote retitle")

    assert {:error, _} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               concurrent,
               version,
               target
             )

    assert Repo.aggregate(PullMetadataIntent, :count) == 0

    assert Repo.get!(MirrorOperation, operation.id).external_effect_marker ==
             operation.external_effect_marker
  end

  defp local_edit(c, intent, opts \\ []) do
    title = Keyword.get(opts, :title, "Locally retitled")
    body = Keyword.get(opts, :body, "locally edited body")
    version = c.expected.local_version + 1

    c.issue
    |> Changeset.change(title: title, body: body, sync_version: version)
    |> Repo.update!()

    remote_issue =
      c.issue_mapping.confirmed_snapshot
      |> Map.put("state", "closed")
      |> Map.put("state_reason", "completed")

    target = remote_issue |> Map.put("title", title) |> Map.put("body", body)
    {version, target, observation(c, intent, remote_issue)}
  end

  defp assert_target_timestamp_ambiguity(c, regressed_kind) do
    {operation, intent} = marked(c)
    {version, target, initial_observation} = local_edit(c, intent)
    expected_at = DateTime.add(c.now, 2, :second)
    initial_observation = put_observation_times(initial_observation, expected_at, expected_at)

    assert {:ok, result} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               initial_observation,
               version,
               target
             )

    target_observation = applied_observation(initial_observation, target, expected_at)
    regressed_at = DateTime.add(expected_at, -1, :second)

    target_observation =
      case regressed_kind do
        :pull -> put_in(target_observation.pull.remote_updated_at, regressed_at)
        :issue -> put_in(target_observation.issue.remote_updated_at, regressed_at)
      end

    assert {:ok, {:error, :merge_metadata_unconfirmed}} =
             Repo.transaction(fn ->
               PullMergeConfirmation.authorize(
                 result.operation,
                 c.now,
                 intent,
                 target_observation
               )
             end)

    assert {:ok, yielded} =
             PullMergeConfirmation.record_ambiguous_effect(
               result.operation,
               c.now,
               DateTime.add(c.now, 3, :second),
               target_observation
             )

    assert yielded.failure_disposition == :conflict
    assert yielded.failure_detail == "ambiguous_external_effect"
    assert yielded.external_effect_marker == result.marker
  end

  defp observation(c, intent, issue_snapshot) do
    fields =
      Map.merge(c.expected.fields, %{
        "state" => "closed",
        "state_reason" => "completed",
        "base_sha" => intent.merge_oid
      })

    %{
      remote_base_oid: intent.merge_oid,
      pull: %{
        github_object_id: 902,
        github_node_id: "PR_902",
        github_number: 7,
        provider_base_oid: intent.expected_base_oid,
        provider_identity: c.expected.provider_identity,
        confirmed_snapshot: fields,
        confirmed_merge_state: %{
          "merged_at" => DateTime.to_iso8601(c.now),
          "merge_commit_sha" => intent.merge_oid
        },
        remote_updated_at: c.now
      },
      issue: %{
        github_object_id: 901,
        github_node_id: "I_901",
        github_number: 7,
        provider_state_reason: "completed",
        confirmed_snapshot: issue_snapshot,
        remote_updated_at: c.now
      }
    }
  end

  defp applied_observation(observation, issue, observed_at) do
    observation
    |> put_in([:issue, :confirmed_snapshot], issue)
    |> put_in([:issue, :remote_updated_at], observed_at)
    |> update_in([:pull, :confirmed_snapshot], &Map.merge(&1, Map.take(issue, ~w(title body))))
    |> put_in([:pull, :remote_updated_at], observed_at)
  end

  defp put_observation_times(observation, pull_time, issue_time) do
    observation
    |> put_in([:pull, :remote_updated_at], pull_time)
    |> put_in([:issue, :remote_updated_at], issue_time)
  end

  defp merge_locally(c, intent, target) do
    ForgeIssues.Issue
    |> Repo.get!(c.issue.id)
    |> Changeset.change(
      state: :closed,
      state_reason: :completed,
      title: target["title"],
      body: target["body"],
      sync_version: c.expected.local_version + 2
    )
    |> Repo.update!()

    c.pull
    |> Changeset.change(
      base_sha: intent.merge_oid,
      merged_at: c.now,
      merge_commit_sha: intent.merge_oid
    )
    |> Repo.update!()

    {:ok, actual} = ForgePulls.sync_projection(c.binding.repository_id, :pull, c.pull.id)
    actual
  end

  defp marked(c) do
    assert {:ok, %{reserved: intent}} =
             Multi.new()
             |> PullMergeBoundary.append_prepare(
               :reserved,
               c.operation,
               c.now,
               c.expected,
               ForgePulls.append_prepare_coordinated_merge(Multi.new(), :intent, c.request)
             )
             |> Repo.transaction()

    intent =
      intent
      |> Changeset.change(
        state: :merge_written,
        merge_tree_oid: String.duplicate("c", 40),
        merge_oid: String.duplicate("d", 40)
      )
      |> Repo.update!()

    assert {:ok, operation} =
             PullMergeBoundary.mark(c.operation, c.now, nil, %{
               "phase" => "remote_cas_pending",
               "merge_operation_id" => intent.id,
               "merge_tree_oid" => intent.merge_tree_oid,
               "merge_oid" => intent.merge_oid
             })

    {operation, intent}
  end

  defp tamper_intent(intent, attrs) do
    Repo.update_all(from(i in PullMetadataIntent, where: i.id == ^intent.id), set: attrs)
  end

  defp replace_marker(operation, marker) do
    operation
    |> Changeset.change(external_effect_marker: marker)
    |> Repo.update!()
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
