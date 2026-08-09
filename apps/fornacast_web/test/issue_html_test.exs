defmodule FornacastWeb.IssueHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.{IssueHTML, RepositoryPage}

  test "issue list is a dense filtered repository page with one active Issues tab" do
    issue = issue(7, "Keep the list dense")

    result =
      result(:issues, %{
        issues: %Fornacast.Page{entries: [issue], total: 65, page: 2, per_page: 30},
        filters: %{
          kind: :issue,
          page: 2,
          per_page: 30,
          state: :closed,
          labels: "bug",
          assignee: "none",
          creator: "alice",
          sort: :comments,
          direction: :asc
        }
      })

    html = render_component(&IssueHTML.index/1, result: result)

    assert html =~ "data-issues-page"
    assert html =~ "data-issue-filters"
    assert html =~ "data-issue-row"
    assert html =~ "Keep the list dense"
    assert html =~ "1 comment"
    assert html =~ "bug"
    assert html =~ "href=\"/alice/demo/issues/7\""
    assert html =~ "page=3"
    assert html =~ "state=closed"
    assert html =~ "labels=bug"
    [navigation] = Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, html)
    assert length(Regex.scan(~r/aria-current="page"/, navigation)) == 1
    assert navigation =~ ~r/aria-current="page"[^>]*>.*Issues/s
    refute html =~ "data-repository-toolbar"
  end

  test "issue list renders an explicit empty state" do
    result =
      result(:issues, %{
        issues: %Fornacast.Page{entries: [], total: 0, page: 1, per_page: 30},
        filters: default_filters()
      })

    html = render_component(&IssueHTML.index/1, result: result)
    assert html =~ "No issues"
    assert html =~ "No ordinary issues match these filters."
  end

  test "conversation sanitizes issue and chronological comment Markdown and shows counts" do
    issue = %{
      issue(7, "Sanitize the conversation")
      | body: "[safe](https://example.test) <script>x()</script>"
    }

    comments =
      %Fornacast.Page{
        entries: [
          comment(1, "first **comment**", ~U[2026-08-09 08:01:00Z]),
          comment(2, "chronological second <img src=x onerror=bad()>", ~U[2026-08-09 08:02:00Z])
        ],
        total: 2,
        page: 1,
        per_page: 100
      }

    html =
      render_component(&IssueHTML.show/1,
        result: result(:issue, %{issue: issue, comments: comments})
      )

    assert html =~ "data-issue-conversation"
    assert html =~ "Sanitize the conversation"
    assert html =~ ~s(href="https://example.test")
    assert html =~ "first <strong>comment</strong>"
    assert html =~ "chronological second"
    assert html =~ "2 comments"
    assert html =~ "alice"
    assert html =~ "bob"
    refute html =~ "<script"
    refute html =~ "onerror"
    assert byte_index(html, "first <strong>") < byte_index(html, "chronological second")

    [navigation] = Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, html)
    assert length(Regex.scan(~r/aria-current="page"/, navigation)) == 1
    refute html =~ "data-repository-toolbar"
  end

  defp result(kind, content) do
    owner = %User{id: 1, username: "alice", kind: :user, state: :active}

    repository = %Repository{
      id: 1,
      owner_user_id: owner.id,
      slug: "demo",
      name: "Demo",
      visibility: :public,
      storage_path: "@test/demo.git",
      default_branch: "main",
      has_issues: true
    }

    %RepositoryPage.Result{
      kind: kind,
      chrome: %RepositoryPage.Chrome{
        owner: owner,
        repository: repository,
        viewer: nil,
        ref_summary: %GitCore.RefSummary{
          branch_count: 1,
          tag_count: 0,
          branches: [],
          tags: [],
          refs_truncated: false
        },
        snapshot: nil,
        clone: %RepositoryPage.Clone{https_url: "https://forge.test/alice/demo.git"},
        collaboration_counts: %{issues: 4, pull_requests: 2}
      },
      content: content
    }
  end

  defp issue(number, title) do
    %ForgeIssues.Issue{
      id: number,
      number: number,
      kind: :issue,
      title: title,
      body: "Issue body",
      state: :open,
      author: %{username: "alice"},
      author_association: "OWNER",
      labels: [%{name: "bug", color: "d73a4a"}],
      assignees: [%{username: "bob"}],
      comment_count: 1,
      capabilities: %{
        can_create: false,
        can_comment: false,
        can_edit: false,
        can_close: false,
        can_manage_relationships: false
      },
      inserted_at: ~U[2026-08-09 08:00:00Z],
      updated_at: ~U[2026-08-09 08:00:00Z]
    }
  end

  defp comment(id, body, inserted_at) do
    %ForgeIssues.Comment{
      id: id,
      issue_id: 7,
      issue_number: 7,
      author_user_id: 2,
      author: %{username: "bob"},
      author_association: "CONTRIBUTOR",
      body: body,
      capabilities: %{can_edit: false, can_delete: false},
      inserted_at: inserted_at,
      updated_at: inserted_at
    }
  end

  defp default_filters do
    %{
      kind: :issue,
      page: 1,
      per_page: 30,
      state: :open,
      labels: "",
      assignee: nil,
      creator: nil,
      sort: :created,
      direction: :desc
    }
  end

  defp byte_index(text, pattern) do
    {index, _length} = :binary.match(text, pattern)
    index
  end
end
