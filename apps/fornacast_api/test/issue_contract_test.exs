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

      rendered = Serializer.render(version, :issue, issue, opts)

      assert rendered.url == "https://forge.test/api/v3/repos/acme/widget/issues/7"
      assert rendered.html_url == rendered.url
      assert rendered.node_id == "SXNzdWU6MzAwMQ"
      assert rendered.pull_request.merged_at == nil
      assert rendered.user == simple_user()
      assert rendered.labels == [Serializer.render(version, :label, label(), opts)]
      assert Serializer.render(version, :issue_comment, comment, opts).issue_url == rendered.url
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
      labels: [label()],
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
end
