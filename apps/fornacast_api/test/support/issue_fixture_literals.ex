defmodule FornacastAPI.IssueFixtureLiterals do
  @moduledoc false

  @versions ["2022-11-28", "2026-03-10"]

  def versions, do: @versions

  def regenerate! do
    fixture_root = Path.expand("../fixtures", __DIR__)

    for version <- versions(), {filename, literal} <- files(version) do
      fixture_path = Path.join([fixture_root, version, "issues", filename])
      File.write!(fixture_path, JSON.encode!(literal))
    end
  end

  def files(version) when version in @versions do
    issue = build_issue() |> stringify_keys()
    comment = comment() |> stringify_keys()

    %{
      "issue.json" => issue,
      "pull-issue.json" => version |> pull_issue() |> stringify_keys(),
      "issue-comment.json" => comment,
      "issue-list.json" => [issue],
      "issue-comment-list.json" => [comment]
    }
  end

  def issue, do: build_issue()
  def pull_issue(version) when version in @versions, do: build_issue(pull_link(version))

  def comment do
    url = "https://forge.test/api/v3/repos/acme/widget/issues/comments/3101"

    %{
      url: url,
      html_url: url,
      issue_url: "https://forge.test/api/v3/repos/acme/widget/issues/7",
      id: 3101,
      node_id: "SXNzdWVDb21tZW50OjMxMDE",
      user: simple_user(),
      created_at: "2026-07-21T00:00:00Z",
      updated_at: "2026-07-21T00:00:00Z",
      author_association: "NONE",
      body: "First comment",
      reactions: comment_reactions(),
      performed_via_github_app: nil
    }
  end

  def label do
    %{
      id: 3201,
      node_id: "TGFiZWw6MzIwMQ",
      url: "https://forge.test/api/v3/repos/acme/widget/labels/bug",
      name: "bug",
      color: "ff0000",
      default: false,
      description: nil
    }
  end

  defp build_issue(pull_request \\ nil) do
    url = "https://forge.test/api/v3/repos/acme/widget/issues/7"

    %{
      url: url,
      repository_url: "https://forge.test/api/v3/repos/acme/widget",
      labels_url: url <> "/labels{/name}",
      comments_url: url <> "/comments",
      events_url: url <> "/events",
      html_url: url,
      id: 3001,
      node_id: "SXNzdWU6MzAwMQ",
      number: 7,
      title: "API issue",
      user: simple_user(),
      labels: [],
      state: "open",
      locked: false,
      assignee: nil,
      assignees: [],
      milestone: nil,
      comments: 0,
      created_at: "2026-07-21T00:00:00Z",
      updated_at: "2026-07-21T00:00:00Z",
      closed_at: nil,
      author_association: "NONE",
      active_lock_reason: nil,
      draft: false,
      body: "Track compatibility",
      closed_by: nil,
      reactions: issue_reactions(),
      timeline_url: url <> "/timeline",
      performed_via_github_app: nil,
      state_reason: nil
    }
    |> maybe_put_pull_request(pull_request)
  end

  defp pull_link(version) do
    url = "https://forge.test/api/v3/repos/acme/widget/pulls/7"
    link = %{url: url, html_url: url, diff_url: url, patch_url: url}

    if version == "2022-11-28", do: Map.put(link, :merged_at, nil), else: link
  end

  defp simple_user do
    %{
      avatar_url: "https://forge.test/octocat",
      events_url: "https://forge.test/api/v3/users/octocat/events{/privacy}",
      followers_url: "https://forge.test/api/v3/users/octocat/followers",
      following_url: "https://forge.test/api/v3/users/octocat/following{/other_user}",
      gists_url: "https://forge.test/api/v3/users/octocat/gists{/gist_id}",
      gravatar_id: nil,
      html_url: "https://forge.test/octocat",
      id: 41,
      login: "octocat",
      node_id: "VXNlcjo0MQ",
      organizations_url: "https://forge.test/api/v3/users/octocat/orgs",
      received_events_url: "https://forge.test/api/v3/users/octocat/received_events",
      repos_url: "https://forge.test/api/v3/users/octocat/repos",
      site_admin: false,
      starred_url: "https://forge.test/api/v3/users/octocat/starred{/owner}{/repo}",
      subscriptions_url: "https://forge.test/api/v3/users/octocat/subscriptions",
      type: "User",
      url: "https://forge.test/api/v3/users/octocat"
    }
  end

  defp issue_reactions do
    %{
      "+1": 0,
      "-1": 0,
      laugh: 0,
      confused: 0,
      heart: 0,
      hooray: 0,
      rocket: 0,
      eyes: 0,
      url: "https://forge.test/api/v3/repos/acme/widget/issues/7/reactions",
      total_count: 0
    }
  end

  defp comment_reactions do
    %{
      issue_reactions()
      | url: "https://forge.test/api/v3/repos/acme/widget/issues/comments/3101/reactions"
    }
  end

  defp maybe_put_pull_request(issue, nil), do: issue

  defp maybe_put_pull_request(issue, pull_request),
    do: Map.put(issue, :pull_request, pull_request)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, entry} -> {to_string(key), stringify_keys(entry)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
