defmodule FornacastAPI.Serializers.V2026_03_10.Pull do
  alias FornacastAPI.{Serializer, URL}
  alias FornacastAPI.Serializers.V2026_03_10

  @version "2026-03-10"

  def render(pull, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    view = Keyword.fetch!(opts, :repository_view)
    issue = pull.issue
    url = URL.pull(owner, repo, issue.number)
    issue_url = URL.issue(owner, repo, issue.number)
    author = Serializer.render(@version, :simple_user, issue.author, opts)

    assignees =
      Enum.map(issue.assignees || [], &Serializer.render(@version, :simple_user, &1, opts))

    repository = V2026_03_10.render(:repository, view, actor: Keyword.get(opts, :actor))
    owner_user = V2026_03_10.render(:simple_user, view.owner, [])
    merged = not is_nil(pull.merged_at) and not is_nil(pull.merge_commit_sha)

    %{
      _links: links(owner, repo, issue.number, pull.head_sha),
      additions: 0,
      assignees: assignees,
      author_association: issue.author_association,
      auto_merge: nil,
      base: branch(owner, pull.base_ref, pull.base_sha, repository, owner_user),
      body: issue.body,
      changed_files: 0,
      closed_at: timestamp(issue.closed_at),
      comments: issue.comment_count,
      comments_url: issue_url <> "/comments",
      commits: 0,
      commits_url: URL.pull_commits(owner, repo, issue.number),
      created_at: timestamp(issue.inserted_at),
      deletions: 0,
      diff_url: url,
      draft: false,
      head: branch(owner, pull.head_ref, pull.head_sha, repository, owner_user),
      html_url: URL.pull_web(owner, repo, issue.number),
      id: pull.id,
      issue_url: issue_url,
      labels:
        Enum.map(
          issue.labels || [],
          &Serializer.render(@version, :label, &1, owner: owner, repo: repo)
        ),
      locked: false,
      maintainer_can_modify: false,
      mergeable: pull.mergeable,
      mergeable_state: Atom.to_string(pull.mergeable_state || :unknown),
      merged: merged,
      merged_at: timestamp(pull.merged_at),
      merged_by:
        if(pull.merged_by,
          do: Serializer.render(@version, :simple_user, pull.merged_by, opts),
          else: nil
        ),
      milestone: nil,
      node_id: node_id("PullRequest", pull.id),
      number: issue.number,
      patch_url: url,
      requested_reviewers: [],
      requested_teams: [],
      review_comment_url: url <> "/comments{/number}",
      review_comments: 0,
      review_comments_url: url <> "/comments",
      state: Atom.to_string(issue.state),
      statuses_url: URL.commit_statuses(owner, repo, pull.head_sha),
      title: issue.title,
      updated_at: timestamp(issue.updated_at),
      url: url,
      user: author
    }
  end

  def render_merge(result, _opts),
    do: %{sha: result.sha, merged: result.merged, message: result.message}

  defp branch(owner, ref, sha, repository, user) do
    short_ref = String.replace_prefix(ref, "refs/heads/", "")
    %{label: "#{owner}:#{short_ref}", ref: short_ref, sha: sha, repo: repository, user: user}
  end

  defp links(owner, repo, number, head_sha) do
    url = URL.pull(owner, repo, number)
    issue_url = URL.issue(owner, repo, number)

    %{
      self: %{href: url},
      html: %{href: URL.pull_web(owner, repo, number)},
      issue: %{href: issue_url},
      comments: %{href: issue_url <> "/comments"},
      review_comments: %{href: url <> "/comments"},
      review_comment: %{href: url <> "/comments{/number}"},
      commits: %{href: url <> "/commits"},
      statuses: %{href: URL.commit_statuses(owner, repo, head_sha)}
    }
  end

  defp node_id(type, id), do: Base.url_encode64("#{type}:#{id}", padding: false)
  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)
end
