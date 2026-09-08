defmodule ForgePulls.GitHubImportTest do
  use ExUnit.Case, async: false

  import Ecto.Query

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
    assert Map.get(pull, :head_repository_id) == repository.id
    assert Map.get(pull, :draft) == false
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

  test "trusted import head choice cannot be replaced by attrs", ctx do
    represented = repository_fixture(ctx.owner)

    for {head_id, number} <- [{nil, 91}, {represented.id, 92}] do
      issue = import_issue!(ctx.repository, ctx.merger, number, :pull_request, "Head import")

      attrs =
        Map.merge(head_import_attrs(), %{head_repository_id: ctx.repository.id, draft: true})

      assert {:ok, %{pull: pull}} =
               Multi.new()
               |> ForgePulls.import_pull_request_multi(
                 :pull,
                 ctx.repository,
                 issue,
                 nil,
                 attrs,
                 head_id
               )
               |> Repo.transaction()

      assert pull.head_repository_id == head_id
      assert pull.draft
    end
  end

  test "trusted head import preserves canonical repository checks and invalid head errors", ctx do
    other = repository_fixture(ctx.owner)
    foreign_issue = import_issue!(other, ctx.merger, 91, :pull_request, "Foreign")

    assert {:error, :pull, changeset, _} =
             Multi.new()
             |> ForgePulls.import_pull_request_multi(
               :pull,
               ctx.repository,
               foreign_issue,
               nil,
               head_import_attrs(),
               nil
             )
             |> Repo.transaction()

    assert changeset.errors[:repository_id]

    issue = import_issue!(ctx.repository, ctx.merger, 92, :pull_request, "Invalid head")

    for head_id <- [-1, "123", 9_223_372_036_854_775_808] do
      assert {:error, :pull, changeset, _} =
               Multi.new()
               |> ForgePulls.import_pull_request_multi(
                 :pull,
                 ctx.repository,
                 issue,
                 nil,
                 head_import_attrs(),
                 head_id
               )
               |> Repo.transaction()

      assert changeset.errors[:head_repository_id]
    end
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
               %{
                 "title" => "Live pull",
                 "head" => "feature",
                 "base" => "main",
                 "head_repository_id" => nil
               },
               %{}
             )

    assert pull.issue.kind == :pull_request
    assert Map.get(pull, :head_repository_id) == repository.id
    assert Map.get(pull, :draft) == false
    assert is_nil(pull.merged_at)
  end

  test "head identity foreign key permits same-repository cascade deletion", %{
    repository: repository,
    merger: merger
  } do
    issue = import_issue!(repository, merger, 31, :pull_request, "Draft pull")

    attrs = %{
      draft: true,
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40),
      inserted_at: @inserted_at,
      updated_at: @updated_at
    }

    assert {:ok, pull} =
             %PullRequest{issue_id: issue.id, repository_id: repository.id}
             |> PullRequest.import_changeset(attrs, issue, repository)
             |> Repo.insert()

    assert Map.get(Repo.get!(PullRequest, pull.id), :draft) == true
    assert Map.get(pull, :head_repository_id) == repository.id
    assert {1, _} = Repo.delete_all(where(ForgeRepos.Repository, id: ^repository.id))
    assert Repo.get(PullRequest, pull.id) == nil
  end

  test "external-head pulls reject all shared issue and comment mutations", ctx do
    {issue, pull} = import_head_pull!(ctx, nil)

    {:ok, %{comment: comment}} =
      Multi.new()
      |> ForgeIssues.import_comment_multi(:comment, issue, ctx.merger, %{
        body: "Remote comment",
        inserted_at: @inserted_at,
        updated_at: @updated_at
      })
      |> Repo.transaction()

    for attrs <- [
          %{title: "Changed"},
          %{state: :closed},
          %{labels: ["bug"]},
          %{assignees: [ctx.owner.username]}
        ] do
      assert {:error, :forbidden} =
               ForgeIssues.update(
                 ctx.owner,
                 ctx.owner.username,
                 ctx.repository.slug,
                 issue.number,
                 attrs,
                 %{}
               )
    end

    assert {:error, :forbidden} =
             ForgeIssues.create_comment(
               ctx.owner,
               ctx.owner.username,
               ctx.repository.slug,
               issue.number,
               %{body: "Local"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeIssues.update_comment(
               ctx.owner,
               ctx.owner.username,
               ctx.repository.slug,
               comment.id,
               %{body: "Local"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeIssues.delete_comment(
               ctx.owner,
               ctx.owner.username,
               ctx.repository.slug,
               comment.id,
               %{}
             )

    assert {:error, :forbidden} =
             ForgePulls.update_pull_request(
               ctx.repository,
               pull,
               ctx.owner,
               %{title: "Local"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgePulls.merge(ctx.repository, pull, ctx.owner, %{}, %{
               request_id: "external-merge"
             })

    assert {:ok, visible_comment} =
             ForgeIssues.get_comment(
               ctx.owner,
               ctx.owner.username,
               ctx.repository.slug,
               comment.id
             )

    assert visible_comment.capabilities == %{can_edit: false, can_delete: false}
    assert Repo.get!(ForgeIssues.Issue, issue.id).title == issue.title
    assert Repo.get!(ForgeIssues.Comment, comment.id).body == "Remote comment"
  end

  test "external-head metadata remains readable with no mutation capabilities or local ref refresh",
       ctx do
    {issue, pull} = import_head_pull!(ctx, nil)

    assert {:ok, visible_issue} =
             ForgeIssues.get(ctx.owner, ctx.owner.username, ctx.repository.slug, issue.number)

    assert visible_issue.capabilities.can_create

    refute Enum.any?(Map.delete(visible_issue.capabilities, :can_create), fn {_key, allowed} ->
             allowed
           end)

    assert {:ok, visible} = ForgePulls.get_pull_request(ctx.repository, issue.number, ctx.owner)
    assert visible.head_sha == pull.head_sha
    assert visible.base_sha == pull.base_sha
    refute Enum.any?(visible.capabilities, fn {_key, allowed} -> allowed end)
    assert Repo.get!(PullRequest, pull.id).head_sha == pull.head_sha
  end

  test "represented cross-repository metadata can change but cannot merge using base-repository head refs",
       ctx do
    head_repository = repository_fixture(ctx.owner)
    {issue, pull} = import_head_pull!(ctx, head_repository.id)

    assert {:ok, changed} =
             ForgePulls.update_pull_request(
               ctx.repository,
               pull,
               ctx.owner,
               %{title: "Edited metadata"},
               %{}
             )

    assert changed.issue.title == "Edited metadata"
    assert changed.head_sha == pull.head_sha
    assert {:ok, visible} = ForgePulls.get_pull_request(ctx.repository, issue.number, ctx.owner)
    assert visible.capabilities.can_edit
    refute visible.capabilities.can_merge

    assert {:error, :forbidden} =
             ForgePulls.merge(ctx.repository, visible, ctx.owner, %{}, %{
               request_id: "cross-merge"
             })
  end

  test "a canonical pull identity without its extension fails closed", ctx do
    issue = import_issue!(ctx.repository, ctx.merger, 71, :pull_request, "Incomplete pull")

    assert {:error, :forbidden} =
             ForgeIssues.update(
               ctx.owner,
               ctx.owner.username,
               ctx.repository.slug,
               issue.number,
               %{title: "Changed"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeIssues.create_comment(
               ctx.owner,
               ctx.owner.username,
               ctx.repository.slug,
               issue.number,
               %{body: "Local"},
               %{}
             )
  end

  test "external and represented foreign heads cannot read commits or files from the base repository",
       ctx do
    head_repository = repository_fixture(ctx.owner)

    for head_id <- [nil, head_repository.id] do
      {issue, pull} = import_head_pull!(ctx, head_id)

      assert {:error, :cross_repository_head} =
               ForgePulls.list_commits(ctx.repository, pull, ctx.owner)

      assert {:error, :cross_repository_head} =
               ForgePulls.changed_files(ctx.repository, pull, ctx.owner)

      Repo.delete!(pull)
      Repo.delete!(issue)
    end
  end

  defp import_head_pull!(ctx, head_repository_id) do
    issue = import_issue!(ctx.repository, ctx.merger, 70, :pull_request, "Remote head")

    {:ok, %{pull: pull}} =
      Multi.new()
      |> ForgePulls.import_pull_request_multi(
        :pull,
        ctx.repository,
        issue,
        nil,
        head_import_attrs(),
        head_repository_id
      )
      |> Repo.transaction()

    {issue, pull}
  end

  defp head_import_attrs do
    %{
      head_ref: "refs/heads/remote-feature",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40),
      inserted_at: @inserted_at,
      updated_at: @updated_at
    }
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
