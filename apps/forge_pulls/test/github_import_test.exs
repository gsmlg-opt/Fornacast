defmodule ForgePulls.GitHubImportTest do
  use ExUnit.Case, async: false

  alias Ecto.Multi
  alias ForgePulls.PullRequest
  alias Fornacast.Repo

  @merged_at ~U[2025-02-03 00:00:00Z]
  @inserted_at ~U[2025-02-01 00:00:00Z]
  @updated_at ~U[2025-02-03 00:00:00Z]

  setup do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    end

    owner = user_fixture("pull-import-#{System.unique_integer([:positive])}")
    repository = repository_fixture(owner)
    merger = github_identity_fixture("merger")
    ghost = ForgeAccounts.github_deleted_identity()

    %{owner: owner, repository: repository, merger: merger, ghost: ghost}
  end

  test "imports a merged pull with exact refs, shas, timestamps, and github merger", %{
    repository: repository,
    merger: merger
  } do
    canonical_issue = import_issue!(repository, merger, 12, :pull_request, "Imported pull")
    head = String.duplicate("a", 40)
    base = String.duplicate("b", 40)
    merge = String.duplicate("c", 40)

    assert {:ok, %{pull: pull}} =
             Multi.new()
             |> ForgePulls.import_pull_request_multi(
               :pull,
               repository,
               canonical_issue,
               merger,
               %{
                 head_ref: "refs/heads/feature",
                 base_ref: "refs/heads/main",
                 head_sha: head,
                 base_sha: base,
                 merged_at: @merged_at,
                 merge_commit_sha: merge,
                 inserted_at: @inserted_at,
                 updated_at: @updated_at
               }
             )
             |> ForgeIssues.transaction()

    assert pull.issue_id == canonical_issue.id
    assert pull.repository_id == repository.id
    assert pull.head_ref == "refs/heads/feature"
    assert pull.base_ref == "refs/heads/main"
    assert pull.head_sha == head
    assert pull.base_sha == base
    assert pull.merged_at == @merged_at
    assert pull.merge_commit_sha == merge
    assert pull.merged_by_github_identity_id == merger.id
    assert is_nil(pull.merged_by_user_id)
    assert pull.inserted_at == @inserted_at
    assert pull.updated_at == @updated_at
  end

  test "imports an unmerged pull without merger fields", %{repository: repository, merger: merger} do
    canonical_issue = import_issue!(repository, merger, 13, :pull_request, "Open pull")

    assert {:ok, %{pull: pull}} =
             Multi.new()
             |> ForgePulls.import_pull_request_multi(
               :pull,
               repository,
               canonical_issue,
               nil,
               %{
                 head_ref: "refs/heads/feature",
                 base_ref: "refs/heads/main",
                 head_sha: String.duplicate("d", 40),
                 base_sha: String.duplicate("e", 40),
                 inserted_at: @inserted_at,
                 updated_at: @updated_at
               }
             )
             |> ForgeIssues.transaction()

    assert is_nil(pull.merged_at)
    assert is_nil(pull.merge_commit_sha)
    assert is_nil(pull.merged_by_github_identity_id)
    assert is_nil(pull.merged_by_user_id)
  end

  test "records ghost mergers through the deleted github identity", %{
    repository: repository,
    merger: merger,
    ghost: ghost
  } do
    canonical_issue = import_issue!(repository, merger, 14, :pull_request, "Ghost merge")

    assert {:ok, %{pull: pull}} =
             Multi.new()
             |> ForgePulls.import_pull_request_multi(
               :pull,
               repository,
               canonical_issue,
               ghost,
               %{
                 head_ref: "refs/heads/feature",
                 base_ref: "refs/heads/main",
                 head_sha: String.duplicate("f", 40),
                 base_sha: String.duplicate("0", 40),
                 merged_at: @merged_at,
                 merge_commit_sha: String.duplicate("1", 40),
                 inserted_at: @inserted_at,
                 updated_at: @updated_at
               }
             )
             |> ForgeIssues.transaction()

    assert pull.merged_by_github_identity_id == ghost.id
  end

  test "rejects wrong-repository and non-pull canonical issues", %{
    repository: repository,
    owner: owner,
    merger: merger
  } do
    other_repository = repository_fixture(owner)
    wrong_repo_issue = import_issue!(other_repository, merger, 3, :pull_request, "Wrong repo")
    plain_issue = import_issue!(repository, merger, 4, :issue, "Not a pull")
    canonical_issue = import_issue!(repository, merger, 5, :pull_request, "Valid host")

    base_attrs = %{
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("2", 40),
      base_sha: String.duplicate("3", 40),
      inserted_at: @inserted_at,
      updated_at: @updated_at
    }

    assert {:error, :pull, changeset, _} =
             Multi.new()
             |> ForgePulls.import_pull_request_multi(
               :pull,
               repository,
               wrong_repo_issue,
               nil,
               base_attrs
             )
             |> ForgeIssues.transaction()

    assert {"must match the canonical issue repository", _} =
             Keyword.fetch!(changeset.errors, :repository_id)

    assert {:error, :pull, changeset, _} =
             Multi.new()
             |> ForgePulls.import_pull_request_multi(
               :pull,
               repository,
               plain_issue,
               nil,
               base_attrs
             )
             |> ForgeIssues.transaction()

    assert {"must reference a pull request identity", _} =
             Keyword.fetch!(changeset.errors, :issue_id)

    assert {:ok, %{pull: _pull}} =
             Multi.new()
             |> ForgePulls.import_pull_request_multi(
               :pull,
               repository,
               canonical_issue,
               nil,
               base_attrs
             )
             |> ForgeIssues.transaction()
  end

  test "rejects invalid and identical branch refs", %{repository: repository, merger: merger} do
    canonical_issue = import_issue!(repository, merger, 15, :pull_request, "Invalid refs")

    base = %{
      head_sha: String.duplicate("4", 40),
      base_sha: String.duplicate("5", 40),
      inserted_at: @inserted_at,
      updated_at: @updated_at
    }

    assert %{valid?: false} =
             PullRequest.import_changeset(
               %PullRequest{issue_id: canonical_issue.id, repository_id: repository.id},
               Map.merge(base, %{head_ref: "feature", base_ref: "refs/heads/main"}),
               canonical_issue,
               repository
             )

    assert %{valid?: false} =
             PullRequest.import_changeset(
               %PullRequest{issue_id: canonical_issue.id, repository_id: repository.id},
               Map.merge(base, %{
                 head_ref: "refs/heads/main",
                 base_ref: "refs/heads/main"
               }),
               canonical_issue,
               repository
             )
  end

  test "ordinary pull creation remains unchanged", %{owner: owner, repository: repository} do
    create_mergeable_branches!(repository)

    assert {:ok, pull} =
             ForgePulls.create_pull_request(
               repository,
               owner,
               %{"title" => "Live pull", "head" => "feature", "base" => "main"},
               %{}
             )

    assert pull.issue.kind == :pull_request
    assert is_nil(pull.merged_at)
  end

  defp import_issue!(repository, identity, number, kind, title) do
    assert {:ok, %{issue: issue}} =
             Multi.new()
             |> ForgeIssues.import_identity_multi(
               :issue,
               repository,
               identity,
               kind,
               %{
                 number: number,
                 title: title,
                 body: nil,
                 state: :open,
                 inserted_at: @inserted_at,
                 updated_at: @updated_at
               }
             )
             |> ForgeIssues.transaction()

    issue
  end

  defp github_identity_fixture(login) do
    suffix = System.unique_integer([:positive])

    assert {:ok, identity} =
             ForgeAccounts.observe_github_identity(
               %{
                 github_user_id: 9_400_000_000 + suffix,
                 login: "#{login}-#{suffix}",
                 avatar_url: nil,
                 profile_url: nil
               },
               DateTime.utc_now(:second)
             )

    identity
  end

  defp user_fixture(username) do
    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp repository_fixture(owner) do
    slug = "pull-import-#{System.unique_integer([:positive])}"

    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{name: slug, slug: slug, visibility: :private})

    repository
  end

  defp create_mergeable_branches!(repository) do
    path = ForgeRepos.absolute_storage_path(repository)

    {tree, 0} =
      System.cmd("git", ["--git-dir=#{path}", "hash-object", "-t", "tree", "-w", "/dev/null"])

    {base, 0} =
      System.cmd("git", ["--git-dir=#{path}", "commit-tree", String.trim(tree), "-m", "base"])

    {head, 0} =
      System.cmd("git", [
        "--git-dir=#{path}",
        "commit-tree",
        String.trim(tree),
        "-p",
        String.trim(base),
        "-m",
        "head"
      ])

    {_, 0} =
      System.cmd("git", ["--git-dir=#{path}", "update-ref", "refs/heads/main", String.trim(base)])

    {_, 0} =
      System.cmd("git", [
        "--git-dir=#{path}",
        "update-ref",
        "refs/heads/feature",
        String.trim(head)
      ])
  end
end
