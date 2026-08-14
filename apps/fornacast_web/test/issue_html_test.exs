defmodule FornacastWeb.IssueHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.{IssueHTML, RepositoryPage}

  test "issue list is a dense filtered repository page with one active Issues tab" do
    issue = %{issue(7, "Keep the list dense") | state: :closed}

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
    [issue_row] = Regex.run(~r/<li\b[^>]*data-issue-row.*?<\/li>/s, html)
    assert issue_row =~ ~r/>\s*closed\s*</
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
    assert html =~ ~s(id="issuecomment-1")
    assert html =~ ~s(id="issuecomment-2")
    refute html =~ "<script"
    refute html =~ "onerror"
    assert byte_index(html, "first <strong>") < byte_index(html, "chronological second")

    [navigation] = Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, html)
    assert length(Regex.scan(~r/aria-current="page"/, navigation)) == 1
    refute html =~ "data-repository-toolbar"
  end

  test "new form uses DuskMoon fields, CSRF, relationship options, and field errors" do
    result =
      result(:issues, %{
        issue: nil,
        options: form_options(true),
        values: %{
          "title" => "Retained title",
          "body" => "Retained body",
          "labels" => ["bug"],
          "assignees" => ["bob"]
        },
        errors: [
          %{resource: "Issue", field: "title", code: :invalid},
          %{resource: "Issue", field: "base", code: :unprocessable}
        ]
      })

    html = render_component(&IssueHTML.new/1, result: result)

    assert html =~ "data-issue-form"
    assert html =~ ~s(name="_csrf_token")
    assert html =~ ~s(name="issue[title]")
    assert html =~ ~s(name="issue[body]")
    assert html =~ ~s(name="issue[labels][]")
    assert html =~ ~s(name="issue[assignees][]")
    assert html =~ ~r/<option[^>]*value="bug"[^>]*selected/
    assert html =~ ~r/<option[^>]*value="bob"[^>]*selected/
    assert html =~ "Retained title"
    assert html =~ "Retained body"
    assert label_text(html, "issue-title") == "Title"
    assert label_text(html, "issue-body") == "Body"
    assert label_text(html, "issue-labels") == "Labels"
    assert label_text(html, "issue-assignees") == "Assignees"
    assert html =~ "Title is invalid"
    assert html =~ "The issue could not be processed"
    assert length(Regex.scan(~r/aria-current="page"/, navigation(html))) == 1
    assert primary_action_count(html) == 1
  end

  test "non-writer author edit form omits relationship controls and uses PATCH override" do
    author_issue = put_in(issue(7, "Author issue").capabilities.can_edit, true)

    result =
      result(:issue, %{
        issue: author_issue,
        options: form_options(false),
        values: %{"title" => "Author issue", "body" => "Body"},
        errors: []
      })

    html = render_component(&IssueHTML.edit/1, result: result)

    assert html =~ "data-issue-form"
    assert html =~ ~s(name="_method" value="patch")
    assert html =~ ~s(name="_csrf_token")
    refute html =~ ~s(name="issue[labels][]")
    refute html =~ ~s(name="issue[assignees][]")
  end

  test "conversation actions are visible only from issue and comment capabilities" do
    issue =
      issue(7, "Actionable")
      |> put_in([Access.key(:capabilities), :can_edit], true)
      |> put_in([Access.key(:capabilities), :can_close], true)
      |> put_in([Access.key(:capabilities), :can_comment], true)

    first_editable =
      comment(1, "editable", ~U[2026-08-09 08:01:00Z])
      |> put_in([Access.key(:capabilities), :can_edit], true)
      |> put_in([Access.key(:capabilities), :can_delete], true)

    second_editable =
      comment(2, "second original", ~U[2026-08-09 08:02:00Z])
      |> put_in([Access.key(:capabilities), :can_edit], true)

    content = %{
      issue: issue,
      comments: %Fornacast.Page{
        entries: [first_editable, second_editable],
        total: 2,
        page: 1,
        per_page: 100
      },
      comment_form: %{
        operation: {:edit, "1"},
        values: %{"body" => "Retained edit"},
        errors: [%{resource: "IssueComment", field: "body", code: :invalid}]
      }
    }

    html = render_component(&IssueHTML.show/1, result: result(:issue, content))

    assert html =~ ~s(href="/alice/demo/issues/7/edit")
    assert html =~ ~s(action="/alice/demo/issues/7/state")
    assert html =~ ~s(action="/alice/demo/issues/7/comments")
    assert html =~ ~s(action="/alice/demo/issues/7/comments/1")
    assert html =~ ~s(name="comment[body]")
    assert textarea_body(html, "issue-comment-1") =~ "Retained edit"
    assert textarea_body(html, "issue-comment-2") =~ "second original"
    assert textarea_body(html, "issue-comment-body") == ""
    assert html =~ "Body is invalid"
    assert primary_action_count(html) <= 1

    create_html =
      render_component(&IssueHTML.show/1,
        result:
          result(:issue, %{
            content
            | comment_form: %{
                operation: :create,
                values: %{"body" => "Retained creation"},
                errors: [%{resource: "IssueComment", field: "base", code: :unprocessable}]
              }
          })
      )

    assert textarea_body(create_html, "issue-comment-1") =~ "editable"
    assert textarea_body(create_html, "issue-comment-2") =~ "second original"
    assert textarea_body(create_html, "issue-comment-body") =~ "Retained creation"
    assert create_html =~ "The comment could not be processed"

    hidden_issue = issue(8, "Read only")

    hidden =
      render_component(&IssueHTML.show/1,
        result:
          result(:issue, %{
            issue: hidden_issue,
            comments: %Fornacast.Page{
              entries: [comment(2, "read only", ~U[2026-08-09 08:02:00Z])],
              total: 1,
              page: 1,
              per_page: 100
            }
          })
      )

    refute hidden =~ "/edit"
    refute hidden =~ "/state"
    refute hidden =~ "/comments"
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

  defp textarea_body(html, id) do
    [_, body] =
      Regex.run(~r/<textarea[^>]*id="#{Regex.escape(id)}"[^>]*>(.*?)<\/textarea>/s, html)

    body
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

  defp form_options(can_manage_relationships) do
    %{
      labels: [%{name: "bug", normalized_name: "bug"}],
      assignees: [%{username: "bob"}],
      capabilities: %{
        can_create: true,
        can_comment: true,
        can_edit: true,
        can_close: true,
        can_manage_relationships: can_manage_relationships
      }
    }
  end

  defp navigation(html) do
    [navigation] = Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, html)
    navigation
  end

  defp byte_index(text, pattern) do
    {index, _length} = :binary.match(text, pattern)
    index
  end

  defp primary_action_count(html) do
    elements = Regex.scan(~r/<el-dm-button\b[^>]*variant="primary"[^>]*>/, html)
    links = Regex.scan(~r/<(?:a|button)\b[^>]*class="[^"]*\bbtn-primary\b[^"]*"[^>]*>/, html)

    Enum.count(elements, fn [element] -> primary_color?(element) end) + length(links)
  end

  defp primary_color?(element), do: not String.contains?(element, "--color-primary:")

  defp label_text(html, id) do
    [_, content] =
      Regex.run(~r/<label\b[^>]*for="#{Regex.escape(id)}"[^>]*>(.*?)<\/label>/s, html)

    content
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end
end
