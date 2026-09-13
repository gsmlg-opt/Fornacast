defmodule ForgeMirrors.PullMergeAssigneeProofTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.{Changeset, Multi}
  alias ForgeAccounts.GitHubIdentity

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    PullEligibility,
    PullMergeAssigneeProof,
    PullMergeBoundary,
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

    installation =
      Repo.get_by!(GitHubAppInstallation,
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
    now = DateTime.utc_now(:second)
    next_id = (Repo.aggregate(GitHubIdentity, :max, :github_user_id) || 0) + 1

    identities =
      for id <- next_id..(next_id + 1) do
        {:ok, identity} =
          ForgeAccounts.observe_github_identity(%{id: id, login: "merge-user-#{id}"}, now)

        identity
      end

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: binding.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Merge",
        body: "original",
        author_user_id: actor.id
      })

    Enum.each(identities, fn identity ->
      Repo.insert!(%ForgeIssues.IssueAssignee{
        issue_id: issue.id,
        github_identity_id: identity.id
      })
    end)

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

    provider_identity = %{
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
        provider_identity: provider_identity,
        state: :confirmed
      })
      |> Repo.insert!()

    {:ok, pull_fingerprint} = ForgeMirrors.resource_fingerprint(local.fields)
    pull_mapping |> Changeset.change(confirmed_fingerprint: pull_fingerprint) |> Repo.update!()

    assignee_ids = Enum.map(identities, & &1.github_user_id)

    issue_snapshot =
      Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
        "label_github_ids" => [],
        "assignee_github_ids" => assignee_ids
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

    queued =
      operation_fixture(organization, %{
        repository_mirror_id: binding.id,
        kind: "merge.pull",
        cursor: %{"issue_id" => issue.id, "pull_id" => pull.id},
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("merge-assignee-proof", now, 60, 100, ["merge.pull"])

    operation = Enum.find(claimed, &(&1.id == queued.id))

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
      provider_identity: provider_identity,
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

    {operation, merge_intent} = marked(operation, now, expected, request)
    version = local.local_version + 1

    issue
    |> Changeset.change(title: "Locally retitled", sync_version: version)
    |> Repo.update!()

    remote_issue =
      Map.merge(issue_mapping.confirmed_snapshot, %{
        "state" => "closed",
        "state_reason" => "completed"
      })

    target_issue = Map.put(remote_issue, "title", "Locally retitled")
    observation = observation(now, expected, merge_intent, remote_issue)

    {:ok, effect} =
      PullMergeMetadataEffects.mark(
        operation,
        now,
        merge_intent,
        observation,
        version,
        target_issue
      )

    %{
      effect: effect,
      identities: identities,
      installation: installation,
      intent: effect.intent,
      issue: issue,
      now: now
    }
  end

  test "seeds one immutable target per claim and yields without changing merge evidence", c do
    assert {:ok, context} = PullMergeAssigneeProof.context(c.effect.operation, c.now)
    [first, second] = c.identities
    before_intent = Repo.get!(PullMetadataIntent, c.intent.id)

    assert context.target == %{
             identity_id: first.id,
             github_user_id: first.github_user_id,
             expected_node_id: nil
           }

    assert {:ok, %{operation: yielded, identity: seeded}} =
             PullMergeAssigneeProof.seed(
               c.effect.operation,
               c.now,
               expected(context),
               profile(first),
               &yield_effect/2
             )

    assert seeded.github_node_id == profile(first).node_id
    assert yielded.external_effect_marker == c.effect.marker
    assert yielded.state == :effect_pending
    assert yielded.lease_owner == nil
    assert yielded.lease_expires_at == nil
    assert Repo.get!(GitHubIdentity, second.id).github_node_id == nil
    assert Repo.get!(PullMetadataIntent, c.intent.id) == before_intent

    retry_at = DateTime.add(c.now, 1, :second)

    assert {:ok, claimed} =
             ForgeMirrors.claim_operations("next-merge-assignee", retry_at, 60, 100, [
               "merge.pull"
             ])

    reclaimed = Enum.find(claimed, &(&1.id == yielded.id))
    assert {:ok, next} = PullMergeAssigneeProof.context(reclaimed, retry_at)
    assert next.target.identity_id == second.id
  end

  test "rejects substituted numeric identity and malformed authenticated profiles", c do
    assert {:ok, context} = PullMergeAssigneeProof.context(c.effect.operation, c.now)
    [first, second] = c.identities

    for invalid <- [
          profile(second),
          Map.put(profile(first), :node_id, ""),
          Map.put(profile(first), :extra, true)
        ] do
      assert {:error, :invalid_identity_observation} =
               PullMergeAssigneeProof.seed(
                 c.effect.operation,
                 c.now,
                 expected(context),
                 invalid,
                 &yield_effect/2
               )

      assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil
    end
  end

  test "rejects node collisions and stale marker or target claims", c do
    assert {:ok, context} = PullMergeAssigneeProof.context(c.effect.operation, c.now)
    [first, second] = c.identities
    {:ok, _} = ForgeAccounts.observe_github_identity(profile(second), c.now)

    assert {:error, :identity_conflict} =
             PullMergeAssigneeProof.seed(
               c.effect.operation,
               c.now,
               expected(context),
               %{profile(first) | node_id: profile(second).node_id},
               &yield_effect/2
             )

    stale_marker =
      put_in(expected(context).marker["metadata_intent_hash"], String.duplicate("0", 64))

    for stale <- [
          stale_marker,
          put_in(expected(context), [:target, :identity_id], second.id)
        ] do
      assert {:error, :stale_relationship_proof} =
               PullMergeAssigneeProof.seed(
                 c.effect.operation,
                 c.now,
                 stale,
                 profile(first),
                 &yield_effect/2
               )
    end

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil

    assert Repo.get!(MirrorOperation, c.effect.operation.id).external_effect_marker ==
             c.effect.marker
  end

  test "missing immutable target identity is unavailable after local membership changes", c do
    [first, _] = c.identities

    Repo.delete_all(
      from(a in ForgeIssues.IssueAssignee, where: a.github_identity_id == ^first.id)
    )

    Repo.delete!(first)

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [sync_version: c.intent.local_version + 1]
    )

    assert {:error, :assignee_identity_unavailable} =
             PullMergeAssigneeProof.context(c.effect.operation, c.now)
  end

  test "lost lease rolls back identity evidence and retains the merge marker", c do
    assert {:ok, context} = PullMergeAssigneeProof.context(c.effect.operation, c.now)
    first = hd(c.identities)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.effect.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, -1, :second)]
    )

    assert {:error, :lost_lease} =
             PullMergeAssigneeProof.seed(
               c.effect.operation,
               c.now,
               expected(context),
               profile(first),
               &yield_effect/2
             )

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil

    assert Repo.get!(MirrorOperation, c.effect.operation.id).external_effect_marker ==
             c.effect.marker
  end

  test "lost installation permission cannot seed identity evidence", c do
    assert {:ok, context} = PullMergeAssigneeProof.context(c.effect.operation, c.now)
    first = hd(c.identities)

    c.installation
    |> Changeset.change(permissions: %{"metadata" => "read"})
    |> Repo.update!()

    assert {:error, :permission_missing} =
             PullMergeAssigneeProof.seed(
               c.effect.operation,
               c.now,
               expected(context),
               profile(first),
               &yield_effect/2
             )

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil

    assert Repo.get!(MirrorOperation, c.effect.operation.id).external_effect_marker ==
             c.effect.marker
  end

  test "yield failure rolls back the identity observation", c do
    assert {:ok, context} = PullMergeAssigneeProof.context(c.effect.operation, c.now)
    first = hd(c.identities)

    assert {:error, :lost_lease} =
             PullMergeAssigneeProof.seed(
               c.effect.operation,
               c.now,
               expected(context),
               profile(first),
               fn _, _ -> {:error, :lost_lease} end
             )

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil

    assert Repo.get!(MirrorOperation, c.effect.operation.id).external_effect_marker ==
             c.effect.marker
  end

  test "a fabricated yield result cannot commit identity evidence", c do
    assert {:ok, context} = PullMergeAssigneeProof.context(c.effect.operation, c.now)
    first = hd(c.identities)
    before_intent = Repo.get!(PullMetadataIntent, c.intent.id)

    fake_yield = fn operation, _now ->
      {:ok,
       %{
         operation
         | state: :effect_pending,
           next_attempt_at: c.now,
           lease_owner: nil,
           lease_expires_at: nil
       }}
    end

    assert {:error, :invalid_transition} =
             PullMergeAssigneeProof.seed(
               c.effect.operation,
               c.now,
               expected(context),
               profile(first),
               fake_yield
             )

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil
    persisted = Repo.get!(MirrorOperation, c.effect.operation.id)
    assert persisted.lease_owner == "merge-assignee-proof"
    assert persisted.external_effect_marker == c.effect.marker
    assert Repo.get!(PullMetadataIntent, c.intent.id) == before_intent
  end

  defp expected(context), do: Map.take(context, [:marker, :target])

  defp profile(identity),
    do: %{
      id: identity.github_user_id,
      login: identity.login,
      node_id: "U_merge_#{identity.github_user_id}",
      name: nil,
      avatar_url: nil,
      html_url: nil
    }

  defp yield_effect(operation, now) do
    operation
    |> Changeset.change(
      state: :effect_pending,
      next_attempt_at: DateTime.truncate(now, :second),
      lease_owner: nil,
      lease_expires_at: nil,
      failure_class: nil,
      failure_disposition: nil,
      failure_detail: nil,
      updated_at: now
    )
    |> Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
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

    assert {:ok, operation} =
             PullMergeBoundary.mark(operation, now, nil, %{
               "phase" => "remote_cas_pending",
               "merge_operation_id" => intent.id,
               "merge_tree_oid" => intent.merge_tree_oid,
               "merge_oid" => intent.merge_oid
             })

    {operation, intent}
  end

  defp observation(now, expected, intent, issue_snapshot) do
    fields =
      Map.merge(expected.fields, %{
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
        confirmed_snapshot: issue_snapshot,
        remote_updated_at: now
      }
    }
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
