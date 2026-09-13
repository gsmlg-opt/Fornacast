defmodule ForgeMirrors.PullMergeLocalLabelEffectsTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  import Ecto.Query
  alias Ecto.{Changeset, Multi}

  alias ForgeMirrors.{
    MirrorConflict,
    MirrorRefState,
    MirrorResourceState,
    PullEligibility,
    PullMergeBoundary,
    PullMergeLocalLabelEffects,
    PullMergeMetadataEffects
  }

  alias Fornacast.{AuditEvent, Repo}

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
        "issues" => "write",
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

    {:ok, claimed} =
      ForgeMirrors.claim_operations("merge-local-label", now, 60, 100, ["merge.pull"])

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

  test "mark retains the exact parent merge marker and immutable local label evidence", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)
    parent_marker = operation.external_effect_marker

    assert {:ok, result} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               candidate
             )

    assert result.operation.state == :effect_pending

    assert result.operation.external_effect_marker == %{
             "phase" => "metadata_label_pending",
             "parent_marker" => parent_marker,
             "label_effect" => %{
               "v" => 1,
               "action" => "create_remote_label",
               "resource_kind" => "label",
               "local_label_id" => candidate.local_resource_id,
               "expected_local_version" => candidate.local_version,
               "expected_local_fingerprint" => fingerprint(candidate.fields),
               "expected_remote_absent" => true,
               "label_name" => candidate.fields["name"],
               "proposed_fingerprint" => fingerprint(candidate.fields),
               "proposed_snapshot" => candidate.fields,
               "observed_pull_updated_at" => DateTime.to_iso8601(c.now),
               "observed_issue_updated_at" => DateTime.to_iso8601(c.now)
             }
           }
  end

  test "marked recovery retains the original label while accepting a newer local version", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation(c, intent),
               candidate
             )

    update_label(candidate, %{color: "123456", sync_version: candidate.local_version + 1})

    assert {:ok, context} = PullMergeLocalLabelEffects.context(marked, c.now)
    assert context.candidate == candidate
    assert context.current_candidate.local_version == candidate.local_version + 1
    assert context.current_candidate.fields["color"] == "123456"
  end

  test "unmarked exact adoption confirms a mapping and releases only the merge lease", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    parent_marker = operation.external_effect_marker
    observation = observation(c, intent)

    assert {:ok, result} =
             PullMergeLocalLabelEffects.confirm(
               operation,
               c.now,
               intent,
               observation,
               candidate,
               confirmation(candidate, 880, "L_880"),
               observe_label(candidate, :exact)
             )

    assert result.operation.state == :effect_pending
    assert result.operation.external_effect_marker == parent_marker
    assert is_nil(result.operation.lease_owner)
    assert is_nil(result.operation.lease_expires_at)
    assert result.operation.checkpoint == operation.checkpoint

    assert %MirrorResourceState{
             local_resource_id: id,
             github_object_id: 880,
             github_node_id: "L_880",
             confirmed_local_version: version,
             confirmed_snapshot: fields,
             state: :confirmed
           } = result.resource_state

    assert id == candidate.local_resource_id
    assert version == candidate.local_version
    assert fields == candidate.fields
  end

  test "marked confirmation normalizes a newer observation and restores the exact parent marker",
       c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    parent_marker = operation.external_effect_marker
    observation = observation(c, intent)

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               candidate
             )

    update_label(candidate, %{color: "123456", sync_version: candidate.local_version + 1})

    assert {:ok, result} =
             PullMergeLocalLabelEffects.confirm(
               marked,
               c.now,
               intent,
               observation,
               candidate,
               confirmation(candidate, 880, "L_880"),
               observe_label(candidate, :minimum)
             )

    assert result.operation.external_effect_marker == parent_marker
    assert result.resource == candidate
    assert result.resource_state.confirmed_local_version == candidate.local_version
    assert result.resource_state.confirmed_snapshot == candidate.fields
    assert is_nil(result.operation.lease_owner)
  end

  test "marked recovery confirms the recorded label after its membership is removed", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    parent_marker = operation.external_effect_marker
    observation = observation(c, intent)

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               candidate
             )

    Repo.delete_all(
      from membership in ForgeIssues.IssueLabel,
        where:
          membership.issue_id == ^c.issue.id and
            membership.label_id == ^candidate.local_resource_id
    )

    assert {:ok, result} =
             PullMergeLocalLabelEffects.confirm(
               marked,
               c.now,
               intent,
               observation,
               candidate,
               confirmation(candidate, 880, "L_880"),
               observe_label(candidate, :minimum)
             )

    assert result.operation.external_effect_marker == parent_marker
    assert result.resource_state.local_resource_id == candidate.local_resource_id
    assert result.resource_state.github_object_id == 880
  end

  test "a newly assigned lower unmapped label does not displace marked recovery", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    lower = repository_label(c.binding.repository_id, "lower")
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)

    assert lower.local_resource_id < candidate.local_resource_id

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               candidate
             )

    Repo.insert!(%ForgeIssues.IssueLabel{
      issue_id: c.issue.id,
      label_id: lower.local_resource_id
    })

    assert {:ok, result} =
             PullMergeLocalLabelEffects.confirm(
               marked,
               c.now,
               intent,
               observation,
               candidate,
               confirmation(candidate, 880, "L_880"),
               observe_label(candidate, :minimum)
             )

    assert result.resource_state.local_resource_id == candidate.local_resource_id
    assert result.operation.external_effect_marker == operation.external_effect_marker
  end

  test "a marked ambiguous create becomes a visible merge conflict without a mapping", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               candidate
             )

    assert {:ok, result} =
             PullMergeLocalLabelEffects.conflict(
               marked,
               c.now,
               intent,
               observation,
               candidate,
               :ambiguous_label_create,
               %{}
             )

    assert %MirrorConflict{
             resource_kind: "pull_merge",
             resource_identity: identity,
             conflict_kind: "ambiguous_label_create",
             state: :open
           } = result.conflict

    assert identity == to_string(intent.id)
    assert result.operation.external_effect_marker == marked.external_effect_marker
    assert result.operation.failure_disposition == :conflict
    assert is_nil(result.operation.lease_owner)

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: candidate.local_resource_id
           )
  end

  test "an unmarked namespace mismatch is visible and retains the merge marker", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)

    assert {:ok, result} =
             PullMergeLocalLabelEffects.conflict(
               operation,
               c.now,
               intent,
               observation,
               candidate,
               :label_namespace_collision,
               %{
                 "id" => 880,
                 "node_id" => "L_880",
                 "name" => "merge-local",
                 "color" => "000000",
                 "description" => nil
               }
             )

    assert result.conflict.conflict_kind == "label_namespace_collision"
    assert result.operation.external_effect_marker == operation.external_effect_marker
    assert is_nil(result.operation.lease_owner)
  end

  test "only the lowest assigned unmapped label may be marked", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    _first = assigned_label(c, "first")
    second = assigned_label(c, "second")

    assert {:error, :label_not_assigned} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation(c, intent),
               second
             )
  end

  test "mark rejects a substituted candidate repository identity", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    substituted = %{candidate | repository_id: c.head.repository_id}

    assert {:error, :label_metadata_conflict} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation(c, intent),
               substituted
             )

    assert Repo.get!(ForgeMirrors.MirrorOperation, operation.id).external_effect_marker ==
             operation.external_effect_marker
  end

  test "confirmation rolls back when the callback downgrades label-write permission", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)
    installation_id = c.organization.github_installation_id

    callback = fn multi ->
      Multi.run(multi, :resource, fn _, _ ->
        installation =
          Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
            github_installation_id: installation_id
          )

        installation
        |> Changeset.change(
          permissions: %{
            "contents" => "write",
            "pull_requests" => "read",
            "issues" => "read",
            "metadata" => "read"
          }
        )
        |> Repo.update!()

        {:ok, candidate}
      end)
    end

    assert {:error, :permission_missing} =
             PullMergeLocalLabelEffects.confirm(
               operation,
               c.now,
               intent,
               observation,
               candidate,
               confirmation(candidate, 880, "L_880"),
               callback
             )

    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: installation_id
      )

    assert installation.permissions["pull_requests"] == "write"

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: candidate.local_resource_id
           )
  end

  test "confirmation rejects callback fabrication and rolls its writes back", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)

    callback = fn multi ->
      Multi.run(multi, :resource, fn _, _ ->
        {:ok, %{candidate | local_resource_id: candidate.local_resource_id + 1}}
      end)
    end

    assert {:error, :invalid_projection} =
             PullMergeLocalLabelEffects.confirm(
               operation,
               c.now,
               intent,
               observation,
               candidate,
               confirmation(candidate, 880, "L_880"),
               callback
             )

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: candidate.local_resource_id
           )
  end

  test "metadata parent is retained by the label marker and restored after confirmation", c do
    {operation, intent} = marked(c)

    c.issue
    |> Changeset.change(
      title: "local edit",
      body: "local body",
      sync_version: c.expected.local_version + 1
    )
    |> Repo.update!()

    remote_issue =
      c.issue_mapping.confirmed_snapshot
      |> Map.put("state", "closed")
      |> Map.put("state_reason", "completed")

    target = remote_issue |> Map.put("title", "local edit") |> Map.put("body", "local body")
    initial_observation = put_in(observation(c, intent).issue.confirmed_snapshot, remote_issue)
    {:ok, local} = ForgePulls.sync_projection(c.binding.repository_id, :pull, c.pull.id)

    assert {:ok, metadata} =
             PullMergeMetadataEffects.mark(
               operation,
               c.now,
               intent,
               initial_observation,
               local.local_version,
               target
             )

    parent_marker = metadata.operation.external_effect_marker
    candidate = assigned_label(c, "metadata-local")
    bump_issue(c.issue.id)

    applied_observation =
      initial_observation
      |> put_in([:issue, :confirmed_snapshot], target)
      |> update_in(
        [:pull, :confirmed_snapshot],
        &Map.merge(&1, Map.take(target, ~w(title body)))
      )

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               metadata.operation,
               c.now,
               intent,
               applied_observation,
               candidate
             )

    assert marked.external_effect_marker["parent_marker"] == parent_marker

    assert {:ok, result} =
             PullMergeLocalLabelEffects.confirm(
               marked,
               c.now,
               intent,
               applied_observation,
               candidate,
               confirmation(candidate, 880, "L_880"),
               observe_label(candidate, :minimum)
             )

    assert result.operation.external_effect_marker == parent_marker
    assert result.operation.state == :effect_pending
    assert is_nil(result.operation.lease_owner)
  end

  test "revoked label-write permission prevents marking", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")

    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: c.organization.github_installation_id
    )
    |> Changeset.change(
      permissions: %{
        "contents" => "write",
        "pull_requests" => "read",
        "issues" => "read",
        "metadata" => "read"
      }
    )
    |> Repo.update!()

    assert {:error, :permission_missing} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation(c, intent),
               candidate
             )
  end

  test "preflight rejects a downgraded pull-request write capability", c do
    {operation, _intent} = marked(c)

    Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
      github_installation_id: c.organization.github_installation_id
    )
    |> Changeset.change(
      permissions: %{
        "contents" => "write",
        "pull_requests" => "read",
        "issues" => "read",
        "metadata" => "read"
      }
    )
    |> Repo.update!()

    assert {:error, :permission_missing} =
             ForgeMirrors.pull_merge_local_label_preflight(operation, c.now)
  end

  test "marked remote identity collision is recordable as a durable conflict", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               candidate
             )

    other = repository_label(c.binding.repository_id, "other")
    {:ok, hash} = ForgeMirrors.resource_fingerprint(other.fields)

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: c.binding.id,
      resource_kind: :label,
      local_resource_type: "ForgeIssues.Label",
      local_resource_id: other.local_resource_id,
      github_object_id: 880,
      github_node_id: "L_880",
      confirmed_local_version: other.local_version,
      confirmed_snapshot: other.fields,
      confirmed_fingerprint: hash,
      state: :confirmed
    })
    |> Repo.insert!()

    remote = %{
      "id" => 880,
      "node_id" => "L_880",
      "name" => "merge-local",
      "color" => "abcdef",
      "description" => "remote"
    }

    assert {:error, :identity_conflict} =
             PullMergeLocalLabelEffects.confirm(
               marked,
               c.now,
               intent,
               observation,
               candidate,
               confirmation(candidate, 880, "L_880"),
               fn _ -> flunk("identity collision must precede callback") end
             )

    assert {:ok, result} =
             PullMergeLocalLabelEffects.conflict(
               marked,
               c.now,
               intent,
               observation,
               candidate,
               :label_identity_conflict,
               remote
             )

    assert result.conflict.conflict_kind == "label_identity_conflict"
    assert result.operation.external_effect_marker == marked.external_effect_marker
    assert result.operation.failure_disposition == :conflict
    assert is_nil(result.operation.lease_owner)
  end

  test "marked local deletion retains immutable evidence for a metadata conflict", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               candidate
             )

    Repo.delete_all(
      from membership in ForgeIssues.IssueLabel,
        where: membership.label_id == ^candidate.local_resource_id
    )

    ForgeIssues.Label |> Repo.get!(candidate.local_resource_id) |> Repo.delete!()

    assert {:ok, context} = PullMergeLocalLabelEffects.context(marked, c.now)
    assert context.candidate == candidate
    assert is_nil(context.current_candidate)
    assert context.label_conflict == :label_metadata_conflict

    assert {:ok, result} =
             PullMergeLocalLabelEffects.conflict(
               marked,
               c.now,
               intent,
               observation,
               candidate,
               :label_metadata_conflict,
               %{}
             )

    assert result.conflict.conflict_kind == "label_metadata_conflict"
    assert result.operation.external_effect_marker == marked.external_effect_marker
    assert is_nil(result.operation.lease_owner)
  end

  test "organization-wide label node collision rolls back confirmation", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    other = repository_label(c.head.repository_id, "other")
    {:ok, hash} = ForgeMirrors.resource_fingerprint(other.fields)

    %MirrorResourceState{}
    |> MirrorResourceState.persistence_changeset(%{
      repository_mirror_id: c.head.id,
      resource_kind: :label,
      local_resource_type: "ForgeIssues.Label",
      local_resource_id: other.local_resource_id,
      github_object_id: 990,
      github_node_id: "L_880",
      confirmed_local_version: other.local_version,
      confirmed_snapshot: other.fields,
      confirmed_fingerprint: hash,
      state: :confirmed
    })
    |> Repo.insert!()

    assert {:error, :identity_conflict} =
             PullMergeLocalLabelEffects.confirm(
               operation,
               c.now,
               intent,
               observation(c, intent),
               candidate,
               confirmation(candidate, 880, "L_880"),
               fn _ -> flunk("identity collision must be rejected before the callback") end
             )

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             local_resource_id: candidate.local_resource_id
           )
  end

  test "a substituted caller marker cannot authorize marked recovery", c do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "merge-local")
    observation = observation(c, intent)

    assert {:ok, %{operation: marked}} =
             PullMergeLocalLabelEffects.mark(
               operation,
               c.now,
               intent,
               observation,
               candidate
             )

    substituted = %{marked | external_effect_marker: operation.external_effect_marker}

    assert {:error, :invalid_label_effect} =
             PullMergeLocalLabelEffects.context(substituted, c.now)
  end

  test "an owner atomically resolves a merge conflict for external recheck and wakes its operation",
       c do
    {conflict, operation, intent} = conflicted(c)
    actor = organization_owner_fixture(c.organization)
    checkpoint = operation.checkpoint
    marker = operation.external_effect_marker
    cursor = operation.cursor

    metadata = %{
      "request_id" => "recheck-#{conflict.id}",
      "operation_id" => "recheck-operation-#{conflict.id}",
      "ip_address" => "127.0.0.1",
      "user_agent" => "merge-conflict-test"
    }

    assert {:ok, before_view} =
             ForgeMirrors.organization_settings(actor, c.organization.organization_id)

    assert [summary] = Enum.filter(before_view.conflicts, &(&1.id == conflict.id))
    assert summary.resource_kind == "pull_merge"
    assert summary.lock_version == conflict.lock_version

    assert {:ok, result} =
             ForgeMirrors.recheck_pull_merge_conflict(
               actor,
               c.organization.organization_id,
               conflict,
               "external_recheck",
               c.now,
               metadata
             )

    assert result.conflict.state == :resolved
    assert result.conflict.resolution == %{"action" => "external_recheck", "v" => 1}
    assert result.conflict.resolved_by_user_id == actor.id
    assert result.operation.id == operation.id
    assert result.operation.state == :effect_pending
    assert result.operation.next_attempt_at == c.now
    assert result.operation.failure_class == nil
    assert result.operation.failure_disposition == nil
    assert result.operation.failure_detail == nil
    assert result.operation.lease_owner == nil
    assert result.operation.lease_expires_at == nil
    assert result.operation.checkpoint == checkpoint
    assert result.operation.external_effect_marker == marker
    assert result.operation.cursor == cursor

    assert %AuditEvent{
             action: "github.pull_merge_conflict.external_recheck",
             actor_user_id: actor_id,
             target_type: "mirror_conflict",
             target_id: target_id,
             request_id: request_id,
             operation_id: operation_id
           } =
             audit =
             Repo.get_by!(AuditEvent,
               action: "github.pull_merge_conflict.external_recheck",
               target_id: to_string(conflict.id)
             )

    assert actor_id == actor.id
    assert target_id == to_string(conflict.id)
    assert request_id == metadata["request_id"]
    assert operation_id == "pull-merge-conflict-recheck:#{conflict.id}"
    assert audit.metadata["operation_id"] == metadata["operation_id"]

    persisted_intent = Repo.get!(ForgePulls.MergeOperation, intent.id)
    assert persisted_intent.state == :merge_written
    assert persisted_intent.merge_oid == intent.merge_oid

    assert {:ok, after_view} =
             ForgeMirrors.organization_settings(actor, c.organization.organization_id)

    refute Enum.any?(after_view.conflicts, &(&1.id == conflict.id))

    assert {:ok, replay} =
             ForgeMirrors.recheck_pull_merge_conflict(
               actor,
               c.organization.organization_id,
               conflict,
               "external_recheck",
               DateTime.add(c.now, 1, :second),
               metadata
             )

    assert replay.conflict.id == result.conflict.id
    assert replay.conflict.resolved_at == result.conflict.resolved_at

    assert Repo.aggregate(
             from(event in AuditEvent,
               where:
                 event.action == "github.pull_merge_conflict.external_recheck" and
                   event.target_id == ^to_string(conflict.id)
             ),
             :count
           ) == 1
  end

  test "external recheck rejects stale conflict capabilities and actively leased operations", c do
    {conflict, operation, _intent} = conflicted(c)
    actor = organization_owner_fixture(c.organization)

    assert {:error, :stale} =
             ForgeMirrors.recheck_pull_merge_conflict(
               actor,
               c.organization.organization_id,
               %{conflict | lock_version: conflict.lock_version + 1},
               "external_recheck",
               c.now,
               %{}
             )

    leased =
      operation
      |> Changeset.change(
        lease_owner: "racing-worker",
        lease_expires_at: DateTime.add(c.now, 60, :second),
        lock_version: operation.lock_version + 1
      )
      |> Repo.update!()

    assert leased.lease_owner == "racing-worker"

    assert {:error, :busy} =
             ForgeMirrors.recheck_pull_merge_conflict(
               actor,
               c.organization.organization_id,
               conflict,
               "external_recheck",
               c.now,
               %{}
             )

    assert Repo.get!(MirrorConflict, conflict.id).state == :open
  end

  test "external recheck atomically clears an expired operation lease", c do
    {conflict, operation, _intent} = conflicted(c)
    actor = organization_owner_fixture(c.organization)

    operation
    |> Changeset.change(
      lease_owner: "expired-worker",
      lease_expires_at: DateTime.add(c.now, -1, :second),
      lock_version: operation.lock_version + 1
    )
    |> Repo.update!()

    assert {:ok, result} =
             ForgeMirrors.recheck_pull_merge_conflict(
               actor,
               c.organization.organization_id,
               conflict,
               "external_recheck",
               c.now,
               %{}
             )

    assert result.conflict.state == :resolved
    assert result.operation.lease_owner == nil
    assert result.operation.lease_expires_at == nil
    assert result.operation.next_attempt_at == c.now
  end

  test "external recheck rejects unauthorized actors, arbitrary actions, and non-merge conflicts",
       c do
    {conflict, _operation, _intent} = conflicted(c)
    outsider = ForgeAccounts.User |> Repo.get!(user_fixture())

    assert {:error, :forbidden} =
             ForgeMirrors.recheck_pull_merge_conflict(
               outsider,
               c.organization.organization_id,
               conflict,
               "external_recheck",
               c.now,
               %{}
             )

    assert {:error, :invalid_transition} =
             ForgeMirrors.recheck_pull_merge_conflict(
               organization_owner_fixture(c.organization),
               c.organization.organization_id + 1,
               conflict,
               "external_recheck",
               c.now,
               %{}
             )

    assert {:error, :invalid_argument} =
             ForgeMirrors.recheck_pull_merge_conflict(
               organization_owner_fixture(c.organization),
               c.organization.organization_id,
               conflict,
               "keep_fornacast",
               c.now,
               %{}
             )

    {:ok, other} =
      ForgeMirrors.record_conflict(%{
        organization_mirror_id: c.organization.id,
        repository_mirror_id: c.binding.id,
        resource_kind: "pull",
        resource_identity: "pull:#{c.pull.id}",
        conflict_kind: "concurrent_edit",
        baseline_snapshot: %{},
        local_snapshot: %{},
        remote_snapshot: %{}
      })

    assert {:error, :invalid_transition} =
             ForgeMirrors.recheck_pull_merge_conflict(
               organization_owner_fixture(c.organization),
               c.organization.organization_id,
               other,
               "external_recheck",
               c.now,
               %{}
             )
  end

  defp assigned_label(c, name) do
    projection = repository_label(c.binding.repository_id, name)

    Repo.insert!(%ForgeIssues.IssueLabel{
      issue_id: c.issue.id,
      label_id: projection.local_resource_id
    })

    projection
  end

  defp conflicted(c) do
    {operation, intent} = marked(c)
    merge_locally(c, intent)
    candidate = assigned_label(c, "conflicted-label")

    assert {:ok, result} =
             PullMergeLocalLabelEffects.conflict(
               operation,
               c.now,
               intent,
               observation(c, intent),
               candidate,
               :label_namespace_collision,
               %{}
             )

    {result.conflict, result.operation, intent}
  end

  defp repository_label(repository_id, name) do
    label =
      %ForgeIssues.Label{repository_id: repository_id}
      |> ForgeIssues.Label.changeset(%{
        name: name,
        normalized_name: name,
        color: "abcdef",
        description: "remote"
      })
      |> Repo.insert!()

    {:ok, projection} = ForgeIssues.label_sync_projection(repository_id, label.id)
    projection
  end

  defp update_label(candidate, attrs) do
    ForgeIssues.Label
    |> Repo.get!(candidate.local_resource_id)
    |> Changeset.change(attrs)
    |> Repo.update!()
  end

  defp confirmation(candidate, github_id, node_id),
    do: %{
      github_object_id: github_id,
      github_node_id: node_id,
      confirmed_snapshot: candidate.fields
    }

  defp observe_label(candidate, mode) do
    request = %{
      repository_id: candidate.repository_id,
      local_resource_id: candidate.local_resource_id,
      expected_fields: candidate.fields
    }

    request =
      if mode == :minimum,
        do: Map.put(request, :minimum_local_version, candidate.local_version),
        else: Map.put(request, :expected_local_version, candidate.local_version)

    fn multi -> ForgeIssues.append_sync_label_observe(multi, :resource, request) end
  end

  defp observation(c, intent) do
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
        confirmed_snapshot:
          Map.merge(Map.take(fields, ~w(title body state state_reason)), %{
            "label_github_ids" => [],
            "assignee_github_ids" => []
          }),
        remote_updated_at: c.now
      }
    }
  end

  defp merge_locally(c, intent, title \\ "Merge") do
    c.issue
    |> Changeset.change(
      state: :closed,
      state_reason: :completed,
      title: title,
      sync_version: c.expected.local_version + 1
    )
    |> Repo.update!()

    c.pull
    |> Changeset.change(
      base_sha: intent.merge_oid,
      merged_at: c.now,
      merge_commit_sha: intent.merge_oid
    )
    |> Repo.update!()
  end

  defp bump_issue(issue_id) do
    issue = Repo.get!(ForgeIssues.Issue, issue_id)
    issue |> Changeset.change(sync_version: issue.sync_version + 1) |> Repo.update!()
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

  defp fingerprint(fields) do
    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(fields)
    fingerprint
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
