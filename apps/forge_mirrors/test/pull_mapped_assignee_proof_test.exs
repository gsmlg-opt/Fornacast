defmodule ForgeMirrors.PullMappedAssigneeProofTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeAccounts.GitHubIdentity
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState, MirrorRefState, PullEligibility}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(org)
    actor = organization_owner_fixture(org)
    now = DateTime.utc_now(:second)
    next_id = (Repo.aggregate(GitHubIdentity, :max, :github_user_id) || 0) + 1

    identities =
      for id <- next_id..(next_id + 1) do
        {:ok, identity} =
          ForgeAccounts.observe_github_identity(%{id: id, login: "mapped-user-#{id}"}, now)

        identity
      end

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Base",
        author_user_id: actor.id
      })

    for identity <- identities,
        do:
          Repo.insert!(%ForgeIssues.IssueAssignee{
            issue_id: issue.id,
            github_identity_id: identity.id
          })

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: base.repository_id,
        head_repository_id: base.repository_id,
        head_ref: "refs/heads/topic",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })

    for {ref, oid} <- [{pull.head_ref, pull.head_sha}, {pull.base_ref, pull.base_sha}],
        do:
          Repo.insert!(%MirrorRefState{
            repository_mirror_id: base.id,
            ref_name: ref,
            ref_kind: :branch,
            state: :confirmed,
            confirmed_oid: oid,
            last_local_oid: oid,
            last_remote_oid: oid,
            last_confirmed_at: now
          })

    {:ok, local} = ForgePulls.sync_projection(base.repository_id, :pull, pull.id)
    repo_identity = %{"id" => base.github_repository_id, "node_id" => base.github_node_id}

    provider = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => repo_identity,
      "head_repository" => repo_identity
    }

    merge = %{"merged_at" => nil, "merge_commit_sha" => nil}

    mapping =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: base.id,
        resource_kind: :pull,
        local_resource_type: "ForgePulls.PullRequest",
        local_resource_id: pull.id,
        github_object_id: 902,
        github_node_id: "PR_902",
        github_number: 7,
        confirmed_local_version: 1,
        confirmed_snapshot: local.fields,
        confirmed_remote_updated_at: now,
        confirmed_merge_state: merge,
        provider_identity: provider,
        state: :confirmed
      })

    baseline =
      Map.merge(Map.take(local.fields, ~w(title body state state_reason)), %{
        "label_github_ids" => [],
        "assignee_github_ids" => []
      })

    Repo.insert!(%MirrorResourceState{
      repository_mirror_id: base.id,
      resource_kind: :issue,
      local_resource_type: "ForgeIssues.Issue",
      local_resource_id: issue.id,
      github_object_id: 901,
      github_node_id: "I_901",
      github_number: 7,
      confirmed_local_version: 1,
      confirmed_snapshot: baseline,
      state: :confirmed
    })

    queued =
      operation_fixture(org, %{
        repository_mirror_id: base.id,
        kind: "sync.pull",
        cursor: %{"trigger" => "local", "issue_id" => issue.id, "sync_version" => 1},
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("mapped-assignee", now, 120, 100, ["sync.pull"])

    operation = Enum.find(claimed, &(&1.id == queued.id))
    {:ok, sync} = ForgeMirrors.mapped_pull_pair_context(operation)

    {:ok, proof} =
      PullEligibility.check(
        base.id,
        base.repository_id,
        Map.take(pull, [:head_ref, :head_sha, :base_ref, :base_sha])
      )

    {:ok, hash} = ForgeMirrors.resource_fingerprint(local.fields)

    marker = %{
      "action" => "update_remote_pull_issue",
      "github_object_id" => 902,
      "github_node_id" => "PR_902",
      "github_number" => 7,
      "resource_state_lock_version" => mapping.lock_version,
      "provider_identity" => provider,
      "pull_eligibility_proof" => proof |> JSON.encode!() |> JSON.decode!(),
      "expected_merge_state" => merge,
      "expected_local_version" => 1,
      "expected_local_fingerprint" => hash,
      "proposed_fingerprint" => hash,
      "expected_local_draft" => false,
      "expected_remote_draft" => false,
      "proposed_draft" => false,
      "expected_remote_updated_at" => DateTime.to_iso8601(now),
      "expected_remote_issue_updated_at" => DateTime.to_iso8601(now)
    }

    target = Map.put(baseline, "assignee_github_ids", Enum.map(identities, & &1.github_user_id))

    payload = %{
      "v" => 1,
      "expected_local_issue" => target,
      "expected_remote_issue" => baseline,
      "target_issue" => target
    }

    {:ok, effect} =
      ForgeMirrors.mark_mapped_pull_effect(operation, now, sync.pair, marker, payload)

    %{effect: effect, identities: identities, now: now, issue: issue, org: org}
  end

  test "seeds exactly one desired identity and yields unchanged mapped evidence", c do
    checkpoint = %{"keep" => 3}

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.effect.operation.id),
      set: [checkpoint: checkpoint]
    )

    assert {:ok, context} = ForgeMirrors.mapped_pull_assignee_node_context(c.effect.operation)
    [first, second] = c.identities

    assert context.target == %{
             identity_id: first.id,
             github_user_id: first.github_user_id,
             expected_node_id: nil
           }

    assert {:ok, %{operation: yielded, identity: seeded}} =
             ForgeMirrors.seed_mapped_pull_assignee_node(
               c.effect.operation,
               c.now,
               expected(context),
               profile(first)
             )

    assert seeded.github_node_id == profile(first).node_id
    assert yielded.external_effect_marker == c.effect.marker
    assert yielded.checkpoint == checkpoint
    assert yielded.state == :effect_pending
    assert yielded.lease_owner == nil
    assert Repo.get!(GitHubIdentity, second.id).github_node_id == nil

    {:ok, claimed} =
      ForgeMirrors.claim_operations("next-mapped-assignee", c.now, 120, 100, ["sync.pull"])

    operation = Enum.find(claimed, &(&1.id == yielded.id))
    assert {:ok, next} = ForgeMirrors.mapped_pull_assignee_node_context(operation)
    assert next.target.identity_id == second.id
  end

  test "rejects substituted numeric identity and malformed authenticated profile", c do
    {:ok, context} = ForgeMirrors.mapped_pull_assignee_node_context(c.effect.operation)
    [first, second] = c.identities

    for invalid <- [
          profile(second),
          Map.put(profile(first), :node_id, ""),
          Map.put(profile(first), :extra, true)
        ] do
      assert {:error, :invalid_identity_observation} =
               ForgeMirrors.seed_mapped_pull_assignee_node(
                 c.effect.operation,
                 c.now,
                 expected(context),
                 invalid
               )

      assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil
    end
  end

  test "node collision and stale target cannot change retained identity", c do
    {:ok, context} = ForgeMirrors.mapped_pull_assignee_node_context(c.effect.operation)
    [first, second] = c.identities
    {:ok, _} = ForgeAccounts.observe_github_identity(profile(second), c.now)

    assert {:error, :identity_conflict} =
             ForgeMirrors.seed_mapped_pull_assignee_node(
               c.effect.operation,
               c.now,
               expected(context),
               %{profile(first) | node_id: profile(second).node_id}
             )

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil
    {:ok, _} = ForgeAccounts.observe_github_identity(profile(first), c.now)

    assert {:error, :stale_relationship_proof} =
             ForgeMirrors.seed_mapped_pull_assignee_node(
               c.effect.operation,
               c.now,
               expected(context),
               profile(first)
             )

    assert {:ok, %{target: nil}} =
             ForgeMirrors.mapped_pull_assignee_node_context(c.effect.operation)
  end

  test "missing original identity is unavailable even if newer local membership removed it", c do
    [first, _] = c.identities

    Repo.delete_all(
      from(a in ForgeIssues.IssueAssignee, where: a.github_identity_id == ^first.id)
    )

    Repo.delete!(first)

    Repo.update_all(from(i in ForgeIssues.Issue, where: i.id == ^c.issue.id),
      set: [sync_version: 2]
    )

    assert {:error, :assignee_identity_unavailable} =
             ForgeMirrors.mapped_pull_assignee_node_context(c.effect.operation)
  end

  test "expired lease leaves identity and effect marker unchanged", c do
    {:ok, context} = ForgeMirrors.mapped_pull_assignee_node_context(c.effect.operation)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.effect.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, -1)]
    )

    assert {:error, :lost_lease} =
             ForgeMirrors.seed_mapped_pull_assignee_node(
               c.effect.operation,
               c.now,
               expected(context),
               profile(hd(c.identities))
             )

    assert Repo.get!(GitHubIdentity, hd(c.identities).id).github_node_id == nil

    assert Repo.get!(MirrorOperation, c.effect.operation.id).external_effect_marker ==
             c.effect.marker
  end

  test "changed original installation cannot seed mapped identity evidence", c do
    id = Repo.aggregate(ForgeMirrors.GitHubAppInstallation, :max, :github_installation_id) + 1

    {:ok, _} =
      ForgeMirrors.observe_github_app_installation(%{
        github_installation_id: id,
        github_account_id: c.org.github_account_id,
        github_account_login: c.org.github_account_login,
        account_type: :organization,
        repository_selection: :all,
        permissions: %{"metadata" => "read"},
        state: :active,
        last_verified_at: c.now
      })

    Repo.update_all(from(o in ForgeMirrors.OrganizationMirror, where: o.id == ^c.org.id),
      set: [github_installation_id: id]
    )

    assert {:error, :ineligible_pull} =
             ForgeMirrors.mapped_pull_assignee_node_context(c.effect.operation)
  end

  defp expected(context), do: Map.take(context, [:marker, :target])

  defp profile(identity),
    do: %{
      id: identity.github_user_id,
      login: identity.login,
      node_id: "U_mapped_#{identity.github_user_id}",
      name: nil,
      avatar_url: nil,
      html_url: nil
    }
end
