defmodule ForgeMirrors.PullMergeRemoteLabelObservationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Ecto.{Changeset, Multi}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    PullEligibility,
    PullMergeBoundary,
    PullMergeMetadataEffects,
    PullMergeRemoteLabelObservation
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

    {:ok, claimed} =
      ForgeMirrors.claim_operations("merge-remote-label", now, 60, 100, ["merge.pull"])

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

    %{operation: marked, reserved: intent} = marked(operation, now, expected, request)

    candidate = %{
      github_object_id: 700,
      node_id: "LA_700",
      name: "remote-label",
      color: "abcdef",
      description: "Observed during merge"
    }

    %{
      organization: organization,
      binding: binding,
      head: head,
      issue: issue,
      pull: pull,
      pull_mapping: Repo.get!(MirrorResourceState, pull_mapping.id),
      issue_mapping: issue_mapping,
      now: now,
      operation: marked,
      intent: intent,
      expected: expected,
      candidate: candidate,
      observation:
        observation(expected, intent, now, issue_snapshot, [candidate.github_object_id])
    }
  end

  test "remote-CAS observation imports one label and releases only the merge lease", c do
    before = durable_state(c)

    assert {:ok, result} = import_label(c)
    assert result.operation.id == c.operation.id
    assert result.operation.state == :effect_pending
    assert result.operation.lease_owner == nil
    assert result.operation.lease_expires_at == nil
    assert result.operation.next_attempt_at == c.now
    assert result.operation.lock_version == c.operation.lock_version + 1
    assert result.operation.external_effect_marker == c.operation.external_effect_marker
    assert result.operation.effect_marked_at == c.operation.effect_marked_at
    assert result.operation.checkpoint == c.operation.checkpoint

    assert result.resource_state.github_object_id == c.candidate.github_object_id
    assert result.resource_state.github_node_id == c.candidate.node_id
    assert result.resource_state.local_resource_id == result.resource.local_resource_id

    assert durable_state(c) == before
  end

  test "metadata observation imports its unknown preimage label without consuming the effect",
       c do
    c = metadata_pending(c, :preimage)
    before = durable_state(c)

    assert {:ok, result} = import_label(c)
    assert result.operation.state == :effect_pending
    assert result.operation.external_effect_marker == c.operation.external_effect_marker
    assert result.operation.effect_marked_at == c.operation.effect_marked_at
    assert result.operation.checkpoint == c.operation.checkpoint
    assert durable_state(c) == before
  end

  test "metadata observation may import the exact applied target at newer timestamps", c do
    c = metadata_pending(c, :target)
    assert {:ok, result} = import_label(c)
    assert result.operation.state == :effect_pending
    assert result.operation.external_effect_marker == c.operation.external_effect_marker
  end

  test "imports the lowest missing label and leaves later candidates for later claims", c do
    second = %{
      github_object_id: 701,
      node_id: "LA_701",
      name: "second-remote-label",
      color: "123456",
      description: nil
    }

    observation =
      put_in(
        c.observation,
        [:issue, :confirmed_snapshot, "label_github_ids"],
        [c.candidate.github_object_id, second.github_object_id]
      )

    assert {:ok, first} = import_label(%{c | observation: observation})

    refute Repo.get_by(MirrorResourceState,
             repository_mirror_id: c.binding.id,
             resource_kind: :label,
             github_object_id: second.github_object_id
           )

    {:ok, claimed} =
      ForgeMirrors.claim_operations("merge-remote-label-second", c.now, 60, 100, ["merge.pull"])

    operation = Enum.find(claimed, &(&1.id == first.operation.id))

    assert {:ok, second_result} =
             import_label(%{
               c
               | operation: operation,
                 observation: observation,
                 candidate: second
             })

    assert second_result.resource_state.github_object_id == second.github_object_id

    assert Repo.aggregate(
             from(mapping in MirrorResourceState,
               where:
                 mapping.repository_mirror_id == ^c.binding.id and
                   mapping.resource_kind == :label
             ),
             :count
           ) == 2
  end

  test "rejects a candidate that is absent or not the lowest missing label", c do
    second = %{c.candidate | github_object_id: 701, node_id: "LA_701", name: "later"}

    for candidate <- [second, %{c.candidate | github_object_id: 999, node_id: "LA_999"}] do
      assert {:error, :stale_relationship_proof} = import_label(%{c | candidate: candidate})
    end

    refute Repo.get_by(ForgeIssues.Label,
             repository_id: c.binding.repository_id,
             name: c.candidate.name
           )
  end

  test "rejects malformed candidates and substituted authenticated merge observations", c do
    invalid_candidates = [
      Map.put(c.candidate, :extra, true),
      %{c.candidate | node_id: ""},
      %{c.candidate | color: "not-a-color"},
      %{c.candidate | description: String.duplicate("x", 101)}
    ]

    for candidate <- invalid_candidates do
      assert {:error, :invalid_label_observation} = import_label(%{c | candidate: candidate})
    end

    substituted = put_in(c.observation, [:pull, :github_node_id], "PR_substituted")

    assert {:error, :merge_metadata_unconfirmed} =
             import_label(%{c | observation: substituted})
  end

  test "fabricated or over-broad domain projections roll back every canonical write", c do
    fake = fn multi ->
      Multi.put(multi, :resource, %{
        repository_id: c.binding.repository_id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: 999_999_999,
        local_version: 1,
        fields: candidate_fields(c.candidate)
      })
    end

    assert {:error, :invalid_projection} = import_label(c, fake)

    extra = fn multi ->
      multi
      |> append_label(c, c.candidate, :resource)
      |> append_label(
        c,
        %{c.candidate | github_object_id: 701, node_id: "LA_701", name: "extra"},
        :extra
      )
    end

    assert {:error, :invalid_projection} = import_label(c, extra)

    refute Repo.exists?(
             from label in ForgeIssues.Label,
               where: label.repository_id == ^c.binding.repository_id
           )

    assert Repo.get!(MirrorOperation, c.operation.id) == c.operation
  end

  test "namespace and organization node collisions are rejected before import", c do
    existing =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: c.binding.repository_id,
        name: c.candidate.name,
        normalized_name: c.candidate.name,
        color: "000000"
      })

    assert {:error, :namespace_collision} = import_label(c)
    assert Repo.get!(ForgeIssues.Label, existing.id) == existing
    Repo.delete!(existing)

    other = repository_mirror_fixture(c.organization)

    collision =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: other.id,
        resource_kind: :label,
        github_object_id: 702,
        github_node_id: c.candidate.node_id,
        state: :confirmed
      })

    assert {:error, :identity_conflict} = import_label(c)
    assert Repo.get!(MirrorResourceState, collision.id) == collision

    refute Repo.exists?(
             from label in ForgeIssues.Label,
               where: label.repository_id == ^c.binding.repository_id
           )
  end

  test "an exact local namespace occupant is adopted without rewriting its metadata", c do
    existing =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: c.binding.repository_id,
        name: c.candidate.name,
        normalized_name: c.candidate.name,
        color: c.candidate.color,
        description: c.candidate.description
      })

    before = Repo.get!(ForgeIssues.Label, existing.id)
    assert {:ok, result} = import_label(c)
    assert result.resource.local_resource_id == existing.id
    assert result.resource_state.local_resource_id == existing.id
    assert Repo.get!(ForgeIssues.Label, existing.id) == before
  end

  test "a node collision introduced inside the callback rolls back label and collision", c do
    other = repository_mirror_fixture(c.organization)

    callback = fn multi ->
      multi
      |> append_label(c, c.candidate, :resource)
      |> Multi.run(:collision, fn repo, _ ->
        repo.insert(%MirrorResourceState{
          repository_mirror_id: other.id,
          resource_kind: :label,
          github_object_id: 702,
          github_node_id: c.candidate.node_id,
          state: :confirmed
        })
      end)
    end

    assert {:error, :identity_conflict} = import_label(c, callback)

    refute Repo.exists?(
             from label in ForgeIssues.Label,
               where: label.repository_id == ^c.binding.repository_id
           )

    refute Repo.exists?(
             from mapping in MirrorResourceState, where: mapping.repository_mirror_id == ^other.id
           )
  end

  test "lease, capability, intent, paired baseline, local projection and ref drift roll back import",
       c do
    installation =
      Repo.get_by!(ForgeMirrors.GitHubAppInstallation,
        github_installation_id: c.organization.github_installation_id
      )

    base_ref =
      Repo.get_by!(MirrorRefState,
        repository_mirror_id: c.binding.id,
        ref_name: c.pull.base_ref
      )

    mutations = [
      fn repo ->
        repo.update_all(from(op in MirrorOperation, where: op.id == ^c.operation.id),
          set: [lease_expires_at: DateTime.add(c.now, -1, :second)]
        )
      end,
      fn repo ->
        repo.update_all(
          from(row in ForgeMirrors.GitHubAppInstallation, where: row.id == ^installation.id),
          set: [permissions: %{"metadata" => "read"}]
        )
      end,
      fn repo ->
        repo.update_all(
          from(intent in ForgePulls.MergeOperation, where: intent.id == ^c.intent.id),
          set: [merge_oid: String.duplicate("e", 40)]
        )
      end,
      fn repo ->
        repo.update_all(
          from(mapping in MirrorResourceState, where: mapping.id == ^c.issue_mapping.id),
          inc: [lock_version: 1]
        )
      end,
      fn repo ->
        repo.update_all(from(issue in ForgeIssues.Issue, where: issue.id == ^c.issue.id),
          set: [title: "callback drift"],
          inc: [sync_version: 1]
        )
      end,
      fn repo ->
        repo.update_all(from(ref in MirrorRefState, where: ref.id == ^base_ref.id),
          inc: [lock_version: 1]
        )
      end
    ]

    for mutation <- mutations do
      callback = fn multi ->
        multi
        |> append_label(c, c.candidate, :resource)
        |> Multi.run(:drift, fn repo, _ ->
          mutation.(repo)
          {:ok, :drifted}
        end)
      end

      assert {:error, _reason} = import_label(c, callback)

      refute Repo.exists?(
               from label in ForgeIssues.Label,
                 where: label.repository_id == ^c.binding.repository_id
             )

      assert Repo.get!(MirrorOperation, c.operation.id) == c.operation
      assert Repo.get!(MirrorResourceState, c.pull_mapping.id) == c.pull_mapping
      assert Repo.get!(MirrorResourceState, c.issue_mapping.id) == c.issue_mapping
    end
  end

  test "metadata third state, ABA timestamp and regressed target cannot import or clear evidence",
       c do
    c = metadata_pending(c, :preimage)
    marker = c.operation.external_effect_marker

    third =
      c.observation
      |> put_in([:issue, :confirmed_snapshot, "body"], "third state")
      |> put_in([:pull, :confirmed_snapshot, "body"], "third state")

    aba =
      c.observation
      |> put_in([:pull, :remote_updated_at], DateTime.add(c.now, 1, :second))
      |> put_in([:issue, :remote_updated_at], DateTime.add(c.now, 1, :second))

    target = metadata_pending_observation(c, :target)
    regressed = put_in(target, [:issue, :remote_updated_at], DateTime.add(c.now, -1, :second))

    for {observation, reason} <- [
          {third, :ambiguous_external_effect},
          {aba, :ambiguous_external_effect},
          {regressed, :merge_metadata_unconfirmed}
        ] do
      assert {:error, ^reason} = import_label(%{c | observation: observation})
      assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == marker

      refute Repo.exists?(
               from label in ForgeIssues.Label,
                 where: label.repository_id == ^c.binding.repository_id
             )
    end
  end

  test "ordinary sync operations cannot enter the merge import boundary", c do
    ordinary = %{c.operation | kind: "sync.pull"}
    callback = fn _ -> flunk("ordinary operation callback") end

    assert {:error, :invalid_argument} =
             PullMergeRemoteLabelObservation.import(
               ordinary,
               c.now,
               c.intent,
               c.observation,
               c.candidate,
               callback
             )
  end

  defp import_label(c, callback \\ nil) do
    callback =
      callback ||
        fn multi ->
          append_label(multi, c, c.candidate, :resource)
        end

    PullMergeRemoteLabelObservation.import(
      c.operation,
      c.now,
      c.intent,
      c.observation,
      c.candidate,
      callback
    )
  end

  defp durable_state(c) do
    %{
      pull_mapping: Repo.get!(MirrorResourceState, c.pull_mapping.id),
      issue_mapping: Repo.get!(MirrorResourceState, c.issue_mapping.id),
      intent: Repo.get!(ForgePulls.MergeOperation, c.intent.id),
      metadata_intents: Repo.all(ForgeMirrors.PullMetadataIntent)
    }
  end

  defp metadata_pending(c, observation_mode) do
    version = c.expected.local_version + 1

    c.issue
    |> Changeset.change(title: "Local title", sync_version: version)
    |> Repo.update!()

    target = Map.put(c.observation.issue.confirmed_snapshot, "title", "Local title")

    assert {:ok, marked} =
             PullMergeMetadataEffects.mark(
               c.operation,
               c.now,
               c.intent,
               c.observation,
               version,
               target
             )

    c = %{c | operation: marked.operation}
    %{c | observation: metadata_pending_observation(c, observation_mode)}
  end

  defp metadata_pending_observation(c, :preimage), do: c.observation

  defp metadata_pending_observation(c, :target) do
    observed_at = DateTime.add(c.now, 1, :second)

    target =
      Repo.get!(
        ForgeMirrors.PullMetadataIntent,
        c.operation.external_effect_marker["metadata_intent_id"]
      ).payload["target_issue"]

    c.observation
    |> put_in([:issue, :confirmed_snapshot], target)
    |> put_in([:issue, :remote_updated_at], observed_at)
    |> update_in([:pull, :confirmed_snapshot], &Map.merge(&1, Map.take(target, ~w(title body))))
    |> put_in([:pull, :remote_updated_at], observed_at)
  end

  defp append_label(multi, c, candidate, key) do
    ForgeIssues.append_sync_label_import(multi, key, %{
      repository_id: c.binding.repository_id,
      fields: candidate_fields(candidate),
      provenance: %{origin: :github, correlation_id: "merge-#{c.operation.id}"}
    })
  end

  defp candidate_fields(candidate) do
    %{
      "name" => candidate.name,
      "color" => candidate.color,
      "description" => candidate.description
    }
  end

  defp marked(operation, now, expected, request) do
    assert {:ok, %{reserved: intent}} =
             Multi.new()
             |> PullMergeBoundary.append_prepare(
               :reserved,
               operation,
               now,
               expected,
               ForgePulls.append_prepare_coordinated_merge(Multi.new(), :intent, request)
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

    assert {:ok, marked} =
             PullMergeBoundary.mark(operation, now, nil, %{
               "phase" => "remote_cas_pending",
               "merge_operation_id" => intent.id,
               "merge_tree_oid" => intent.merge_tree_oid,
               "merge_oid" => intent.merge_oid
             })

    %{operation: marked, reserved: intent}
  end

  defp observation(expected, intent, now, baseline, labels) do
    issue =
      baseline
      |> Map.merge(%{"state" => "closed", "state_reason" => "completed"})
      |> Map.put("label_github_ids", Enum.sort(labels))

    fields =
      expected.fields
      |> Map.merge(%{
        "state" => "closed",
        "state_reason" => "completed",
        "base_sha" => intent.merge_oid
      })
      |> Map.merge(Map.take(issue, ~w(title body)))

    %{
      remote_base_oid: intent.merge_oid,
      pull: %{
        github_object_id: 902,
        github_node_id: "PR_902",
        github_number: 7,
        provider_base_oid: intent.expected_base_oid,
        provider_identity: expected.provider_identity,
        confirmed_snapshot: fields,
        confirmed_merge_state: %{
          "merged_at" => DateTime.to_iso8601(now),
          "merge_commit_sha" => intent.merge_oid
        },
        remote_updated_at: now
      },
      issue: %{
        github_object_id: 901,
        github_node_id: "I_901",
        github_number: 7,
        provider_state_reason: "completed",
        confirmed_snapshot: issue,
        remote_updated_at: now
      }
    }
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
