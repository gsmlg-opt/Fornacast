defmodule ForgeMirrors.PullRelationshipProofBoundaryTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.{DomainOutboxEvent, Repo}
  alias ForgeAccounts.GitHubIdentity
  alias ForgeMirrors.{GitHubAppInstallation, MirrorOperation, MirrorRefState, OrganizationMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(organization)
    head = repository_mirror_fixture(organization)
    actor = organization_owner_fixture(organization)
    now = DateTime.utc_now(:second)

    assignees =
      for index <- 1..2 do
        github_user_id = System.unique_integer([:positive, :monotonic])

        {:ok, identity} =
          ForgeAccounts.observe_github_identity(
            %{id: github_user_id, login: "relationship-user-#{index}-#{github_user_id}"},
            now
          )

        identity
      end

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: base.repository_id,
        number: 7,
        kind: :pull_request,
        title: "Local pull",
        body: "Body",
        author_user_id: actor.id
      })

    Enum.each(assignees, fn identity ->
      Repo.insert!(%ForgeIssues.IssueAssignee{
        issue_id: issue.id,
        github_identity_id: identity.id
      })
    end)

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: base.repository_id,
        head_repository_id: head.repository_id,
        base_ref: "refs/heads/main",
        head_ref: "refs/heads/feature",
        base_sha: String.duplicate("a", 40),
        head_sha: String.duplicate("b", 40),
        draft: false
      })

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

    {:ok, {:materialized, [queued]}} = ForgeMirrors.materialize_outbox_event(event)

    {:ok, claimed} =
      ForgeMirrors.claim_operations("relationship-proof", now, 120, 100, ["sync.pull"])

    operation = Enum.find(claimed, &(&1.id == queued.id))
    {:ok, unmarked} = ForgeMirrors.outbound_pull_creation_context(operation)

    expected =
      Map.take(unmarked, [
        :pull_id,
        :issue_id,
        :expected_local_version,
        :expected_fields,
        :expected_issue_snapshot,
        :expected_merge_state,
        :provider_repositories,
        :pull_eligibility_proof
      ])

    {:ok, marked} = ForgeMirrors.mark_outbound_pull_creation(operation, now, expected)

    %{
      assignees: Enum.sort_by(assignees, & &1.github_user_id),
      marked: marked,
      now: now
    }
  end

  test "seeds one authenticated numeric identity and yields the unchanged creation marker", c do
    checkpoint = %{
      "pull_creation_recovery" => %{"page" => 2, "candidate" => nil, "complete" => false},
      "unrelated" => %{"keep" => true}
    }

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.marked.operation.id),
      set: [checkpoint: checkpoint]
    )

    operation = %{c.marked.operation | checkpoint: checkpoint}

    assert {:ok, context} =
             ForgeMirrors.outbound_pull_assignee_node_context(operation)

    [first, second] = c.assignees

    assert context.github_installation_id > 0
    assert context.marker == c.marked.marker

    assert context.target == %{
             identity_id: first.id,
             github_user_id: first.github_user_id,
             expected_node_id: nil
           }

    expected = %{marker: context.marker, target: context.target}

    profile = %ForgeGitHub.User{
      id: first.github_user_id,
      node_id: "U_#{first.github_user_id}",
      login: first.login
    }

    assert {:ok, %{operation: yielded, identity: seeded}} =
             ForgeMirrors.seed_outbound_pull_assignee_node(
               operation,
               c.now,
               expected,
               Map.from_struct(profile)
             )

    assert seeded.id == first.id
    assert seeded.github_node_id == profile.node_id
    assert yielded.state == :effect_pending
    assert yielded.external_effect_marker == c.marked.marker
    assert yielded.checkpoint == checkpoint
    assert yielded.lease_owner == nil
    assert yielded.lease_expires_at == nil

    {:ok, claimed} =
      ForgeMirrors.claim_operations("relationship-proof-next", c.now, 120, 100, ["sync.pull"])

    [reclaimed] = Enum.filter(claimed, &(&1.id == yielded.id))

    assert {:ok, next_context} =
             ForgeMirrors.outbound_pull_assignee_node_context(reclaimed)

    assert next_context.target.github_user_id == second.github_user_id
    assert next_context.marker == c.marked.marker
  end

  test "rejects a different numeric identity or malformed node without changing progress", c do
    assert {:ok, context} =
             ForgeMirrors.outbound_pull_assignee_node_context(c.marked.operation)

    [first, second] = c.assignees
    expected = %{marker: context.marker, target: context.target}

    for profile <- [
          user_profile(second, "U_#{second.github_user_id}"),
          user_profile(first, ""),
          Map.put(user_profile(first, "U_#{first.github_user_id}"), :unexpected, true)
        ] do
      assert {:error, :invalid_identity_observation} =
               ForgeMirrors.seed_outbound_pull_assignee_node(
                 c.marked.operation,
                 c.now,
                 expected,
                 profile
               )

      assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil

      assert Repo.get!(MirrorOperation, c.marked.operation.id).external_effect_marker ==
               c.marked.marker
    end
  end

  test "duplicate or concurrently substituted nodes roll back the profile observation", c do
    assert {:ok, context} =
             ForgeMirrors.outbound_pull_assignee_node_context(c.marked.operation)

    [first, _second] = c.assignees
    expected = %{marker: context.marker, target: context.target}

    duplicate_id = System.unique_integer([:positive, :monotonic])

    {:ok, _duplicate} =
      ForgeAccounts.observe_github_identity(
        %{id: duplicate_id, node_id: "U_taken", login: "taken-#{duplicate_id}"},
        c.now
      )

    assert {:error, :identity_conflict} =
             ForgeMirrors.seed_outbound_pull_assignee_node(
               c.marked.operation,
               c.now,
               expected,
               user_profile(first, "U_taken")
             )

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil

    {:ok, concurrently_seeded} =
      ForgeAccounts.observe_github_identity(
        user_profile(first, "U_concurrent"),
        c.now
      )

    assert concurrently_seeded.github_node_id == "U_concurrent"

    assert {:error, :stale_relationship_proof} =
             ForgeMirrors.seed_outbound_pull_assignee_node(
               c.marked.operation,
               c.now,
               expected,
               user_profile(first, "U_different")
             )

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == "U_concurrent"

    assert Repo.get!(MirrorOperation, c.marked.operation.id).external_effect_marker ==
             c.marked.marker
  end

  test "expired lease rolls back identity progress and preserves the unresolved marker", c do
    assert {:ok, context} =
             ForgeMirrors.outbound_pull_assignee_node_context(c.marked.operation)

    [first, _second] = c.assignees
    expected = %{marker: context.marker, target: context.target}

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.marked.operation.id),
      set: [lease_expires_at: DateTime.add(c.now, -1)]
    )

    assert {:error, :lost_lease} =
             ForgeMirrors.seed_outbound_pull_assignee_node(
               c.marked.operation,
               c.now,
               expected,
               user_profile(first, "U_#{first.github_user_id}")
             )

    assert Repo.get!(GitHubIdentity, first.id).github_node_id == nil

    assert Repo.get!(MirrorOperation, c.marked.operation.id).external_effect_marker ==
             c.marked.marker
  end

  test "replacement installation cannot authorize identity progress for the old intent", c do
    replacement_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, %GitHubAppInstallation{}} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: replacement_id,
               github_account_id: System.unique_integer([:positive, :monotonic]),
               github_account_login: "replacement-installation",
               account_type: :organization,
               repository_selection: :all,
               permissions: %{"metadata" => "read"},
               state: :active,
               last_verified_at: c.now
             })

    Repo.update_all(
      from(o in OrganizationMirror,
        where: o.id == ^c.marked.operation.organization_mirror_id
      ),
      set: [github_installation_id: replacement_id],
      inc: [lock_version: 1]
    )

    assert {:error, :ineligible_pull} =
             ForgeMirrors.outbound_pull_assignee_node_context(c.marked.operation)

    assert Enum.all?(c.assignees, &is_nil(Repo.get!(GitHubIdentity, &1.id).github_node_id))

    assert Repo.get!(MirrorOperation, c.marked.operation.id).external_effect_marker ==
             c.marked.marker
  end

  test "an identity removed after marking is unavailable rather than recreated from a guess", c do
    [first, _second] = c.assignees

    Repo.delete_all(
      from(a in ForgeIssues.IssueAssignee,
        where: a.github_identity_id == ^first.id
      )
    )

    Repo.delete!(first)

    assert {:error, :assignee_identity_unavailable} =
             ForgeMirrors.outbound_pull_assignee_node_context(c.marked.operation)

    assert Repo.get(GitHubIdentity, first.id) == nil

    assert Repo.get!(MirrorOperation, c.marked.operation.id).external_effect_marker ==
             c.marked.marker
  end

  defp user_profile(identity, node_id) do
    %{
      id: identity.github_user_id,
      node_id: node_id,
      login: identity.login,
      name: nil,
      avatar_url: nil,
      html_url: nil
    }
  end
end
