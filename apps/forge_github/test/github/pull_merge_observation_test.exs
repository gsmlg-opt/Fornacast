defmodule ForgeGitHub.PullMergeObservationTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.Repo
  alias ForgeGitHub.PullMergeObservation

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture()
    owner = Repo.get!(ForgeAccounts.User, organization.organization_id)
    actor = organization_owner_fixture(organization)

    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{
        name: "observation",
        slug: "observation",
        visibility: :private
      })

    binding = repository_mirror_fixture(organization, %{repository_id: repository.id})

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: repository.id,
        number: 7,
        kind: :pull_request,
        title: "Local newer title",
        author_user_id: actor.id
      })

    b = String.duplicate("a", 40)
    h = String.duplicate("b", 40)
    m = String.duplicate("c", 40)

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: repository.id,
        head_repository_id: repository.id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: h,
        base_sha: b
      })

    label =
      Repo.insert!(
        ForgeIssues.Label.changeset(%ForgeIssues.Label{repository_id: repository.id}, %{
          name: "known",
          normalized_name: "known",
          color: "112233"
        })
      )

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: issue.id, label_id: label.id})

    Repo.insert!(
      ForgeMirrors.MirrorResourceState.persistence_changeset(
        %ForgeMirrors.MirrorResourceState{},
        %{
          repository_mirror_id: binding.id,
          resource_kind: :label,
          local_resource_type: "ForgeIssues.Label",
          local_resource_id: label.id,
          github_object_id: 800,
          github_node_id: "L_800",
          confirmed_snapshot: %{},
          state: :confirmed
        }
      )
    )

    identity =
      Repo.insert!(
        ForgeAccounts.GitHubIdentity.observed_changeset(%ForgeAccounts.GitHubIdentity{}, %{
          github_user_id: 801,
          github_node_id: "U_801",
          login: "known"
        })
      )

    Repo.insert!(%ForgeIssues.IssueAssignee{issue_id: issue.id, github_identity_id: identity.id})

    remote_repo = %{
      "id" => binding.github_repository_id,
      "node_id" => binding.github_node_id,
      "full_name" => "org/repo"
    }

    provider_identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => Map.take(remote_repo, ["id", "node_id"]),
      "head_repository" => Map.take(remote_repo, ["id", "node_id"])
    }

    sync = %{
      repository_id: repository.id,
      repository_mirror_id: binding.id,
      expected: %{pull_id: pull.id, provider_identity: provider_identity},
      provider_pull_identity: %{"id" => 902, "node_id" => "PR_902"},
      intent: %{
        merge_oid: m,
        expected_base_oid: b,
        expected_head_oid: h,
        base_ref: pull.base_ref,
        head_ref: pull.head_ref
      }
    }

    raw_issue = %{
      "id" => 901,
      "node_id" => "I_901",
      "number" => 7,
      "title" => "Remote title",
      "body" => nil,
      "state" => "closed",
      "state_reason" => "completed",
      "labels" => [%{"id" => 800, "node_id" => "L_800", "name" => "known"}],
      "assignees" => [%{"id" => 801, "node_id" => "U_801", "login" => "known"}],
      "user" => %{"id" => 801},
      "created_at" => "2026-09-01T00:00:00Z",
      "updated_at" => "2026-09-08T00:00:00Z"
    }

    raw_pull =
      Map.merge(Map.take(raw_issue, ~w(number title body state created_at updated_at)), %{
        "id" => 902,
        "node_id" => "PR_902",
        "draft" => false,
        "merged" => true,
        "merged_at" => "2026-09-08T00:00:00Z",
        "merge_commit_sha" => m,
        "mergeable" => nil,
        "rebaseable" => nil,
        "mergeable_state" => "unknown",
        "head" => %{"ref" => "feature", "sha" => h, "repo" => remote_repo},
        "base" => %{"ref" => "main", "sha" => m, "repo" => remote_repo}
      })

    %{sync: sync, pair: %{pull: raw_pull, issue: raw_issue}, m: m}
  end

  test "normalizes exact merge proof using existing relationship identities", %{
    sync: sync,
    pair: pair,
    m: m
  } do
    assert {:ok, result} = PullMergeObservation.build(sync, pair, m)
    assert result.remote_base_oid == m
    assert result.pull.confirmed_snapshot["title"] == "Remote title"

    assert result.pull.confirmed_merge_state == %{
             "merged_at" => "2026-09-08T00:00:00Z",
             "merge_commit_sha" => m
           }

    assert result.issue.confirmed_snapshot["label_github_ids"] == [800]
    assert result.issue.confirmed_snapshot["assignee_github_ids"] == [801]
    assert %DateTime{} = result.pull.remote_updated_at
    refute Map.has_key?(result.pull, :local_version)
  end

  test "rejects contradictory identities, refs, merge facts and malformed times", %{
    sync: sync,
    pair: pair,
    m: m
  } do
    for {path, value} <- [
          {[:pull, "id"], 903},
          {[:pull, "node_id"], "PR_wrong"},
          {[:issue, "id"], 903},
          {[:issue, "node_id"], "I_wrong"},
          {[:issue, "number"], 8},
          {[:pull, "merged"], false},
          {[:pull, "merge_commit_sha"], String.duplicate("d", 40)},
          {[:pull, "base", "sha"], String.duplicate("d", 40)},
          {[:pull, "head", "sha"], m},
          {[:pull, "base", "ref"], "other"},
          {[:pull, "base", "repo", "node_id"], "R_wrong"},
          {[:pull, "head", "repo", "id"], 999},
          {[:pull, "merged_at"], "invalid"},
          {[:issue, "updated_at"], "invalid"}
        ] do
      assert {:error, _} = PullMergeObservation.build(sync, put_in(pair, path, value), m)
    end

    assert {:error, _} = PullMergeObservation.build(sync, pair, sync.intent.expected_base_oid)
    assert {:error, _} = PullMergeObservation.build(sync, %{pull: %{}, issue: %{}}, m)
  end

  test "uses confirmed branch result when GitHub retains historical pull base and null issue reason",
       %{sync: sync, pair: pair, m: m} do
    pair =
      pair
      |> put_in([:pull, "base", "sha"], sync.intent.expected_base_oid)
      |> put_in([:issue, "state_reason"], nil)

    assert {:ok, result} = PullMergeObservation.build(sync, pair, m)
    assert result.pull.provider_base_oid == sync.intent.expected_base_oid
    assert result.issue.provider_state_reason == nil
    assert result.pull.confirmed_snapshot["base_sha"] == m
    assert result.pull.confirmed_snapshot["state_reason"] == "completed"
    assert result.issue.confirmed_snapshot["state_reason"] == "completed"
    assert {:error, _} = PullMergeObservation.build(sync, pair, sync.intent.expected_base_oid)

    for reason <- ["not_planned", "reopened"] do
      assert {:error, _} =
               PullMergeObservation.build(sync, put_in(pair, [:issue, "state_reason"], reason), m)
    end
  end

  test "unknown or substituted relationship identities cause no database writes", %{
    sync: sync,
    pair: pair,
    m: m
  } do
    before = {Repo.all(ForgeAccounts.GitHubIdentity), Repo.all(ForgeMirrors.MirrorResourceState)}

    for {kind, raw} <- [
          {"labels", [%{"id" => 999, "node_id" => "L_999", "name" => "new"}]},
          {"labels", [%{"id" => 800, "node_id" => "L_wrong", "name" => "known"}]},
          {"assignees", [%{"id" => 801, "node_id" => "U_wrong", "login" => "known"}]},
          {"assignees", [%{"id" => 999, "node_id" => "U_999", "login" => "new"}]}
        ] do
      assert {:error, :merge_metadata_unconfirmed} =
               PullMergeObservation.build(sync, put_in(pair, [:issue, kind], raw), m)
    end

    assert before ==
             {Repo.all(ForgeAccounts.GitHubIdentity), Repo.all(ForgeMirrors.MirrorResourceState)}
  end
end
