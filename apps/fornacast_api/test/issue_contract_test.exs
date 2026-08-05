defmodule FornacastAPI.IssueContractTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.User
  alias ForgeIssues.{Comment, Issue, Label}
  alias FornacastAPI.{IssueContract, RequestValidator, Serializer}

  @versions ["2022-11-28", "2026-03-10"]

  setup do
    previous_base_url = Application.fetch_env!(:fornacast, :base_url)
    Application.put_env(:fornacast, :base_url, "https://forge.test")
    on_exit(fn -> Application.put_env(:fornacast, :base_url, previous_base_url) end)
  end

  test "validates issue mutations explicitly for both versions" do
    for version <- @versions do
      assert {:ok, %{"title" => "API issue"}} =
               RequestValidator.validate(version, :issue_create, %{"title" => "API issue"})

      assert {:error, {:validation, [%{resource: "Issue", field: "title", code: :missing_field}]}} =
               RequestValidator.validate(version, :issue_create, %{})

      assert {:error, {:validation, [%{resource: "Issue", field: "labels", code: :invalid}]}} =
               RequestValidator.validate(version, :issue_update, %{"labels" => [%{"name" => 1}]})

      assert {:error, {:validation, [%{resource: "Issue", field: "extra", code: :unprocessable}]}} =
               RequestValidator.validate(version, :issue_comment_create, %{
                 "body" => "ok",
                 "extra" => true
               })
    end
  end

  test "parses issue and comment filters independently" do
    assert {:ok, filters} =
             IssueContract.list_filters(%{
               "labels" => "bug, api",
               "state" => "all",
               "since" => "2026-07-21T00:00:00Z",
               "ignored" => "yes"
             })

    assert filters == [
             page: 1,
             per_page: 30,
             state: :all,
             labels: ["bug", "api"],
             assignee: nil,
             creator: nil,
             sort: :created,
             direction: :desc,
             since: ~U[2026-07-21 00:00:00Z]
           ]

    assert {:ok, [page: 1, per_page: 30, since: nil]} = IssueContract.comment_filters(%{})

    assert {:error, {:validation, [%{resource: "Issue", field: "labels", code: :unprocessable}]}} =
             IssueContract.list_filters(%{
               "labels" => Enum.join(List.duplicate("label", 101), ",")
             })
  end

  test "renders complete pinned issue resources" do
    for version <- @versions do
      issue = issue()
      comment = comment()

      opts = [
        owner: "acme",
        repo: "widget",
        issue_number: 7,
        pull_links_by_issue_id: %{3001 => %{merged_at: nil}}
      ]

      expected_issue = expected_issue(nil)
      expected_pull = expected_issue(expected_pull_link())
      expected_comment = expected_comment()

      assert Serializer.render(version, :issue, %{issue | kind: :issue}, opts) == expected_issue
      assert Serializer.render(version, :issue, issue, opts) == expected_pull
      assert Serializer.render(version, :issue_comment, comment, opts) == expected_comment
      assert Serializer.render(version, :label, label(), opts) == expected_label()

      assert_fixtures(version, expected_issue, expected_pull, expected_comment)
    end
  end

  defp issue do
    %Issue{
      id: 3001,
      number: 7,
      kind: :pull_request,
      title: "API issue",
      body: "Track compatibility",
      state: :open,
      author: author(),
      labels: [],
      assignees: [],
      comment_count: 0,
      author_association: "NONE",
      inserted_at: ~U[2026-07-21 00:00:00Z],
      updated_at: ~U[2026-07-21 00:00:00Z]
    }
  end

  defp comment do
    %Comment{
      id: 3101,
      issue_id: 3001,
      body: "First comment",
      author: author(),
      author_association: "NONE",
      inserted_at: ~U[2026-07-21 00:00:00Z],
      updated_at: ~U[2026-07-21 00:00:00Z]
    }
  end

  defp label, do: %Label{id: 3201, name: "bug", color: "ff0000", default: false, description: nil}
  defp author, do: %User{id: 41, username: "octocat", kind: :user, role: :user}

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

  defp expected_issue(pull_request) do
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
      reactions: reactions(),
      timeline_url: url <> "/timeline",
      performed_via_github_app: nil,
      state_reason: nil
    }
    |> maybe_pull(pull_request)
  end

  defp expected_pull_link do
    url = "https://forge.test/api/v3/repos/acme/widget/pulls/7"
    %{url: url, html_url: url, diff_url: url, patch_url: url, merged_at: nil}
  end

  defp expected_comment do
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

  defp expected_label,
    do: %{
      id: 3201,
      node_id: "TGFiZWw6MzIwMQ",
      url: "https://forge.test/api/v3/repos/acme/widget/labels/bug",
      name: "bug",
      color: "ff0000",
      default: false,
      description: nil
    }

  defp maybe_pull(map, nil), do: map
  defp maybe_pull(map, value), do: Map.put(map, :pull_request, value)

  defp reactions,
    do: %{
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

  defp comment_reactions do
    %{
      reactions()
      | url: "https://forge.test/api/v3/repos/acme/widget/issues/comments/3101/reactions"
    }
  end

  defp assert_fixtures(version, issue, pull, comment) do
    root = Path.join([Path.expand("fixtures", __DIR__), version, "issues"])

    expected = %{
      "issue.json" => issue,
      "pull-issue.json" => pull,
      "issue-comment.json" => comment,
      "issue-list.json" => [issue],
      "issue-comment-list.json" => [comment]
    }

    for {filename, literal} <- expected do
      bytes = File.read!(Path.join(root, filename))
      assert JSON.decode!(bytes) == JSON.decode!(JSON.encode!(literal))
    end
  end
end
