defmodule ForgeImports.GitHub.MetadataMapperTest do
  use ExUnit.Case, async: true

  alias ForgeImports.GitHub.MetadataMapper

  @fixtures Path.expand("../fixtures/github", __DIR__)

  test "maps label payloads" do
    [payload | _] = fixture!("labels_page.json")

    assert {:ok, %{github_id: 208_045_946, name: "bug", color: "d73a4a"}} =
             MetadataMapper.label(payload)
  end

  test "maps issue payloads with exact ids and kind" do
    [payload | _] = fixture!("issues_page.json")

    assert {:ok, %{github_id: 301, number: 7, kind: :issue}} = MetadataMapper.issue(payload)
  end

  test "skips issue payloads that represent pull requests" do
    issue_payload = hd(fixture!("issues_page.json"))

    pull_backed =
      Map.put(issue_payload, "pull_request", %{
        "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/7"
      })

    assert {:skip, :pull_request_issue, %{number: 7, github_issue_id: 301}} =
             MetadataMapper.issue(pull_backed)

    assert {:error, :invalid_issue} = MetadataMapper.issue(Map.put(pull_backed, "id", nil))
    assert {:error, :invalid_issue} = MetadataMapper.issue(Map.put(pull_backed, "number", 0))
  end

  test "maps comment payloads and deleted authors to ghost semantics" do
    [payload | _] = fixture!("comments_page.json")

    assert {:ok, %{github_id: 601, author_github_user_id: 583_231, author_deleted: false}} =
             MetadataMapper.comment(payload)

    assert {:ok, %{author_github_user_id: nil, author_deleted: true}} =
             MetadataMapper.comment(Map.put(payload, "user", nil))
  end

  test "maps same-repository merged pulls when staged refs match" do
    payload = fixture!("pull_same_repo.json")

    staged_refs = %{
      "refs/heads/feature" => payload["head"]["sha"],
      "refs/heads/main" => payload["base"]["sha"]
    }

    assert {:ok, pull} =
             MetadataMapper.pull(payload, 1_296_269, staged_refs: staged_refs)

    assert pull.number == 7
    assert pull.head_ref == "refs/heads/feature"
    assert pull.merge_commit_sha == payload["merge_commit_sha"]
    assert pull.merger_github_user_id == 9001
  end

  test "maps an authenticated pull and canonical issue observation without conflating ids" do
    pull =
      fixture!("pull_same_repo.json")
      |> authenticated_pull_identity()

    issue = pull_issue_payload(pull, 302, "I_kwDOIssue302")

    staged_refs = %{
      "refs/heads/feature" => pull["head"]["sha"],
      "refs/heads/main" => pull["base"]["sha"]
    }

    assert {:ok, mapped} =
             MetadataMapper.pull_observation(pull, issue, 1_296_269,
               source_full_name: "octocat/Hello-World",
               expected_issue_id: 302,
               staged_refs: staged_refs
             )

    assert mapped.github_id == 701
    assert mapped.github_node_id == "PR_kwDOPull701"
    assert mapped.github_issue_id == 302
    assert mapped.github_issue_node_id == "I_kwDOIssue302"

    assert mapped.snapshot == %{
             "title" => "Same repo pull",
             "body" => "Pull body",
             "state" => "closed",
             "state_reason" => "completed",
             "draft" => false,
             "head_ref" => "refs/heads/feature",
             "head_sha" => pull["head"]["sha"],
             "base_ref" => "refs/heads/main",
             "base_sha" => pull["base"]["sha"]
           }

    assert mapped.issue_snapshot == %{
             "title" => "Same repo pull",
             "body" => "Pull body",
             "state" => "closed",
             "state_reason" => "completed",
             "label_github_ids" => [],
             "assignee_github_ids" => []
           }

    assert mapped.provider_identity == %{
             "github_issue_object_id" => 302,
             "github_issue_node_id" => "I_kwDOIssue302",
             "github_number" => 7,
             "head_repository" => %{"id" => 1_296_269, "node_id" => "R_repo"},
             "base_repository" => %{"id" => 1_296_269, "node_id" => "R_repo"}
           }

    assert mapped.merge_state == %{
             "merged_at" => "2025-02-03T00:00:00Z",
             "merge_commit_sha" => pull["merge_commit_sha"]
           }

    assert {:error, :pull_issue_identity_mismatch} =
             MetadataMapper.pull_observation(pull, issue, 1_296_269,
               source_full_name: "octocat/Hello-World",
               expected_issue_id: 701,
               staged_refs: staged_refs
             )

    assert {:error, :pull_issue_identity_mismatch} =
             MetadataMapper.pull_observation(
               pull,
               Map.put(issue, "title", "raced title"),
               1_296_269,
               source_full_name: "octocat/Hello-World",
               expected_issue_id: 302,
               staged_refs: staged_refs
             )

    assert {:error, :pull_issue_identity_mismatch} =
             MetadataMapper.pull_observation(
               put_in(pull, ["head", "repo", "node_id"], "R_wrong"),
               issue,
               1_296_269,
               source_full_name: "octocat/Hello-World",
               expected_issue_id: 302,
               staged_refs: staged_refs
             )

    assert {:error, :pull_issue_identity_mismatch} =
             MetadataMapper.pull_observation(
               pull,
               Map.put(issue, "updated_at", nil),
               1_296_269,
               source_full_name: "octocat/Hello-World",
               expected_issue_id: 302,
               staged_refs: staged_refs
             )
  end

  test "maps pull bodies up to 65536 four-byte codepoints" do
    body = String.duplicate("😀", 65_536)

    pull =
      fixture!("pull_same_repo.json")
      |> authenticated_pull_identity()
      |> Map.put("body", body)

    issue =
      pull_issue_payload(pull, 302, "I_kwDOIssue302")
      |> Map.put("body", body)

    staged_refs = %{
      "refs/heads/feature" => pull["head"]["sha"],
      "refs/heads/main" => pull["base"]["sha"]
    }

    assert {:ok, %{body: ^body, issue_snapshot: %{"body" => ^body}}} =
             MetadataMapper.pull_observation(pull, issue, 1_296_269,
               source_full_name: "octocat/Hello-World",
               expected_issue_id: 302,
               staged_refs: staged_refs
             )

    too_long = body <> "a"

    assert {:error, :invalid_pull} =
             MetadataMapper.pull_observation(
               Map.put(pull, "body", too_long),
               Map.put(issue, "body", too_long),
               1_296_269,
               source_full_name: "octocat/Hello-World",
               expected_issue_id: 302,
               staged_refs: staged_refs
             )
  end

  test "maps external heads by provider identity and preserves drafts" do
    cross = fixture!("pull_cross_repo.json")
    staged = %{"refs/heads/main" => cross["base"]["sha"]}

    assert {:ok, %{head_github_repository_id: 9_999_999, draft: false}} =
             MetadataMapper.pull(cross, 1_296_269, staged_refs: staged)

    draft = fixture!("pull_same_repo.json") |> Map.put("draft", true)
    refs = Map.put(staged, "refs/heads/feature", draft["head"]["sha"])

    assert {:ok, %{draft: true, head_github_repository_id: 1_296_269}} =
             MetadataMapper.pull(draft, 1_296_269, staged_refs: refs)

    assert {:error, :invalid_pull} =
             MetadataMapper.pull(put_in(cross, ["base", "repo", "id"], 77), 1_296_269,
               staged_refs: staged
             )

    assert {:error, :invalid_pull} =
             MetadataMapper.pull(Map.put(draft, "draft", "true"), 1_296_269, staged_refs: refs)
  end

  test "skips pulls when staged refs are missing or drift" do
    payload = fixture!("pull_same_repo.json")

    assert {:skip, :deleted_branch, _details} =
             MetadataMapper.pull(payload, 1_296_269, staged_refs: %{})

    staged_refs = %{
      "refs/heads/feature" => String.duplicate("f", 40),
      "refs/heads/main" => payload["base"]["sha"]
    }

    assert {:skip, :source_drift, %{ref: "refs/heads/feature"}} =
             MetadataMapper.pull(payload, 1_296_269, staged_refs: staged_refs)
  end

  test "accepts 64-bit github ids" do
    [payload | _] = fixture!("issues_page.json")
    payload = Map.put(payload, "id", 9_007_199_254_740_992)

    assert {:ok, %{github_id: 9_007_199_254_740_992}} = MetadataMapper.issue(payload)
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp authenticated_pull_identity(pull) do
    pull
    |> Map.put("node_id", "PR_kwDOPull701")
    |> put_in(["head", "repo", "node_id"], "R_repo")
    |> put_in(["head", "repo", "full_name"], "octocat/Hello-World")
    |> put_in(["base", "repo", "node_id"], "R_repo")
    |> put_in(["base", "repo", "full_name"], "octocat/Hello-World")
  end

  defp pull_issue_payload(pull, issue_id, issue_node_id) do
    fixture!("issues_page.json")
    |> hd()
    |> Map.merge(%{
      "id" => issue_id,
      "node_id" => issue_node_id,
      "number" => pull["number"],
      "title" => pull["title"],
      "body" => pull["body"],
      "state" => pull["state"],
      "state_reason" => "completed",
      "created_at" => pull["created_at"],
      "updated_at" => pull["updated_at"],
      "closed_at" => pull["merged_at"],
      "pull_request" => %{
        "url" => "https://api.github.com/repos/octocat/Hello-World/pulls/#{pull["number"]}"
      }
    })
  end
end
