defmodule ForgeGitHub.PullSyncProjectionTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.PullSyncProjection

  test "projects canonical local pull metadata without mixing identity into the snapshot" do
    projection = %{
      repository_id: 10,
      resource_kind: :pull,
      local_resource_id: 20,
      local_resource_type: "ForgePulls.PullRequest",
      local_version: 3,
      issue_id: 30,
      issue_number: 7,
      head_repository_id: 10,
      merge_state: %{merged_at: nil, merge_commit_sha: nil},
      fields: fields()
    }

    assert {:ok,
            %{
              presence: :present,
              resource_kind: :pull,
              repository_id: 10,
              local_resource_id: 20,
              local_resource_type: "ForgePulls.PullRequest",
              local_version: 3,
              issue_id: 30,
              issue_number: 7,
              head_repository_id: 10,
              snapshot: snapshot,
              merge_state: %{merged: false, merged_at: nil, merge_commit_sha: nil},
              coordinator: %{
                status: :unsupported,
                mergeable: nil,
                rebaseable: nil,
                mergeable_state: nil
              },
              relationship_snapshot: nil
            }} = PullSyncProjection.from_local(projection)

    assert snapshot == fields()
    refute Map.has_key?(snapshot, "issue_id")
    refute Map.has_key?(snapshot, "head_repository_id")
  end

  test "composes remote pull metadata with its distinct canonical issue evidence" do
    pull = remote_pull()
    issue = remote_issue_observation()

    assert {:ok,
            %{
              presence: :present,
              resource_kind: :pull,
              github_object_id: 700,
              github_node_id: "PR_7",
              github_number: 7,
              github_issue_object_id: 800,
              github_issue_node_id: "I_7",
              head_repository: %{
                github_object_id: 2_002,
                github_node_id: "R_head",
                full_name: "contributor/fork"
              },
              base_repository: %{
                github_object_id: 1_001,
                github_node_id: "R_base",
                full_name: "acme/base"
              },
              remote_created_at: ~U[2030-01-01 00:00:00Z],
              remote_updated_at: ~U[2030-01-02 00:00:00Z],
              snapshot: snapshot,
              merge_state: %{merged: false, merged_at: nil, merge_commit_sha: nil},
              coordinator: %{
                status: :unsupported,
                mergeable: false,
                rebaseable: nil,
                mergeable_state: "dirty"
              },
              relationship_snapshot: %{
                "label_github_ids" => [11],
                "assignee_github_ids" => [22]
              },
              label_catalog: %{11 => %{name: "bug", local_label_id: 111}},
              assignee_catalog: %{22 => %{login: "octocat", ref: %{kind: :local_user, id: 222}}}
            }} = PullSyncProjection.from_remote(pull, issue)

    assert snapshot == %{
             "title" => "Canonical pull",
             "body" => nil,
             "state" => "open",
             "state_reason" => nil,
             "draft" => true,
             "head_ref" => "refs/heads/feature",
             "head_sha" => String.duplicate("a", 40),
             "base_ref" => "refs/heads/main",
             "base_sha" => String.duplicate("b", 40)
           }

    refute Map.has_key?(snapshot, "github_object_id")
    refute Map.has_key?(snapshot, "head_repository")
    assert pull["id"] != issue.github_object_id
  end

  test "requires one consistent pull and canonical issue observation" do
    pull = remote_pull()
    issue = remote_issue_observation()

    for inconsistent_issue <- [
          %{issue | github_number: 8},
          put_in(issue, [:snapshot, "title"], "Raced title"),
          put_in(issue, [:snapshot, "body"], "Raced body"),
          put_in(issue, [:snapshot, "state"], "closed")
        ] do
      assert {:error, :inconsistent_observation} =
               PullSyncProjection.from_remote(pull, inconsistent_issue)
    end

    malformed_pull = put_in(pull, ["head", "repo", "full_name"], 123)

    assert {:error, :invalid_projection} =
             PullSyncProjection.from_remote(malformed_pull, issue)
  end

  test "allows the same branch name when head and base repositories differ" do
    remote = put_in(remote_pull(), ["head", "ref"], "main")

    assert {:ok, %{snapshot: %{"head_ref" => "refs/heads/main", "base_ref" => "refs/heads/main"}}} =
             PullSyncProjection.from_remote(remote, remote_issue_observation())

    local = %{
      repository_id: 10,
      resource_kind: :pull,
      local_resource_id: 20,
      local_resource_type: "ForgePulls.PullRequest",
      local_version: 3,
      issue_id: 30,
      issue_number: 7,
      head_repository_id: 11,
      merge_state: %{merged_at: nil, merge_commit_sha: nil},
      fields: %{fields() | "head_ref" => "refs/heads/main"}
    }

    assert {:ok, %{snapshot: %{"head_ref" => "refs/heads/main", "base_ref" => "refs/heads/main"}}} =
             PullSyncProjection.from_local(local)
  end

  defp fields do
    %{
      "title" => "Canonical pull",
      "body" => nil,
      "state" => "open",
      "state_reason" => nil,
      "draft" => false,
      "head_ref" => "refs/heads/feature",
      "head_sha" => String.duplicate("a", 40),
      "base_ref" => "refs/heads/main",
      "base_sha" => String.duplicate("b", 40)
    }
  end

  defp remote_pull do
    %{
      "id" => 700,
      "node_id" => "PR_7",
      "number" => 7,
      "title" => "Canonical pull",
      "body" => "",
      "state" => "open",
      "draft" => true,
      "created_at" => "2030-01-01T00:00:00Z",
      "updated_at" => "2030-01-02T00:00:00Z",
      "merged" => false,
      "merged_at" => nil,
      "merge_commit_sha" => String.duplicate("c", 40),
      "mergeable" => false,
      "rebaseable" => nil,
      "mergeable_state" => "dirty",
      "head" => %{
        "ref" => "feature",
        "sha" => String.duplicate("a", 40),
        "repo" => %{
          "id" => 2_002,
          "node_id" => "R_head",
          "full_name" => "contributor/fork"
        }
      },
      "base" => %{
        "ref" => "main",
        "sha" => String.duplicate("b", 40),
        "repo" => %{"id" => 1_001, "node_id" => "R_base", "full_name" => "acme/base"}
      }
    }
  end

  defp remote_issue_observation do
    %{
      presence: :present,
      resource_kind: :issue,
      github_object_id: 800,
      github_node_id: "I_7",
      github_number: 7,
      snapshot: %{
        "title" => "Canonical pull",
        "body" => nil,
        "state" => "open",
        "state_reason" => nil,
        "label_github_ids" => [11],
        "assignee_github_ids" => [22]
      },
      label_catalog: %{11 => %{name: "bug", local_label_id: 111}},
      assignee_catalog: %{
        22 => %{login: "octocat", ref: %{kind: :local_user, id: 222}}
      }
    }
  end
end
