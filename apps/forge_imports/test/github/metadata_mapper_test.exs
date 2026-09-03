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

    assert {:skip, :pull_request_issue, %{number: 7}} = MetadataMapper.issue(pull_backed)
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

  test "skips cross-repository and draft pulls" do
    cross = fixture!("pull_cross_repo.json")

    assert {:skip, :cross_repository_pull, _details} =
             MetadataMapper.pull(cross, 1_296_269, staged_refs: %{})

    draft = Map.put(cross, "draft", true)

    assert {:skip, :draft_pull, _details} =
             MetadataMapper.pull(draft, 1_296_269, staged_refs: %{})
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
end
