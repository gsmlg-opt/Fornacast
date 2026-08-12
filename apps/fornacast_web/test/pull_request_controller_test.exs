defmodule FornacastWeb.PullRequestControllerTestCollaborationPage do
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

  def pulls(repository, owner, viewer, filters, opts) do
    record(:pulls, [repository, owner, viewer, filters, opts])

    case Map.get(Process.get({__MODULE__, :responses}, %{}), :pulls) do
      nil -> {:ok, result(repository, owner, viewer, filters)}
      response when is_function(response, 0) -> response.()
      response -> response
    end
  end

  def pull(repository, owner, viewer, number, opts) do
    record(:pull, [repository, owner, viewer, number, opts])

    reply(:pull, fn ->
      {:ok,
       %RepositoryPage.Result{
         kind: :pull,
         chrome: chrome(repository, owner, viewer),
         content: %{
           pull: pull(number, "Pull #{number}"),
           comments: %Fornacast.Page{
             entries: [comment(1, "Canonical comment")],
             total: 1,
             page: 1,
             per_page: 100
           }
         }
       }}
    end)
  end

  def pull_commits(repository, owner, viewer, number, params) do
    record(:pull_commits, [repository, owner, viewer, number, params])

    reply(:pull_commits, fn ->
      page = Map.get(params, :page, 1)

      {:ok,
       %RepositoryPage.Result{
         kind: :pull_commits,
         chrome: chrome(repository, owner, viewer),
         content: %{
           pull: pull(number, "Pull #{number}"),
           commits: %Fornacast.Page{
             entries: [commit("commit-#{page}", "Commit page #{page}")],
             total: 101,
             page: page,
             per_page: 50
           }
         }
       }}
    end)
  end

  def pull_files(repository, owner, viewer, number, params) do
    record(:pull_files, [repository, owner, viewer, number, params])

    reply(:pull_files, fn ->
      page = Map.get(params, :page, 1)

      {:ok,
       %RepositoryPage.Result{
         kind: :pull_files,
         chrome: chrome(repository, owner, viewer),
         content: %{
           pull: pull(number, "Pull #{number}"),
           files: %ForgePulls.ChangedFilePage{
             entries: [changed_file(), binary_file()],
             total: 102,
             additions: 4,
             deletions: 2,
             page: page,
             per_page: 100,
             truncated: true
           }
         }
       }}
    end)
  end

  def result(repository, owner, viewer, filters) do
    pull = pull(7, "Ship comparison")

    %RepositoryPage.Result{
      kind: :pulls,
      chrome: chrome(repository, owner, viewer),
      content: %{
        pulls: %Fornacast.Page{entries: [pull], total: 61, page: filters.page, per_page: 30},
        filters: filters
      }
    }
  end

  def pull(number, title) do
    issue = %ForgeIssues.Issue{
      id: number,
      number: number,
      kind: :pull_request,
      title: title,
      body: "Pull body",
      state: :open,
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
      analysis: analysis(),
      capabilities: %{can_edit: false, can_close: false, can_merge: false}
    }
  end

  def analysis(mergeable \\ true) do
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

  def comment(id, body) do
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

  def commit(oid, title) do
    %GitCore.Commit{
      oid: oid,
      title: title,
      message: "#{title} <script>unsafe()</script>",
      author_name: "Alice <script>",
      author_email: "alice@example.test",
      author_time: 1_754_723_200,
      committer_name: "Alice",
      committer_email: "alice@example.test",
      committer_time: 1_754_723_200,
      parents: []
    }
  end

  def changed_file do
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

  def binary_file do
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

  defp reply(operation, fallback) do
    case Map.get(Process.get({__MODULE__, :responses}, %{}), operation) do
      nil -> fallback.()
      response when is_function(response, 0) -> response.()
      response -> response
    end
  end

  defp record(operation, args),
    do: Process.put({__MODULE__, :calls}, calls() ++ [{operation, args}])

  defp chrome(repository, owner, viewer) do
    %RepositoryPage.Chrome{
      owner: owner,
      repository: repository,
      viewer: viewer,
      ref_summary: %GitCore.RefSummary{
        branch_count: 2,
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

defmodule FornacastWeb.PullRequestControllerTestPulls do
  def reset do
    Process.put({__MODULE__, :calls}, [])
    Process.put({__MODULE__, :responses}, %{})
  end

  def calls, do: Process.get({__MODULE__, :calls}, [])

  def respond(operation, response) do
    responses = Process.get({__MODULE__, :responses}, %{})
    Process.put({__MODULE__, :responses}, Map.put(responses, operation, response))
  end

  def branch_options(repository, actor) do
    reply(:branch_options, [repository, actor], fn ->
      {:ok,
       [
         ref("refs/heads/feature", "feature"),
         ref("refs/heads/main", "main"),
         ref("refs/heads/release", "release")
       ]}
    end)
  end

  def compare(repository, actor, head, base, opts) do
    reply(:compare, [repository, actor, head, base, opts], fn ->
      {:ok,
       %ForgePulls.Comparison{
         head_ref: "refs/heads/feature",
         base_ref: "refs/heads/main",
         head_oid: String.duplicate("a", 40),
         base_oid: String.duplicate("b", 40),
         analysis: FornacastWeb.PullRequestControllerTestCollaborationPage.analysis()
       }}
    end)
  end

  def create_pull_request(repository, actor, attrs, metadata) do
    reply(:create_pull_request, [repository, actor, attrs, metadata], fn ->
      {:ok, FornacastWeb.PullRequestControllerTestCollaborationPage.pull(12, attrs["title"])}
    end)
  end

  def get_pull_request(repository, number, actor) do
    reply(:get_pull_request, [repository, number, actor], fn ->
      {:ok,
       FornacastWeb.PullRequestControllerTestCollaborationPage.pull(number, "Pull #{number}")}
    end)
  end

  def update_pull_request(repository, pull, actor, attrs, metadata) do
    reply(:update_pull_request, [repository, pull, actor, attrs, metadata], fn ->
      if actor.username == pull.issue.author.username,
        do: {:ok, put_in(pull.issue.state, attrs["state"])},
        else: {:error, :forbidden}
    end)
  end

  def merge(repository, pull, actor, attrs, metadata) do
    reply(:merge, [repository, pull, actor, attrs, metadata], fn ->
      {:ok,
       %{
         merged: true,
         message: "Pull Request successfully merged",
         sha: String.duplicate("c", 40)
       }}
    end)
  end

  defp ref(name, display_name),
    do: %GitCore.Ref{name: name, display_name: display_name, kind: :branch, target: "target"}

  defp reply(operation, args, fallback) do
    Process.put({__MODULE__, :calls}, calls() ++ [{operation, args}])

    case Map.get(Process.get({__MODULE__, :responses}, %{}), operation) do
      nil -> fallback.()
      response when is_function(response, 0) -> response.()
      response -> response
    end
  end
end

defmodule FornacastWeb.PullRequestControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.PullRequestControllerTestCollaborationPage, as: TestPage
  alias FornacastWeb.PullRequestControllerTestPulls, as: TestPulls

  @endpoint FornacastWeb.Endpoint

  setup do
    reset_database!()
    Fornacast.Setup.force_initialized!()
    TestPage.reset()
    TestPulls.reset()

    alice = insert_user!("alice")
    bob = insert_user!("bob")
    public = insert_repository!(alice, "public-repo", :public)
    private = insert_repository!(alice, "private-repo", :private)

    on_exit(&Fornacast.Setup.reset!/0)
    %{alice: alice, bob: bob, public: public, private: private}
  end

  test "anonymous readers list public pulls with allowlisted filters and pagination" do
    query =
      URI.encode_query(%{
        "page" => "2",
        "state" => "closed",
        "head" => "alice:feature",
        "base" => "main",
        "sort" => "popularity",
        "direction" => "asc"
      })

    conn = request_conn() |> get("/alice/public-repo/pulls?#{query}")

    assert html_response(conn, 200) =~ "data-pulls-page"
    assert conn.resp_body =~ "Ship comparison"
    assert conn.resp_body =~ "page=3"
    assert conn.resp_body =~ "head=alice%3Afeature"
    assert conn.resp_body =~ "base=main"
    assert_private_no_store(conn)

    assert [{:pulls, [_repository, _owner, nil, filters, []]}] = TestPage.calls()

    assert filters == %{
             page: 2,
             per_page: 30,
             state: :closed,
             head: "alice:feature",
             base: "main",
             sort: :popularity,
             direction: :asc
           }
  end

  test "private and missing pull lists share a masked 404" do
    private = request_conn() |> get("/alice/private-repo/pulls")
    missing = request_conn() |> get("/alice/missing-repo/pulls")

    assert private.status == 404
    assert missing.status == 404
    assert masked_body(private.resp_body) == masked_body(missing.resp_body)
    refute private.resp_body =~ "private-repo"
    assert TestPage.calls() == []
  end

  test "repository owner can read a private pull list", %{alice: alice} do
    conn = request_conn(alice) |> get("/alice/private-repo/pulls")

    assert html_response(conn, 200) =~ "data-pulls-page"
    assert [{:pulls, [_repository, _owner, ^alice, _filters, []]}] = TestPage.calls()
    assert_private_no_store(conn)
  end

  test "invalid list pagination and filters fail before composition" do
    assert (request_conn() |> get("/alice/public-repo/pulls?page=0")).status == 404
    assert (request_conn() |> get("/alice/public-repo/pulls?page[]=1")).status == 422
    assert (request_conn() |> get("/alice/public-repo/pulls?head[]=feature")).status == 422
    assert (request_conn() |> get("/alice/public-repo/pulls?base[]=main")).status == 422
    assert (request_conn() |> get("/alice/public-repo/pulls?state=merged")).status == 422
    assert (request_conn() |> get("/alice/public-repo/pulls?unknown=value")).status == 422
    assert TestPage.calls() == []
  end

  test "structured comparison refs return retained 422 forms", %{bob: bob} do
    head = request_conn(bob) |> get("/alice/public-repo/pulls/new?head[]=feature")
    base = request_conn(bob) |> get("/alice/public-repo/pulls/new?head=feature&base[]=main")

    assert html_response(head, 422) =~ "Head is invalid"
    assert html_response(base, 422) =~ "Base is invalid"
    assert Enum.filter(TestPulls.calls(), &match?({:compare, _}, &1)) == []
  end

  test "new and create require sign-in with generated local return targets" do
    new = request_conn() |> get("/alice/public-repo/pulls/new?return_to=//evil.test")
    create = request_conn() |> post("/alice/public-repo/pulls", %{})
    hostile = request_conn() |> get("/%2F%2Fevil.test/public-repo/pulls/new")

    assert login_return_to(new) == "/alice/public-repo/pulls/new"
    assert login_return_to(create) == "/alice/public-repo/pulls"
    assert login_return_to(hostile) == "/%2F%2Fevil.test/public-repo/pulls/new"
    refute String.starts_with?(login_return_to(hostile), "//")
    refute redirected_to(new) =~ "evil.test"
  end

  test "new form preserves branch order, defaults base, and skips comparison when head is blank",
       %{
         bob: bob
       } do
    conn = request_conn(bob) |> get("/alice/public-repo/pulls/new")

    assert html_response(conn, 200) =~ "data-pull-form"
    assert conn.resp_body =~ ~s(name="pull[head]")
    assert conn.resp_body =~ ~s(name="pull[base]")
    assert conn.resp_body =~ ~r/<option[^>]*value="main"[^>]*selected/
    refute conn.resp_body =~ "data-pull-compare"

    assert [{:branch_options, [_repository, ^bob]}] = TestPulls.calls()
    assert TestPage.calls() != []
  end

  test "new form compares same-owner head prefixes and previews counts", %{bob: bob} do
    conn =
      request_conn(bob)
      |> get("/alice/public-repo/pulls/new?head=alice%3Afeature&base=main")

    assert html_response(conn, 200) =~ "data-pull-compare"
    assert conn.resp_body =~ ~r/3<\/span>\s+commits/
    assert conn.resp_body =~ ~r/4<\/span>\s+files/

    assert [{:compare, [_repository, ^bob, "alice:feature", "main", []]}] =
             Enum.filter(TestPulls.calls(), &match?({:compare, _}, &1))
  end

  test "invalid and equal comparison refs retain safe values with 422", %{bob: bob} do
    for {reason, head, base} <- [
          {:invalid_head, "missing", "main"},
          {:cross_repository_head, "mallory:feature", "main"},
          {:head_equals_base, "main", "main"}
        ] do
      TestPulls.reset()
      TestPulls.respond(:compare, {:error, reason})

      conn =
        request_conn(bob)
        |> get(
          "/alice/public-repo/pulls/new?#{URI.encode_query(%{"head" => head, "base" => base})}"
        )

      assert html_response(conn, 422) =~ head
      assert conn.resp_body =~ base
      assert conn.resp_body =~ "is invalid"
    end
  end

  test "reader creates through one CSRF-protected metadata-bearing mutation and PRG", %{
    bob: bob
  } do
    form = request_conn(bob) |> get("/alice/public-repo/pulls/new")
    assert html_response(form, 200) =~ ~s(name="_csrf_token")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      request_conn(bob)
      |> with_production_csrf()
      |> post("/alice/public-repo/pulls", %{"pull" => %{"title" => "No token"}})
    end

    TestPulls.reset()

    conn =
      submit_with_csrf(
        bob,
        %{
          "pull" => %{
            "title" => "Created safely",
            "body" => "body secret",
            "head" => "alice:feature",
            "base" => "main",
            "admin" => "forged"
          }
        }
      )

    assert redirected_to(conn) == "/alice/public-repo/pulls/12"
    assert_private_no_store(conn)
    refute redirected_to(conn) =~ "Created"
    refute redirected_to(conn) =~ "secret"

    assert [{:create_pull_request, [_repository, ^bob, attrs, metadata]}] = mutation_calls()

    assert attrs == %{
             "title" => "Created safely",
             "body" => "body secret",
             "head" => "alice:feature",
             "base" => "main"
           }

    assert Map.keys(metadata) |> Enum.sort() == [:ip_address, :request_id, :user_agent]
  end

  test "creation validation retains title body and branch values", %{bob: bob} do
    TestPulls.respond(
      :create_pull_request,
      {:error,
       {:validation,
        [
          %{resource: "PullRequest", field: "title", code: :invalid},
          %{resource: "PullRequest", field: "base", code: :unprocessable}
        ]}}
    )

    conn =
      submit_with_csrf(
        bob,
        %{
          "pull" => %{
            "title" => "Retained title",
            "body" => "Retained body",
            "head" => "feature",
            "base" => "main"
          }
        }
      )

    assert html_response(conn, 422) =~ "Retained title"
    assert conn.resp_body =~ "Retained body"
    assert conn.resp_body =~ "feature"
    assert conn.resp_body =~ "main"
    assert conn.resp_body =~ "Title is invalid"
    assert conn.resp_body =~ "Base could not be processed"
    assert length(mutation_calls()) == 1
  end

  test "structured creation fields render a safe 422 before mutation", %{bob: bob} do
    conn =
      submit_with_csrf(
        bob,
        %{
          "pull" => %{
            "title" => %{"x" => "unsafe title"},
            "body" => %{"x" => "unsafe body"},
            "head" => %{"x" => "unsafe head"},
            "base" => %{"x" => "unsafe base"}
          }
        }
      )

    assert html_response(conn, 422) =~ "data-pull-form"
    assert conn.resp_body =~ "is invalid"
    refute conn.resp_body =~ "unsafe title"
    refute conn.resp_body =~ "unsafe body"
    assert mutation_calls() == []
  end

  test "authenticated private new is masked before branch reads", %{bob: bob} do
    conn = request_conn(bob) |> get("/alice/private-repo/pulls/new")
    assert conn.status == 404
    refute conn.resp_body =~ "private-repo"
    assert TestPulls.calls() == []
  end

  test "anonymous readers view the canonical pull conversation" do
    conn = request_conn() |> get("/alice/public-repo/pulls/7")

    assert html_response(conn, 200) =~ "data-pull-conversation"
    assert conn.resp_body =~ "Pull 7"
    assert conn.resp_body =~ "Canonical comment"
    assert_private_no_store(conn)
    assert [{:pull, [_repository, _owner, nil, 7, []]}] = TestPage.calls()
  end

  test "private pull detail masks like missing while the owner may read it", %{alice: alice} do
    private = request_conn() |> get("/alice/private-repo/pulls/7")
    missing = request_conn() |> get("/alice/missing-repo/pulls/7")

    assert private.status == 404
    assert missing.status == 404
    assert masked_body(private.resp_body) == masked_body(missing.resp_body)

    TestPage.reset()
    owner = request_conn(alice) |> get("/alice/private-repo/pulls/7")
    assert html_response(owner, 200) =~ "data-pull-conversation"
  end

  test "commit and file routes forward bounded pagination to the page composer" do
    commits = request_conn() |> get("/alice/public-repo/pulls/7/commits?page=2")
    files = request_conn() |> get("/alice/public-repo/pulls/7/files?page=2")

    assert html_response(commits, 200) =~ "data-pull-commits"
    assert commits.resp_body =~ "page=3"
    assert html_response(files, 200) =~ "data-pull-files"
    assert files.resp_body =~ "page=1"

    assert [
             {:pull_commits,
              [_commits_repository, _commits_owner, nil, 7, %{page: 2, per_page: 50}]},
             {:pull_files, [_files_repository, _files_owner, nil, 7, %{page: 2, per_page: 100}]}
           ] = TestPage.calls()
  end

  test "invalid detail numbers and pagination are controlled before composition" do
    assert (request_conn() |> get("/alice/public-repo/pulls/nope")).status == 404
    assert (request_conn() |> get("/alice/public-repo/pulls/7/commits?page=0")).status == 404
    assert (request_conn() |> get("/alice/public-repo/pulls/7/files?page[]=1")).status == 422
    assert TestPage.calls() == []
  end

  test "state and merge require sign-in with generated local detail return targets" do
    state = request_conn() |> patch("/alice/public-repo/pulls/7/state", %{"state" => "closed"})
    merge = request_conn() |> post("/alice/public-repo/pulls/7/merge", %{})

    hostile =
      request_conn()
      |> post("/%2F%2Fevil.test/public-repo/pulls/7/merge", %{})

    assert login_return_to(state) == "/alice/public-repo/pulls/7"
    assert login_return_to(merge) == "/alice/public-repo/pulls/7"
    assert login_return_to(hostile) == "/%2F%2Fevil.test/public-repo/pulls/7"
    refute String.starts_with?(login_return_to(hostile), "//")
  end

  test "author closes and reopens through exactly one metadata-bearing update", %{alice: alice} do
    for state <- ["closed", "open"] do
      TestPulls.reset()

      conn =
        submit_action_with_csrf(
          alice,
          "/alice/public-repo/pulls/7",
          :patch,
          "/alice/public-repo/pulls/7/state",
          %{"state" => state}
        )

      assert redirected_to(conn) == "/alice/public-repo/pulls/7"
      assert_private_no_store(conn)

      assert [
               {:update_pull_request,
                [_repository, _pull, ^alice, %{"state" => ^state}, metadata]}
             ] = task7_mutation_calls()

      assert Map.keys(metadata) |> Enum.sort() == [:ip_address, :request_id, :user_agent]
    end
  end

  test "writer merge forces merge method, accepts only optional expected head, and PRGs", %{
    alice: alice
  } do
    expected_head = String.duplicate("a", 40)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      request_conn(alice)
      |> with_production_csrf()
      |> post("/alice/public-repo/pulls/7/merge", %{})
    end

    conn =
      submit_action_with_csrf(
        alice,
        "/alice/public-repo/pulls/7",
        :post,
        "/alice/public-repo/pulls/7/merge",
        %{
          "sha" => expected_head,
          "merge_method" => "squash",
          "commit_title" => "not accepted"
        }
      )

    assert redirected_to(conn) == "/alice/public-repo/pulls/7"
    assert_private_no_store(conn)

    assert [{:merge, [_repository, _pull, ^alice, attrs, metadata]}] = task7_mutation_calls()
    assert attrs == %{"sha" => expected_head, "merge_method" => "merge"}
    assert Map.keys(metadata) |> Enum.sort() == [:ip_address, :request_id, :user_agent]
  end

  test "merge domain failures retain exact web status semantics", %{alice: alice} do
    for {reason, status} <- [
          {:conflict, 405},
          {:merge_commits_disabled, 405},
          {:head_changed, 409},
          {:ref_conflict, 409},
          {{:unavailable, :timeout}, 503},
          {:forbidden, 403}
        ] do
      TestPulls.reset()
      TestPulls.respond(:merge, {:error, reason})

      conn =
        submit_action_with_csrf(
          alice,
          "/alice/public-repo/pulls/7",
          :post,
          "/alice/public-repo/pulls/7/merge",
          %{}
        )

      assert conn.status == status
      assert length(task7_mutation_calls()) == 1
      assert_private_no_store(conn)
    end
  end

  defp request_conn(user \\ nil) do
    conn =
      build_conn()
      |> Plug.Conn.put_private(:repository_collaboration_page, TestPage)
      |> Plug.Conn.put_private(:forge_pulls, TestPulls)

    if user, do: Plug.Test.init_test_session(conn, user_id: user.id), else: conn
  end

  defp submit_with_csrf(user, params) do
    form = request_conn(user) |> get("/alice/public-repo/pulls/new")
    token = extract_csrf_token(form.resp_body)

    form
    |> recycle()
    |> Plug.Conn.put_private(:repository_collaboration_page, TestPage)
    |> Plug.Conn.put_private(:forge_pulls, TestPulls)
    |> with_production_csrf()
    |> post("/alice/public-repo/pulls", Map.put(params, "_csrf_token", token))
  end

  defp submit_action_with_csrf(user, form_path, method, path, params) do
    form = request_conn(user) |> get(form_path)
    token = extract_csrf_token(form.resp_body)

    conn =
      form
      |> recycle()
      |> Plug.Conn.put_private(:repository_collaboration_page, TestPage)
      |> Plug.Conn.put_private(:forge_pulls, TestPulls)
      |> with_production_csrf()

    params = Map.put(params, "_csrf_token", token)

    case method do
      :post -> post(conn, path, params)
      :patch -> patch(conn, path, params)
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

  defp with_production_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp mutation_calls,
    do: Enum.filter(TestPulls.calls(), &match?({:create_pull_request, _}, &1))

  defp task7_mutation_calls do
    Enum.filter(TestPulls.calls(), fn {operation, _args} ->
      operation in [:update_pull_request, :merge]
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

  defp insert_repository!(owner, slug, visibility) do
    Fornacast.Repo.insert!(%Repository{
      owner_user_id: owner.id,
      slug: slug,
      name: String.replace(slug, "-", " "),
      visibility: visibility,
      storage_path: "@test/#{slug}.git",
      default_branch: "main",
      has_issues: true
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
