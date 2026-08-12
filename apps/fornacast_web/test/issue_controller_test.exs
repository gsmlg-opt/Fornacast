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

  def pull(repository, owner, viewer, number, opts) do
    reply(:pull, [repository, owner, viewer, number, opts], fn ->
      {:ok, pull_result(repository, owner, viewer, number)}
    end)
  end

  def pull_result(repository, owner, viewer, number) do
    issue = issue(number, "Pull #{number}", :pull_request)

    pull = %ForgePulls.PullRequest{
      id: number,
      issue_id: number,
      repository_id: repository.id,
      head_ref: "refs/heads/feature",
      base_ref: "refs/heads/main",
      head_sha: String.duplicate("a", 40),
      base_sha: String.duplicate("b", 40),
      issue: issue,
      analysis: %GitCore.MergeAnalysis{
        base_oid: String.duplicate("b", 40),
        head_oid: String.duplicate("a", 40),
        mergeable: true,
        ahead_by: 1,
        behind_by: 0,
        commit_count: 1,
        changed_paths: 1
      },
      capabilities: %{can_close: false, can_comment: true, can_merge: false}
    }

    %RepositoryPage.Result{
      kind: :pull,
      chrome: chrome(repository, owner, viewer),
      content: %{
        pull: pull,
        comments: %Fornacast.Page{entries: [], total: 0, page: 1, per_page: 100}
      }
    }
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

defmodule FornacastWeb.IssueControllerTestIssues do
  def reset do
    Process.put({__MODULE__, :calls}, [])
    Process.put({__MODULE__, :responses}, %{})
  end

  def calls, do: Process.get({__MODULE__, :calls}, [])

  def respond(operation, response) do
    responses = Process.get({__MODULE__, :responses}, %{})
    Process.put({__MODULE__, :responses}, Map.put(responses, operation, response))
  end

  def form_options(actor, owner, repository, issue) do
    reply(:form_options, [actor, owner, repository, issue], fn _args ->
      {:ok,
       %{
         labels: [%{name: "bug", normalized_name: "bug"}],
         assignees: [%{username: "alice"}],
         capabilities: %{
           can_create: true,
           can_comment: true,
           can_edit: true,
           can_close: true,
           can_manage_relationships: true
         }
       }}
    end)
  end

  def get(actor, owner, repository, number) do
    reply(:get, [actor, owner, repository, number], fn _args ->
      {:ok, FornacastWeb.IssueControllerTestCollaborationPage.issue(number, "Issue #{number}")}
    end)
  end

  def get_comment(actor, owner, repository, id) do
    reply(:get_comment, [actor, owner, repository, id], fn _args ->
      {:ok,
       %ForgeIssues.Comment{
         id: id,
         issue_number: 7,
         body: "Existing comment",
         capabilities: %{can_edit: true, can_delete: true}
       }}
    end)
  end

  def create(actor, owner, repository, attrs, metadata),
    do:
      reply(:create, [actor, owner, repository, attrs, metadata], fn _args ->
        {:ok, FornacastWeb.IssueControllerTestCollaborationPage.issue(11, attrs["title"])}
      end)

  def update(actor, owner, repository, number, attrs, metadata),
    do:
      reply(:update, [actor, owner, repository, number, attrs, metadata], fn _args ->
        {:ok,
         FornacastWeb.IssueControllerTestCollaborationPage.issue(
           number,
           attrs["title"] || "Updated"
         )}
      end)

  def create_comment(actor, owner, repository, number, attrs, metadata),
    do:
      reply(:create_comment, [actor, owner, repository, number, attrs, metadata], fn _args ->
        {:ok, %ForgeIssues.Comment{id: 3, issue_number: number, body: attrs["body"]}}
      end)

  def update_comment(actor, owner, repository, id, attrs, metadata),
    do:
      reply(:update_comment, [actor, owner, repository, id, attrs, metadata], fn _args ->
        {:ok, %ForgeIssues.Comment{id: id, issue_number: 7, body: attrs["body"]}}
      end)

  def delete_comment(actor, owner, repository, id, metadata),
    do: reply(:delete_comment, [actor, owner, repository, id, metadata], fn _args -> :ok end)

  defp reply(operation, args, fallback) do
    Process.put({__MODULE__, :calls}, calls() ++ [{operation, args}])

    case Map.get(Process.get({__MODULE__, :responses}, %{}), operation) do
      nil -> fallback.(args)
      response when is_function(response, 1) -> response.(args)
      response -> response
    end
  end
