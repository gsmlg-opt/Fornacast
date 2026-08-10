defmodule FornacastWeb.PullRequestHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.{PullRequestHTML, RepositoryPage}

  test "pull list is dense, filterable, paginated, and identifies branch direction" do
    pull = pull(7, "Ship comparison", :closed)

    result =
      result(:pulls, %{
        pulls: %Fornacast.Page{entries: [pull], total: 61, page: 2, per_page: 30},
        filters: %{
          page: 2,
          per_page: 30,
          state: :closed,
          head: "alice:feature",
          base: "main",
          sort: :popularity,
          direction: :asc
        }
      })

    html = render_component(&PullRequestHTML.index/1, result: result)

    assert html =~ "data-pulls-page"
    assert html =~ "data-pull-filters"
    assert html =~ "data-pull-row"
    assert html =~ "Ship comparison"
    assert html =~ "feature"
    assert html =~ "main"
    assert html =~ "closed"
    assert html =~ "page=3"
    assert html =~ "head=alice%3Afeature"
    assert html =~ "base=main"
    assert length(Regex.scan(~r/aria-current="page"/, navigation(html))) == 1
    assert navigation(html) =~ ~r/aria-current="page"[^>]*>.*Pull Requests/s
  end

  test "pull list renders an explicit empty state" do
    result =
      result(:pulls, %{
        pulls: %Fornacast.Page{entries: [], total: 0, page: 1, per_page: 30},
        filters: default_filters()
      })

    html = render_component(&PullRequestHTML.index/1, result: result)
    assert html =~ "No pull requests"
    assert html =~ "No pull requests match these filters."
  end

  test "long-running sort round-trips through filters and pagination" do
    filters = %{default_filters() | sort: :long_running, direction: :asc}

    result =
      result(:pulls, %{
        pulls: %Fornacast.Page{entries: [], total: 61, page: 2, per_page: 30},
        filters: filters
      })

    html = render_component(&PullRequestHTML.index/1, result: result)

    assert html =~ ~r/<option[^>]*value="long-running"[^>]*selected/
    assert html =~ "sort=long-running"
    refute html =~ "sort=long_running"
  end

  test "new form uses DuskMoon branch selects in deterministic order with default base" do
    values = %{"title" => "", "body" => "", "head" => "", "base" => "main"}

    html =
      render_component(&PullRequestHTML.new/1,
        result: result(:pulls, new_content(values, nil, []))
      )

    assert html =~ "data-pull-form"
    assert html =~ ~s(name="_csrf_token")
    assert html =~ ~s(name="pull[title]")
    assert html =~ ~s(name="pull[body]")
    assert html =~ ~s(name="pull[head]")
    assert html =~ ~s(name="pull[base]")
    assert html =~ ~r/<option[^>]*value="main"[^>]*selected/
    assert byte_index(html, ~r/>\s*feature\s*</) < byte_index(html, ~r/>\s*main\s*</)
    assert byte_index(html, ~r/>\s*main\s*</) < byte_index(html, ~r/>\s*release\s*</)
    assert length(Regex.scan(~r/variant="primary"|btn-primary/, html)) == 1
    refute html =~ "data-pull-compare"
  end

  test "comparison renders counts and conflict preview" do
    comparison = %ForgePulls.Comparison{
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_oid: String.duplicate("a", 40),
      base_oid: String.duplicate("b", 40),
      analysis: analysis(false)
    }

    html =
      render_component(&PullRequestHTML.new/1,
        result:
          result(
            :pulls,
            new_content(%{"head" => "feature", "base" => "main"}, comparison, [])
          )
      )

    assert html =~ "data-pull-compare"
    assert html =~ ~r/3<\/span>\s+ahead/
    assert html =~ ~r/1<\/span>\s+behind/
    assert html =~ ~r/3<\/span>\s+commits/
    assert html =~ ~r/4<\/span>\s+files/
    assert html =~ "conflict"
  end

  test "creation form retains safe values and projects field and resource errors" do
    errors = [
      %{resource: "PullRequest", field: "title", code: :invalid},
      %{resource: "PullRequest", field: "base", code: :unprocessable},
      %{resource: "PullRequest", field: "base", code: :custom, message: "Choose another base"}
    ]

    values = %{
      "title" => "Retained title",
      "body" => "Retained body",
      "head" => "feature",
      "base" => "main"
    }

    html =
      render_component(&PullRequestHTML.new/1,
        result: result(:pulls, new_content(values, nil, errors))
      )

    assert html =~ "Retained title"
    assert html =~ "Retained body"
    assert html =~ "Title is invalid"
    assert html =~ "Base could not be processed"
    assert html =~ "Choose another base"
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
        viewer: owner,
        ref_summary: %GitCore.RefSummary{
          branch_count: 3,
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

  defp new_content(values, comparison, errors) do
    %{
      pulls: %Fornacast.Page{entries: [], total: 0, page: 1, per_page: 30},
      filters: default_filters(),
      branches: [
        ref("refs/heads/feature", "feature"),
        ref("refs/heads/main", "main"),
        ref("refs/heads/release", "release")
      ],
      comparison: comparison,
      values: values,
      errors: errors
    }
  end

  defp pull(number, title, state) do
    issue = %ForgeIssues.Issue{
      id: number,
      number: number,
      kind: :pull_request,
      title: title,
      body: "Body",
      state: state,
      author: %{username: "alice"},
      labels: [],
      assignees: [],
      comment_count: 2,
      capabilities: %{},
      inserted_at: ~U[2026-08-09 08:00:00Z],
      updated_at: ~U[2026-08-09 08:00:00Z]
    }

    %ForgePulls.PullRequest{
      id: number,
      issue_id: number,
      repository_id: 1,
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40),
      issue: issue,
      analysis: analysis(true),
      capabilities: %{}
    }
  end

  defp ref(name, display_name),
    do: %GitCore.Ref{name: name, display_name: display_name, kind: :branch, target: "target"}

  defp analysis(mergeable) do
    %GitCore.MergeAnalysis{
      base_oid: String.duplicate("b", 40),
      head_oid: String.duplicate("a", 40),
      mergeable: mergeable,
      ahead_by: 3,
      behind_by: 1,
      commit_count: 3,
      changed_paths: 4
    }
  end

  defp default_filters do
    %{
      page: 1,
      per_page: 30,
      state: :open,
      head: nil,
      base: nil,
      sort: :created,
      direction: :desc
    }
  end

  defp navigation(html) do
    [navigation] = Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, html)
    navigation
  end

  defp byte_index(string, pattern) do
    {index, _length} = Regex.run(pattern, string, return: :index) |> hd()
    index
  end
end
