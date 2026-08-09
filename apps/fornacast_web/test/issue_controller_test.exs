defmodule FornacastWeb.IssueControllerTestCollaborationPage do
  alias FornacastWeb.RepositoryPage

  def reset do
    Process.put({__MODULE__, :calls}, [])
    Process.put({__MODULE__, :responses}, %{})
  end

  def calls, do: Process.get({__MODULE__, :calls}, [])

  def respond(operation, response) do
    responses = Process.get({__MODULE__, :responses}, %{})
    Process.put({__MODULE__, :responses}, Map.put(responses, operation, response))
  end

  def decorate(result), do: result

  def issues(repository, owner, viewer, filters, opts) do
    reply(:issues, [repository, owner, viewer, filters, opts], fn ->
      issue = issue(1, "Public issue")
      page = %Fornacast.Page{entries: [issue], total: 65, page: filters.page, per_page: 30}

      {:ok,
       %RepositoryPage.Result{
         kind: :issues,
         chrome: chrome(repository, owner, viewer),
         content: %{issues: page, filters: filters}
       }}
    end)
  end

  def issue(repository, owner, viewer, number, opts) do
    reply(:issue, [repository, owner, viewer, number, opts], fn ->
      issue = issue(number, "Issue #{number}")
      comments = %Fornacast.Page{entries: [], total: 0, page: 1, per_page: 100}

      {:ok,
       %RepositoryPage.Result{
         kind: :issue,
         chrome: chrome(repository, owner, viewer),
         content: %{issue: issue, comments: comments}
       }}
    end)
  end

  def result(repository, owner, viewer, issue) do
    %RepositoryPage.Result{
      kind: :issue,
      chrome: chrome(repository, owner, viewer),
      content: %{
        issue: issue,
        comments: %Fornacast.Page{entries: [], total: 0, page: 1, per_page: 100}
      }
    }
  end

  def issue(number, title, kind \\ :issue) do
    %ForgeIssues.Issue{
      id: number,
      number: number,
      kind: kind,
      title: title,
      body: "Body <script>unsafe()</script>",
      state: :open,
      author: %{username: "alice"},
      labels: [%{name: "bug", color: "d73a4a"}],
      assignees: [],
      comment_count: 0,
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

  defp reply(operation, args, fallback) do
    Process.put({__MODULE__, :calls}, calls() ++ [{operation, args}])
    Map.get(Process.get({__MODULE__, :responses}, %{}), operation, fallback).()
  end

  defp chrome(repository, owner, viewer) do
    %RepositoryPage.Chrome{
      owner: owner,
      repository: repository,
      viewer: viewer,
      ref_summary: %GitCore.RefSummary{
        branch_count: 1,
        tag_count: 0,
        branches: [],
        tags: [],
        refs_truncated: false
      },
      snapshot: nil,
      clone: %RepositoryPage.Clone{
        https_url: "https://forge.test/#{owner.username}/#{repository.slug}.git"
      },
      collaboration_counts: %{issues: 4, pull_requests: 2}
    }
  end
end

defmodule FornacastWeb.IssueControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.IssueControllerTestCollaborationPage, as: TestPage

  @endpoint FornacastWeb.Endpoint

  setup do
    reset_database!()
    Fornacast.Setup.force_initialized!()
    TestPage.reset()

    alice = insert_user!("alice")
    public = insert_repository!(alice, "public-repo", :public)
    private = insert_repository!(alice, "private-repo", :private)
    disabled = insert_repository!(alice, "disabled-repo", :public, false)

    on_exit(&Fornacast.Setup.reset!/0)
    %{alice: alice, public: public, private: private, disabled: disabled}
  end

  test "anonymous readers list ordinary issues with allowlisted filters and preserved pagination" do
    query =
      URI.encode_query(%{
        "page" => "2",
        "state" => "closed",
        "labels" => "bug,help wanted",
        "assignee" => "none",
        "creator" => "alice",
        "sort" => "comments",
        "direction" => "asc"
      })

    conn = request_conn() |> get("/alice/public-repo/issues?#{query}")

    assert html_response(conn, 200) =~ "data-issues-page"
    assert conn.resp_body =~ "data-issue-row"
    assert conn.resp_body =~ ~r/65\s+issues/
    assert conn.resp_body =~ ~r/>\s*4\s*</
    assert conn.resp_body =~ "page=3"
    assert conn.resp_body =~ "state=closed"
    assert conn.resp_body =~ "labels=bug%2Chelp+wanted"
    assert_private_no_store(conn)

    assert [{:issues, [_repository, _owner, nil, filters, []]}] = TestPage.calls()

    assert filters == %{
             kind: :issue,
             page: 2,
             per_page: 30,
             state: :closed,
             labels: "bug,help wanted",
             assignee: "none",
             creator: "alice",
             sort: :comments,
             direction: :asc
           }
  end

  test "anonymous readers can view a public ordinary issue with sanitized content" do
    conn = request_conn() |> get("/alice/public-repo/issues/7")

    assert html_response(conn, 200) =~ "data-issue-conversation"
    assert conn.resp_body =~ "Issue 7"
    refute conn.resp_body =~ "<script>"
    assert [{:issue, [_repository, _owner, nil, 7, []]}] = TestPage.calls()
    assert_private_no_store(conn)
  end

  test "private repositories and missing repositories share the masked 404" do
    private = request_conn() |> get("/alice/private-repo/issues")
    missing = request_conn() |> get("/alice/missing-repo/issues")

    assert private.status == 404
    assert missing.status == 404
    assert masked_body(private.resp_body) == masked_body(missing.resp_body)
    refute private.resp_body =~ "private-repo"
    assert TestPage.calls() == []
  end

  test "disabled issue reads return 410 before domain composition" do
    assert (request_conn() |> get("/alice/disabled-repo/issues")).status == 410
    assert (request_conn() |> get("/alice/disabled-repo/issues/1")).status == 410
    assert TestPage.calls() == []
  end

  test "invalid pages and numbers return 404 while invalid filters return 422" do
    assert (request_conn() |> get("/alice/public-repo/issues?page=0")).status == 404
    assert (request_conn() |> get("/alice/public-repo/issues/nope")).status == 404
    assert (request_conn() |> get("/alice/public-repo/issues?state=merged")).status == 422
    assert (request_conn() |> get("/alice/public-repo/issues?unknown=value")).status == 422
    assert TestPage.calls() == []
  end

  test "pull-backed canonical issues redirect to the pull request detail", context do
    TestPage.respond(:issue, fn ->
      issue = TestPage.issue(9, "Pull-backed issue", :pull_request)
      {:ok, TestPage.result(context.public, context.alice, nil, issue)}
    end)

    conn = request_conn() |> get("/alice/public-repo/issues/9")
    assert redirected_to(conn) == "/alice/public-repo/pulls/9"
    assert_private_no_store(conn)
  end

  defp request_conn do
    build_conn()
    |> Plug.Conn.put_private(:repository_collaboration_page, TestPage)
  end

  defp assert_private_no_store(conn) do
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp masked_body(body), do: Regex.replace(~r/content="[^"]+"/, body, "content=\"token\"")

  defp insert_user!(username) do
    Fornacast.Repo.insert!(%User{
      username: username,
      email: "#{username}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp insert_repository!(owner, slug, visibility, has_issues \\ true) do
    Fornacast.Repo.insert!(%Repository{
      owner_user_id: owner.id,
      slug: slug,
      name: String.replace(slug, "-", " "),
      visibility: visibility,
      storage_path: "@test/#{slug}.git",
      default_branch: "main",
      has_issues: has_issues
    })
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(
          [
            "audit_events",
            "pull_requests",
            "issue_comments",
            "issue_assignees",
            "issue_labels",
            "issues",
            "repository_labels",
            "repository_collaborators",
            "repositories",
            "organization_members",
            "api_keys",
            "ssh_keys",
            "users"
          ],
          &Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{&1}", [])
        )
    end
  end
end