end

defmodule FornacastWeb.IssueControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.IssueControllerTestCollaborationPage, as: TestPage
  alias FornacastWeb.IssueControllerTestIssues, as: TestIssues

  @endpoint FornacastWeb.Endpoint

  setup do
    reset_database!()
    Fornacast.Setup.force_initialized!()
    TestPage.reset()
    TestIssues.reset()

    alice = insert_user!("alice")
    bob = insert_user!("bob")
    public = insert_repository!(alice, "public-repo", :public)
    private = insert_repository!(alice, "private-repo", :private)
    disabled = insert_repository!(alice, "disabled-repo", :public, false)

    on_exit(&Fornacast.Setup.reset!/0)
    %{alice: alice, bob: bob, public: public, private: private, disabled: disabled}
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

  test "new and edit require sign-in with local encoded return targets" do
    new = request_conn() |> get("/alice/public-repo/issues/new?return_to=//evil.test")
    edit = request_conn() |> get("/alice/public-repo/issues/7/edit")

    hostile_owner =
      request_conn()
      |> get("/%2F%2Fevil.test/public-repo/issues/new")

    hostile_repository =
      request_conn()
      |> get("/alice/%2F%2Fevil.test/issues/7/edit")

    assert redirected_to(new) ==
             "/login?return_to=" <> URI.encode_www_form("/alice/public-repo/issues/new")

    assert redirected_to(edit) ==
             "/login?return_to=" <> URI.encode_www_form("/alice/public-repo/issues/7/edit")

    refute redirected_to(new) =~ "evil.test"

    assert login_return_to(hostile_owner) ==
             "/%2F%2Fevil.test/public-repo/issues/new"

    assert login_return_to(hostile_repository) ==
             "/alice/%2F%2Fevil.test/issues/7/edit"

    refute String.starts_with?(login_return_to(hostile_owner), "//")
    refute String.starts_with?(login_return_to(hostile_repository), "//")
  end

  test "reader sees a CSRF-protected new form and creates through one metadata-bearing mutation",
       %{
         bob: bob
       } do
    form = request_conn(bob) |> get("/alice/public-repo/issues/new")
    assert html_response(form, 200) =~ ~s(name="_csrf_token")
    assert form.resp_body =~ ~s(name="issue[title]")
    assert form.resp_body =~ ~s(name="issue[body]")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      request_conn(bob)
      |> with_production_csrf()
      |> post("/alice/public-repo/issues", %{"issue" => %{"title" => "No token"}})
    end

    TestIssues.reset()

    conn =
      submit_with_csrf(
        bob,
        "/alice/public-repo/issues/new",
        :post,
        "/alice/public-repo/issues",
        %{"issue" => %{"title" => "Created safely", "body" => "body secret"}}
      )

    assert redirected_to(conn) == "/alice/public-repo/issues/11"
    assert_private_no_store(conn)
    refute redirected_to(conn) =~ "Created"
    refute redirected_to(conn) =~ "secret"

    assert [{:create, [^bob, "alice", "public-repo", attrs, metadata]}] = mutation_calls()
    assert attrs == %{"title" => "Created safely", "body" => "body secret"}
    assert Map.keys(metadata) |> Enum.sort() == [:ip_address, :request_id, :user_agent]
  end

  test "create validation re-renders field errors and retained safe values", %{bob: bob} do
    TestIssues.respond(
      :create,
      {:error,
       {:validation,
        [
          %{resource: "Issue", field: "title", code: :invalid},
          %{resource: "Issue", field: "body", code: :unprocessable}
        ]}}
    )

    conn =
      submit_with_csrf(
        bob,
        "/alice/public-repo/issues/new",
        :post,
        "/alice/public-repo/issues",
        %{"issue" => %{"title" => "Retained title", "body" => "Retained body"}}
      )

    assert html_response(conn, 422) =~ "Retained title"
    assert conn.resp_body =~ "Retained body"
    assert conn.resp_body =~ "Title is invalid"
    assert conn.resp_body =~ "Body could not be processed"
    assert length(Enum.filter(mutation_calls(), &match?({:create, _}, &1))) == 1
  end

  test "author edit and close/reopen use PRG and one update per request", %{alice: alice} do
    edit = request_conn(alice) |> get("/alice/public-repo/issues/7/edit")
    assert html_response(edit, 200) =~ ~s(value="Issue 7")
    assert edit.resp_body =~ ~s(name="_method" value="patch")

    TestIssues.reset()

    updated =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7/edit",
        :patch,
        "/alice/public-repo/issues/7",
        %{"issue" => %{"title" => "Edited", "body" => "Edited body"}}
      )

    assert redirected_to(updated) == "/alice/public-repo/issues/7"

    assert [{:update, [^alice, "alice", "public-repo", 7, update_attrs, _metadata]}] =
             mutation_calls()

    assert update_attrs == %{"title" => "Edited", "body" => "Edited body"}

    for {state, reason} <- [{"closed", "completed"}, {"open", "reopened"}] do
      TestIssues.reset()

      conn =
        submit_with_csrf(
          alice,
          "/alice/public-repo/issues/7",
          :patch,
          "/alice/public-repo/issues/7/state",
          %{"state" => state}
        )

      assert redirected_to(conn) == "/alice/public-repo/issues/7"

      assert [{:update, [^alice, "alice", "public-repo", 7, attrs, _metadata]}] =
               mutation_calls()

      assert attrs == %{"state" => state, "state_reason" => reason}
    end
  end

  test "writer relationship fields are forwarded while unknown fields are discarded", %{
    alice: alice
  } do
    conn =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7/edit",
        :patch,
        "/alice/public-repo/issues/7",
        %{
          "issue" => %{
            "title" => "Managed",
            "body" => "Body",
            "labels" => ["bug"],
            "assignees" => ["alice"],
            "admin" => "forged"
          }
        }
      )

    assert redirected_to(conn) == "/alice/public-repo/issues/7"
    assert [{:update, [_actor, _owner, _repository, 7, attrs, _metadata]}] = mutation_calls()

    assert attrs == %{
             "title" => "Managed",
             "body" => "Body",
             "labels" => ["bug"],
             "assignees" => ["alice"]
           }

    TestIssues.reset()

    cleared =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7/edit",
        :patch,
        "/alice/public-repo/issues/7",
        %{
          "issue" => %{
            "title" => "Managed",
            "body" => "Body",
            "labels" => [""],
            "assignees" => [""]
          }
        }
      )

    assert redirected_to(cleared) == "/alice/public-repo/issues/7"

    assert [{:update, [_actor, _owner, _repository, 7, cleared_attrs, _metadata]}] =
             mutation_calls()

    assert cleared_attrs["labels"] == []
    assert cleared_attrs["assignees"] == []
  end

  test "comment creation loads canonical kind and redirects pull-backed conversations", %{
    bob: bob
  } do
    TestIssues.respond(:get, fn [_actor, _owner, _repository, number] ->
      {:ok, TestPage.issue(number, "Pull", :pull_request)}
    end)

    conn =
      submit_with_csrf(
        bob,
        "/alice/public-repo/issues/9",
        :post,
        "/alice/public-repo/issues/9/comments",
        %{"comment" => %{"body" => "No URL leakage"}}
      )

    assert redirected_to(conn) == "/alice/public-repo/pulls/9"
    refute redirected_to(conn) =~ "leakage"

    assert [
             {:create_comment,
              [^bob, "alice", "public-repo", 9, %{"body" => "No URL leakage"}, _]}
           ] = mutation_calls()

    assert [{:get, [^bob, "alice", "public-repo", 9]}] =
             Enum.filter(TestIssues.calls(), &match?({:get, _}, &1))
  end

  test "pull-backed comments remain available when ordinary issues are disabled", %{
    alice: alice
  } do
    TestIssues.respond(:get, fn [_actor, _owner, _repository, number] ->
      {:ok, TestPage.issue(number, "Pull", :pull_request)}
    end)

    created =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :post,
        "/alice/disabled-repo/issues/9/comments",
        %{"comment" => %{"body" => "Still available"}}
      )

    assert redirected_to(created) == "/alice/disabled-repo/pulls/9"

    TestIssues.reset()
    TestIssues.respond(:get, {:ok, TestPage.issue(9, "Pull", :pull_request)})
    TestIssues.respond(:get_comment, {:ok, %ForgeIssues.Comment{id: 4, issue_number: 9}})

    updated =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :patch,
        "/alice/disabled-repo/issues/9/comments/4",
        %{"comment" => %{"body" => "Edited while disabled"}}
      )

    assert redirected_to(updated) == "/alice/disabled-repo/pulls/9"

    TestIssues.reset()
    TestIssues.respond(:get, {:ok, TestPage.issue(9, "Pull", :pull_request)})
    TestIssues.respond(:get_comment, {:ok, %ForgeIssues.Comment{id: 4, issue_number: 9}})

    deleted =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :delete,
        "/alice/disabled-repo/issues/9/comments/4",
        %{}
      )

    assert redirected_to(deleted) == "/alice/disabled-repo/pulls/9"
  end

  test "invalid pull comments retain errors on the exact pull conversation form", %{
    alice: alice,
    public: public
  } do
    editable = %ForgeIssues.Comment{
      id: 4,
      issue_number: 9,
      body: "Original pull comment",
      author: %{username: "alice"},
      capabilities: %{can_edit: true, can_delete: true},
      inserted_at: ~U[2026-08-09 08:01:00Z]
    }

    TestIssues.respond(:get, {:ok, TestPage.issue(9, "Pull", :pull_request)})
    TestIssues.respond(:get_comment, {:ok, editable})

    TestIssues.respond(
      :update_comment,
      {:error, {:validation, [%{resource: "IssueComment", field: "body", code: :invalid}]}}
    )

    TestPage.respond(:pull, fn ->
      result = TestPage.pull_result(public, alice, alice, 9)
      {:ok, put_in(result.content.comments.entries, [editable])}
    end)

    conn =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :patch,
        "/alice/public-repo/issues/9/comments/4",
        %{"comment" => %{"body" => "Retained pull edit"}}
      )

    assert html_response(conn, 422) =~ "data-pull-conversation"
    assert conn.resp_body =~ "Body is invalid"
    assert conn.resp_body =~ ~r/id="pull-comment-4"[^>]*>Retained pull edit</s
    refute conn.resp_body =~ ~r/id="pull-comment-body"[^>]*>Retained pull edit</s

    TestIssues.reset()
    TestIssues.respond(:get, {:ok, TestPage.issue(9, "Pull", :pull_request)})

    TestIssues.respond(
      :create_comment,
      {:error, {:validation, [%{resource: "IssueComment", field: "body", code: :invalid}]}}
    )

    create_conn =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :post,
        "/alice/public-repo/issues/9/comments",
        %{"comment" => %{"body" => "Retained pull creation"}}
      )

    assert html_response(create_conn, 422) =~ "data-pull-conversation"
    assert create_conn.resp_body =~ "Body is invalid"
    assert create_conn.resp_body =~ ~r/id="pull-comment-body"[^>]*>Retained pull creation</s
    refute create_conn.resp_body =~ ~r/id="pull-comment-4"[^>]*>Retained pull creation</s
  end

  test "comment update and delete verify route parent before one mutation", %{alice: alice} do
    TestIssues.respond(:get_comment, {:ok, %ForgeIssues.Comment{id: 4, issue_number: 8}})

    mismatch =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :patch,
        "/alice/public-repo/issues/7/comments/4",
        %{"comment" => %{"body" => "wrong parent"}}
      )

    assert mismatch.status == 404
    assert Enum.filter(mutation_calls(), &match?({:update_comment, _}, &1)) == []

    TestIssues.reset()

    updated =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :patch,
        "/alice/public-repo/issues/7/comments/4",
        %{"comment" => %{"body" => "edited"}}
      )

    assert redirected_to(updated) == "/alice/public-repo/issues/7"
    assert length(Enum.filter(mutation_calls(), &match?({:update_comment, _}, &1))) == 1

    TestIssues.reset()

    deleted =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :delete,
        "/alice/public-repo/issues/7/comments/4",
        %{}
      )

    assert redirected_to(deleted) == "/alice/public-repo/issues/7"
    assert length(Enum.filter(mutation_calls(), &match?({:delete_comment, _}, &1))) == 1
  end

  test "comment update validation retains errors only on the targeted edit form", %{
    alice: alice,
    public: public
  } do
    first = %ForgeIssues.Comment{
      id: 4,
      issue_number: 7,
      body: "First original",
      author: %{username: "alice"},
      capabilities: %{can_edit: true, can_delete: true},
      inserted_at: ~U[2026-08-09 08:01:00Z]
    }

    second = %ForgeIssues.Comment{
      id: 5,
      issue_number: 7,
      body: "Second original",
      author: %{username: "alice"},
      capabilities: %{can_edit: true, can_delete: true},
      inserted_at: ~U[2026-08-09 08:02:00Z]
    }

    TestPage.respond(:issue, fn ->
      issue =
        TestPage.issue(7, "Issue 7")
        |> put_in([Access.key(:capabilities), :can_comment], true)

      result = TestPage.result(public, alice, alice, issue)

      {:ok,
       put_in(result.content.comments, %Fornacast.Page{
         entries: [first, second],
         total: 2,
         page: 1,
         per_page: 100
       })}
    end)

    TestIssues.respond(
      :update_comment,
      {:error,
       {:validation,
        [
          %{resource: "IssueComment", field: "body", code: :invalid},
          %{resource: "IssueComment", field: "base", code: :unprocessable}
        ]}}
    )

    conn =
      submit_with_csrf(
        alice,
        "/alice/public-repo/issues/7",
        :patch,
        "/alice/public-repo/issues/7/comments/4",
        %{"comment" => %{"body" => "Retained targeted edit"}}
      )

    assert html_response(conn, 422) =~ "Retained targeted edit"
    assert conn.resp_body =~ "Second original"
    assert conn.resp_body =~ "Body is invalid"
    assert conn.resp_body =~ "The comment could not be processed"
    refute conn.resp_body =~ ~r/id="issue-comment-5"[^>]*>Retained targeted edit</s
    refute conn.resp_body =~ ~r/id="issue-comment-body"[^>]*>Retained targeted edit</s
    assert length(Enum.filter(mutation_calls(), &match?({:update_comment, _}, &1))) == 1
  end

  test "forbidden and disabled mutations preserve shared error semantics", %{bob: bob} do
    TestIssues.respond(:create, {:error, :forbidden})

    forbidden =
      submit_with_csrf(
        bob,
        "/alice/public-repo/issues/new",
        :post,
        "/alice/public-repo/issues",
        %{"issue" => %{"title" => "Denied"}}
      )

    assert forbidden.status == 403
    assert_private_no_store(forbidden)

    disabled = request_conn(bob) |> get("/alice/disabled-repo/issues/new")
    assert disabled.status == 410

    private = request_conn(bob) |> get("/alice/private-repo/issues/new")
    assert private.status == 404
    refute private.resp_body =~ "private-repo"
  end

  test "domain capabilities deny direct new and edit form access", %{bob: bob} do
    TestIssues.respond(:form_options, fn [_actor, _owner, _repository, _issue] ->
      {:ok,
       %{
         labels: [],
         assignees: [],
         capabilities: %{
           can_create: false,
           can_comment: false,
           can_edit: false,
           can_close: false,
           can_manage_relationships: false
         }
       }}
    end)

    assert (request_conn(bob) |> get("/alice/public-repo/issues/new")).status == 403
    assert (request_conn(bob) |> get("/alice/public-repo/issues/7/edit")).status == 403
  end

  defp request_conn(user \\ nil) do
    conn =
      build_conn()
      |> Plug.Conn.put_private(:repository_collaboration_page, TestPage)
      |> Plug.Conn.put_private(:forge_issues, TestIssues)

    if user, do: Plug.Test.init_test_session(conn, user_id: user.id), else: conn
  end

  defp submit_with_csrf(user, form_path, method, path, params) do
    form = request_conn(user) |> get(form_path)
    token = extract_csrf_token(form.resp_body)

    conn =
      form
      |> recycle()
      |> Plug.Conn.put_private(:repository_collaboration_page, TestPage)
      |> Plug.Conn.put_private(:forge_issues, TestIssues)
      |> with_production_csrf()

    params = Map.put(params, "_csrf_token", token)

    case method do
      :post -> post(conn, path, params)
      :patch -> patch(conn, path, params)
      :delete -> delete(conn, path, params)
    end
  end

  defp extract_csrf_token(html) do
    [_full, token] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html)
    token
  end

  defp login_return_to(conn) do
    conn
    |> redirected_to()
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("return_to")
  end

  # Phoenix.ConnTest skips CSRF by default; remove only that test bypass so the
  # request traverses the same protect_from_forgery plug as production.
  defp with_production_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp mutation_calls do
    Enum.filter(TestIssues.calls(), fn {operation, _args} ->
      operation in [:create, :update, :create_comment, :update_comment, :delete_comment]
    end)
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
