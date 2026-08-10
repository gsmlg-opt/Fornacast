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

  test "conversation renders canonical sanitized content, navigation, analysis, and capability actions" do
    pull =
      pull(7, "Review safely", :open,
        body: "Body <script>unsafe body</script>",
        capabilities: %{can_close: true, can_comment: true, can_merge: true}
      )

    comments = %Fornacast.Page{
      entries: [comment(1, "Comment **safe** <script>unsafe comment</script>")],
      total: 1,
      page: 1,
      per_page: 100
    }

    html =
      render_component(&PullRequestHTML.show/1,
        result: result(:pull, %{pull: pull, comments: comments})
      )

    assert html =~ "data-pull-conversation"
    assert html =~ "data-merge-box"
    assert html =~ "feature"
    assert html =~ "main"
    assert html =~ "3 commits"
    assert html =~ "4 files"
    assert html =~ "Comment <strong>safe</strong>"
    assert html =~ ~s(action="/alice/demo/issues/7/comments")
    assert html =~ ~s(action="/alice/demo/pulls/7/state")
    assert html =~ ~s(action="/alice/demo/pulls/7/merge")
    assert html =~ ~s(name="sha" value="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    refute html =~ "<script>"

    nav = pull_navigation(html)
    assert byte_index(nav, ~r/>\s*Conversation\s*</) < byte_index(nav, ~r/>\s*Commits\s*</)
    assert byte_index(nav, ~r/>\s*Commits\s*</) < byte_index(nav, ~r/>\s*Files changed\s*</)
    assert length(Regex.scan(~r/aria-current="page"/, nav)) == 1
  end

  test "merged, closed, and non-writer conversations use only domain capabilities" do
    merged =
      pull(7, "Merged", :closed,
        merged_at: ~U[2026-08-09 09:00:00Z],
        merge_commit_sha: String.duplicate("c", 40),
        capabilities: %{can_close: false, can_comment: false, can_merge: false}
      )

    merged_html =
      render_component(&PullRequestHTML.show/1,
        result: result(:pull, %{pull: merged, comments: empty_comments()})
      )

    assert merged_html =~ "Merged"
    assert merged_html =~ String.duplicate("c", 40)
    refute merged_html =~ ~s(action="/alice/demo/pulls/7/merge")
    refute merged_html =~ ~s(action="/alice/demo/pulls/7/state")

    closed =
      pull(8, "Closed", :closed,
        capabilities: %{can_close: true, can_comment: false, can_merge: false}
      )

    closed_html =
      render_component(&PullRequestHTML.show/1,
        result: result(:pull, %{pull: closed, comments: empty_comments()})
      )

    assert closed_html =~ "Reopen"
    assert closed_html =~ ~s(action="/alice/demo/pulls/8/state")
    refute closed_html =~ ~s(action="/alice/demo/pulls/8/merge")

    reader =
      pull(9, "Reader", :open,
        capabilities: %{can_close: false, can_comment: false, can_merge: false}
      )

    reader_html =
      render_component(&PullRequestHTML.show/1,
        result: result(:pull, %{pull: reader, comments: empty_comments()})
      )

    refute reader_html =~ ~s(action="/alice/demo/pulls/9/state")
    refute reader_html =~ ~s(action="/alice/demo/pulls/9/merge")
    refute reader_html =~ ~s(action="/alice/demo/issues/9/comments")
  end

  test "commits use a DuskMoon table, escape authored text, and paginate" do
    commits = %Fornacast.Page{
      entries: [commit("abc123", "Safe <script>commit</script>")],
      total: 101,
      page: 2,
      per_page: 50
    }

    html =
      render_component(&PullRequestHTML.commits/1,
        result: result(:pull_commits, %{pull: pull(7, "Commits", :open), commits: commits})
      )

    assert html =~ "data-pull-commits"
    assert html =~ "abc123"
    assert html =~ "Safe &lt;script&gt;commit&lt;/script&gt;"
    refute html =~ "<script>commit</script>"
    assert html =~ "page=3"
    assert length(Regex.scan(~r/aria-current="page"/, pull_navigation(html))) == 1
  end

  test "files map typed aggregate, truncation, binary, and escaped diff data" do
    files = %ForgePulls.ChangedFilePage{
      entries: [changed_file(), binary_file()],
      total: 102,
      additions: 14,
      deletions: 9,
      page: 2,
      per_page: 100,
      truncated: true
    }

    html =
      render_component(&PullRequestHTML.files/1,
        result: result(:pull_files, %{pull: pull(7, "Files", :open), files: files})
      )

    assert html =~ "data-pull-files"
    assert html =~ "data-pull-diff"
    assert html =~ "102"
    assert html =~ "14"
    assert html =~ "9"
    assert html =~ "truncated"
    assert html =~ "lib/changed.ex"
    assert html =~ "priv/logo.bin"
    assert html =~ "modified"
    assert html =~ "binary"
    assert html =~ "&lt;script&gt;unsafe diff&lt;/script&gt;"
    refute html =~ "<script>unsafe diff</script>"
    assert html =~ "page=1"
    assert length(Regex.scan(~r/aria-current="page"/, pull_navigation(html))) == 1
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

  defp pull(number, title, state, opts \\ []) do
    issue = %ForgeIssues.Issue{
      id: number,
      number: number,
      kind: :pull_request,
      title: title,
      body: Keyword.get(opts, :body, "Body"),
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
      merged_at: Keyword.get(opts, :merged_at),
      merge_commit_sha: Keyword.get(opts, :merge_commit_sha),
      issue: issue,
      analysis: analysis(true),
      capabilities:
        Keyword.get(opts, :capabilities, %{can_close: false, can_comment: false, can_merge: false})
    }
  end

  defp comment(id, body) do
    %ForgeIssues.Comment{
      id: id,
      issue_id: 7,
      issue_number: 7,
      author_user_id: 2,
      author: %{username: "bob"},
      author_association: "CONTRIBUTOR",
      body: body,
      capabilities: %{can_edit: false, can_delete: false},
      inserted_at: ~U[2026-08-09 08:01:00Z],
      updated_at: ~U[2026-08-09 08:01:00Z]
    }
  end

  defp empty_comments,
    do: %Fornacast.Page{entries: [], total: 0, page: 1, per_page: 100}

  defp commit(oid, title) do
    %GitCore.Commit{
      oid: oid,
      title: title,
      message: "Message <script>unsafe</script>",
      author_name: "Alice <script>",
      author_email: "alice@example.test",
      author_time: 1_754_723_200,
      committer_name: "Alice",
      committer_email: "alice@example.test",
      committer_time: 1_754_723_200,
      parents: []
    }
  end

  defp changed_file do
    %GitCore.DiffFile{
      path: "lib/changed.ex",
      status: :modified,
      old_oid: String.duplicate("1", 40),
      new_oid: String.duplicate("2", 40),
      binary: false,
      additions: 4,
      deletions: 2,
      truncated: true,
      lines: [
        %GitCore.DiffLine{
          type: :added,
          old_line: nil,
          new_line: 1,
          content: "<script>unsafe diff</script>"
        }
      ]
    }
  end

  defp binary_file do
    %GitCore.DiffFile{
      path: "priv/logo.bin",
      status: :added,
      old_oid: nil,
      new_oid: String.duplicate("3", 40),
      binary: true,
      additions: 0,
      deletions: 0,
      truncated: false,
      lines: []
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

  defp pull_navigation(html) do
    [navigation] = Regex.run(~r/<nav\b[^>]*aria-label="Pull request navigation".*?<\/nav>/s, html)
    navigation
  end

  defp byte_index(string, pattern) do
    {index, _length} = Regex.run(pattern, string, return: :index) |> hd()
    index
  end
end
