defmodule FornacastWeb.RepositoryRawTest do
  use ExUnit.Case, async: true

  alias FornacastWeb.RepositoryRaw

  test "content disposition strips controls, escapes quoted ASCII, and adds UTF-8 filename*" do
    disposition = RepositoryRaw.content_disposition("snow-雪\r\n\"\t\\cat.png")

    assert disposition =~ ~s(filename="snow-_\\"\\\\cat.png")
    assert disposition =~ "filename*=UTF-8''snow-%E9%9B%AA%22%5Ccat.png"
    refute disposition =~ "\r"
    refute disposition =~ "\n"
    refute disposition =~ "\t"
  end

  test "content type allows only raster image extensions case-insensitively" do
    assert RepositoryRaw.content_type("image.png") == "image/png"
    assert RepositoryRaw.content_type("image.JPG") == "image/jpeg"
    assert RepositoryRaw.content_type("image.JpEg") == "image/jpeg"
    assert RepositoryRaw.content_type("image.gif") == "image/gif"
    assert RepositoryRaw.content_type("image.WeBp") == "image/webp"
    assert RepositoryRaw.content_type("image.AVIF") == "image/avif"

    assert RepositoryRaw.content_type("page.html") == "application/octet-stream"
    assert RepositoryRaw.content_type("vector.svg") == "application/octet-stream"
    assert RepositoryRaw.content_type("archive.bin") == "application/octet-stream"
  end

  test "response headers always disable content sniffing" do
    assert [
             {"content-type", "image/png"},
             {"content-disposition", disposition},
             {"x-content-type-options", "nosniff"}
           ] = RepositoryRaw.headers("logo.png")

    assert disposition =~ ~s(filename="logo.png")
  end
end

defmodule FornacastWeb.RepositoryControllerTestPage do
  alias FornacastWeb.RepositoryPage

  def reset do
    Process.put({__MODULE__, :responses}, %{})
    Process.put({__MODULE__, :calls}, [])
    :ok
  end

  def respond(operation, response) do
    responses = Process.get({__MODULE__, :responses}, %{})
    Process.put({__MODULE__, :responses}, Map.put(responses, operation, response))
    :ok
  end

  def calls, do: Process.get({__MODULE__, :calls}, [])

  def code(repository, owner, viewer, selector),
    do: reply(:code, [repository, owner, viewer, selector])

  def refs(repository, owner, viewer, kind, page),
    do: reply(:refs, [repository, owner, viewer, kind, page])

  def commits(repository, owner, viewer, route, page),
    do: reply(:commits, [repository, owner, viewer, route, page])

  def commit(repository, owner, viewer, sha, ref_context),
    do: reply(:commit, [repository, owner, viewer, sha, ref_context])

  def tree(repository, owner, viewer, route, page),
    do: reply(:tree, [repository, owner, viewer, route, page])

  def search(repository, owner, viewer, selector, query, scope, opts),
    do: reply(:search, [repository, owner, viewer, selector, query, scope, opts])

  def raw(repository, owner, viewer, route),
    do: reply(:raw, [repository, owner, viewer, route])

  def release(result), do: reply(:release, [result])

  def raw_result(repository, owner, viewer, name \\ "download.bin", data \\ "raw data") do
    blob = %GitCore.Blob{
      name: name,
      oid: "raw-oid",
      size: byte_size(data),
      data: data,
      truncated: false,
      binary: false,
      non_utf8: false,
      lease: :raw_lease
    }

    %RepositoryPage.Result{
      kind: :raw,
      chrome: chrome(repository, owner, viewer),
      content: %RepositoryPage.Raw{blob: blob},
      leases: [{__MODULE__, blob}]
    }
  end

  def refs_result(repository, owner, viewer, page, total_pages, refs \\ []) do
    %RepositoryPage.Result{
      kind: :refs,
      chrome: chrome(repository, owner, viewer, nil),
      content: %RepositoryPage.Refs{
        kind: :branch,
        page: %GitCore.RefPage{
          refs: refs,
          total: length(refs),
          page: page,
          per_page: 100,
          total_pages: total_pages
        }
      }
    }
  end

  def commits_result(repository, owner, viewer, page, total_pages) do
    %RepositoryPage.Result{
      kind: :commits,
      chrome: chrome(repository, owner, viewer),
      content: %RepositoryPage.Commits{
        page: %GitCore.CommitPage{
          commits: [],
          total: 0,
          page: page,
          per_page: 50,
          total_pages: total_pages
        }
      }
    }
  end

  def tree_result(repository, owner, viewer, page, total_pages) do
    %RepositoryPage.Result{
      kind: :tree,
      chrome: chrome(repository, owner, viewer),
      content: %RepositoryPage.Tree{path: "", tree: tree_page(page, total_pages)}
    }
  end

  def empty_result(repository, owner, viewer, write_access) do
    clone =
      if write_access do
        %RepositoryPage.Clone{
          https_url: "https://forge.test/#{owner.username}/#{repository.slug}.git",
          ssh_url: "ssh://#{owner.username}@forge.test/#{owner.username}/#{repository.slug}.git",
          push_commands: [
            "git init",
            "git remote add origin ssh://#{owner.username}@forge.test/#{owner.username}/#{repository.slug}.git",
            "git branch -M #{repository.default_branch}",
            "git push -u origin #{repository.default_branch}"
          ]
        }
      else
        %RepositoryPage.Clone{
          https_url: "https://forge.test/#{owner.username}/#{repository.slug}.git",
          ssh_url: nil,
          push_commands: []
        }
      end

    %RepositoryPage.Result{
      kind: :empty,
      chrome: %{chrome(repository, owner, viewer, nil) | clone: clone},
      content: %RepositoryPage.Empty{write_access: write_access, disk_usage: {:ok, 0}}
    }
  end

  def code_result(repository, owner, viewer, leases \\ []) do
    %RepositoryPage.Result{
      kind: :code,
      chrome: chrome(repository, owner, viewer),
      content: %RepositoryPage.Code{
        commit_summary: %GitCore.CommitSummary{count: 0, latest: nil},
        tree: tree_page(1, 1),
        readme: {:unavailable, :blob_busy},
        analysis: {:unavailable, :scan_timeout},
        disk_usage: {:unavailable, :scan_busy}
      },
      leases: leases
    }
  end

  defp reply(operation, args) do
    Process.put({__MODULE__, :calls}, calls() ++ [{operation, args}])
    response = Process.get({__MODULE__, :responses}, %{}) |> Map.get(operation, :default)

    case response do
      :default -> default_response(operation, args)
      fun when is_function(fun, 1) -> fun.(args)
      value -> value
    end
  end

  defp default_response(:release, _args), do: :ok

  defp default_response(:code, [repository, owner, viewer, _selector]) do
    {:ok,
     %RepositoryPage.Result{
       kind: :empty,
       chrome: chrome(repository, owner, viewer, nil),
       content: %RepositoryPage.Empty{write_access: false, disk_usage: {:ok, 0}}
     }}
  end

  defp default_response(:refs, [repository, owner, viewer, kind, page]) do
    result = refs_result(repository, owner, viewer, page, 1)
    {:ok, put_in(result.content.kind, kind)}
  end

  defp default_response(:commits, [repository, owner, viewer, _route, page]) do
    {:ok,
     %RepositoryPage.Result{
       kind: :commits,
       chrome: chrome(repository, owner, viewer),
       content: %RepositoryPage.Commits{
         page: %GitCore.CommitPage{
           commits: [],
           total: 0,
           page: page,
           per_page: 50,
           total_pages: 1
         }
       }
     }}
  end

  defp default_response(:commit, [repository, owner, viewer, sha, selector]) do
    commit = commit(sha)

    {:ok,
     %RepositoryPage.Result{
       kind: :commit,
       chrome: chrome(repository, owner, viewer, selector),
       content: %RepositoryPage.Commit{
         commit: commit,
         diff: %GitCore.CommitDiff{
           files: [],
           patch: "",
           truncated: false,
           changed_files: 0,
           additions: 0,
           deletions: 0
         },
         ref_context: nil
       }
     }}
  end

  defp default_response(:tree, [repository, owner, viewer, _route, page]) do
    {:ok,
     %RepositoryPage.Result{
       kind: :tree,
       chrome: chrome(repository, owner, viewer),
       content: %RepositoryPage.Tree{path: "", tree: tree_page(page, 1)}
     }}
  end

  defp default_response(
         :search,
         [repository, owner, viewer, selector, query, scope, opts]
       ) do
    {:ok,
     %RepositoryPage.Result{
       kind: :search,
       chrome: chrome(repository, owner, viewer, selector),
       content: %RepositoryPage.Search{
         query: query || "",
         scope: scope,
         results: nil,
         validation_error: Keyword.get(opts, :validation_error)
       }
     }}
  end

  defp default_response(:raw, [repository, owner, viewer, _route]) do
    {:ok, raw_result(repository, owner, viewer)}
  end

  defp chrome(repository, owner, viewer, selector \\ :default) do
    full_ref =
      case selector do
        nil -> nil
        :default -> canonical_default(repository.default_branch)
        %GitCore.RefSelector{full_name: full_name} -> full_name
      end

    snapshot =
      if full_ref do
        %GitCore.Snapshot{kind: :branch, ref: full_ref, oid: String.duplicate("a", 40)}
      end

    ref =
      %GitCore.Ref{
        name: canonical_default(repository.default_branch),
        kind: :branch,
        target: String.duplicate("a", 40),
        display_name: repository.default_branch
      }

    %RepositoryPage.Chrome{
      owner: owner,
      repository: repository,
      viewer: viewer,
      ref_summary: %GitCore.RefSummary{
        branch_count: 1,
        tag_count: 0,
        branches: [ref],
        tags: [],
        refs_truncated: false
      },
      snapshot: snapshot,
      clone: %RepositoryPage.Clone{
        https_url: "https://forge.test/#{owner.username}/#{repository.slug}.git",
        ssh_url: nil,
        push_commands: []
      }
    }
  end

  defp canonical_default("refs/" <> _rest = ref), do: ref
  defp canonical_default(ref), do: "refs/heads/" <> ref

  defp tree_page(page, total_pages) do
    %GitCore.TreePage{
      entries: [],
      total_entries: 0,
      page: page,
      per_page: 100,
      total_pages: total_pages
    }
  end

  defp commit(sha) do
    %GitCore.Commit{
      oid: sha,
      title: "Commit #{sha}",
      message: "Commit #{sha}",
      author_name: "Alice",
      author_email: "alice@example.test",
      author_time: 1,
      committer_name: "Alice",
      committer_email: "alice@example.test",
      committer_time: 1,
      parents: []
    }
  end
end

defmodule FornacastWeb.RepositoryControllerTestHTML do
  def repository(_assigns), do: raise("repository render failed")
end

defmodule FornacastWeb.RepositoryControllerCompositionGitCore do
  @missing_cache __MODULE__.MissingCache

  def reset(opts \\ []) do
    Process.put(
      {__MODULE__, :state},
      %{
        tip: Keyword.get(opts, :tip, String.duplicate("a", 40)),
        advance_to: Keyword.get(opts, :advance_to),
        cache_server: Keyword.get(opts, :cache_server, @missing_cache),
        calls: []
      }
    )

    :ok
  end

  def calls, do: state().calls

  def ref_summary(path, opts \\ []) do
    tip = state().tip
    record({:ref_summary, path, opts, tip})

    {:ok,
     %GitCore.RefSummary{
       branch_count: 1,
       tag_count: 0,
       branches: [
         %GitCore.Ref{
           name: "refs/heads/main",
           kind: :branch,
           target: tip,
           display_name: "main"
         }
       ],
       tags: [],
       refs_truncated: false
     }}
  end

  def resolve_snapshot(path, selector) do
    current = state()
    tip = current.tip
    record({:resolve_snapshot, path, selector, tip})

    if current.advance_to do
      put_state(%{state() | tip: current.advance_to, advance_to: nil})
    end

    {:ok, %GitCore.Snapshot{kind: :branch, ref: "refs/heads/main", oid: tip}}
  end

  def commit_summary(path, oid, opts \\ []) do
    record({:commit_summary, path, oid, opts})

    {:ok,
     %GitCore.CommitSummary{
       count: 1,
       latest: commit(oid)
     }}
  end

  def read_blob(path, oid, blob_path, opts \\ []) do
    record({:read_blob, path, oid, blob_path, opts})
    {:error, %GitCore.Error{kind: :path_not_found, operation: :read_blob}}
  end

  def read_tree_with_history(path, oid, tree_path, page, _opts \\ []) do
    key = {path, :tree_history, oid, tree_path, page, 200}
    record({:tree_cache_key, key})

    GitCore.Cache.fetch(
      key,
      fn ->
        record({:tree_recomputed, oid})

        {:ok,
         %GitCore.TreePage{
           entries: [],
           total_entries: 0,
           page: page,
           per_page: 200,
           total_pages: 1
         }}
      end,
      server: state().cache_server
    )
  end

  def repository_analysis(path, oid, opts \\ []) do
    record({:repository_analysis, path, oid, opts})

    {:ok,
     %GitCore.RepositoryAnalysis{
       languages: [],
       total_bytes: 0,
       files_scanned: 0,
       bytes_scanned: 0,
       truncated: false
     }}
  end

  def repository_disk_usage(path, opts \\ []) do
    record({:repository_disk_usage, path, opts})
    {:ok, 0}
  end

  def release_blob(blob) do
    record({:release_blob, blob})
    :ok
  end

  defp commit(oid) do
    %GitCore.Commit{
      oid: oid,
      title: "Snapshot #{oid}",
      message: "Snapshot #{oid}",
      author_name: "Alice",
      author_email: "alice@example.test",
      author_time: 1,
      committer_name: "Alice",
      committer_email: "alice@example.test",
      committer_time: 1,
      parents: []
    }
  end

  defp record(call) do
    current = state()
    put_state(%{current | calls: current.calls ++ [call]})
  end

  defp state do
    Process.get({__MODULE__, :state}) || raise "composition GitCore was not reset"
  end

  defp put_state(state), do: Process.put({__MODULE__, :state}, state)
end

defmodule FornacastWeb.RepositoryControllerCompositionPage do
  alias FornacastWeb.RepositoryPage
  alias FornacastWeb.RepositoryControllerCompositionGitCore, as: CompositionGitCore

  def code(repository, owner, viewer, selector) do
    RepositoryPage.code(repository, owner, viewer, selector, git_core: CompositionGitCore)
  end

  def release(result), do: RepositoryPage.release(result)
end

defmodule FornacastWeb.RepositoryControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.RepositoryControllerCompositionGitCore, as: CompositionGitCore
  alias FornacastWeb.RepositoryControllerCompositionPage, as: CompositionPage
  alias FornacastWeb.RepositoryControllerTestPage, as: TestPage

  @endpoint FornacastWeb.Endpoint

  setup do
    reset_database!()
    Fornacast.Setup.force_initialized!()
    TestPage.reset()
    CompositionGitCore.reset()

    alice = insert_user!("alice")
    bob = insert_user!("bob")
    public = insert_repository!(alice, "public-repo", :public)
    private = insert_repository!(alice, "private-repo", :private)

    on_exit(&Fornacast.Setup.reset!/0)

    %{alice: alice, bob: bob, public: public, private: private}
  end

  test "anonymous readers can reach the complete public repository route matrix", context do
    TestPage.respond(:raw, fn [repository, owner, viewer, _route] ->
      {:ok, TestPage.raw_result(repository, owner, viewer, "README.md", "read me")}
    end)

    paths = [
      "/alice/public-repo",
      "/alice/public-repo/branches",
      "/alice/public-repo/tags",
      "/alice/public-repo/commits/main",
      "/alice/public-repo/commits/feature/docs",
      "/alice/public-repo/commit/deadbeef",
      "/alice/public-repo/src/main",
      "/alice/public-repo/raw/main/README.md",
      "/alice/public-repo/search"
    ]

    for path <- paths do
      conn = request_conn() |> get(path)
      assert conn.status == 200, "expected anonymous public read for #{path}, got #{conn.status}"
      assert_private_no_store(conn)
    end

    assert context.public.visibility == :public
  end

  test "an authorized viewer can read private repository pages", %{alice: alice} do
    conn = request_conn(alice) |> get("/alice/private-repo")

    assert html_response(conn, 200) =~ "data-repository-kind=\"empty\""
    assert_private_no_store(conn)
    assert [{:code, _args}] = non_release_calls()
  end

  test "an authorized viewer receives private cache policy for private raw content",
       %{alice: alice} do
    conn = request_conn(alice) |> get("/alice/private-repo/raw/main/README.md")

    assert response(conn, 200) == "raw data"
    assert_private_no_store(conn)
    assert [{:raw, _args}, {:release, [_result]}] = TestPage.calls()
  end

  test "missing and inaccessible private repositories return the same sanitized 404 before page reads",
       %{bob: bob} do
    inaccessible = request_conn(bob) |> get("/alice/private-repo")
    missing = request_conn(bob) |> get("/alice/missing-repo")

    assert inaccessible.status == 404
    assert missing.status == 404
    assert inaccessible.resp_body == missing.resp_body
    assert normalized_headers(inaccessible) == normalized_headers(missing)
    assert_private_no_store(inaccessible)
    assert_private_no_store(missing)
    assert inaccessible.resp_body =~ "Repository not found"
    refute inaccessible.resp_body =~ "private-repo"
    assert TestPage.calls() == []
  end

  test "create and import stay authenticated while dynamic public reads do not" do
    assert redirected_to(request_conn() |> get("/repos/new")) == "/login"
    assert redirected_to(request_conn() |> get("/repos/import")) == "/login"
    assert redirected_to(request_conn() |> post("/repos", %{})) == "/login"
    assert html_response(request_conn() |> get("/alice/public-repo"), 200)
  end

  test "canonical and legacy query refs become typed selectors" do
    assert html_response(
             request_conn() |> get("/alice/public-repo?ref=refs%2Fheads%2Ffeature%2Fdocs"),
             200
           )

    assert {:code, [_repository, _owner, nil, canonical]} = List.last(non_release_calls())
    assert canonical == %GitCore.RefSelector{kind: :branch, full_name: "refs/heads/feature/docs"}

    TestPage.reset()
    assert html_response(request_conn() |> get("/alice/public-repo?ref=main"), 200)
    assert {:code, [_repository, _owner, nil, legacy]} = List.last(non_release_calls())
    assert legacy == %GitCore.RefSelector{kind: :legacy, full_name: "main"}
  end

  test "explicit empty and malformed refs do not silently select the default branch" do
    TestPage.respond(:code, fn [_repository, _owner, _viewer, selector] ->
      assert selector == %GitCore.RefSelector{kind: :legacy, full_name: ""}
      {:error, error(:ref_not_found, :resolve_snapshot, "missing")}
    end)

    assert html_response(request_conn() |> get("/alice/public-repo?ref="), 404) =~
             "Repository content not found"

    TestPage.reset()

    TestPage.respond(:code, fn [_repository, _owner, _viewer, selector] ->
      assert selector == %GitCore.RefSelector{kind: :legacy, full_name: "refs/heads/"}
      {:error, error(:ref_not_found, :resolve_snapshot, "missing")}
    end)

    assert html_response(
             request_conn() |> get("/alice/public-repo?ref=refs%2Fheads%2F"),
             404
           ) =~ "Repository content not found"
  end

  test "slash route refs and repository paths are passed to RepositoryPage without probing" do
    assert html_response(
             request_conn() |> get("/alice/public-repo/commits/feature/docs"),
             200
           )

    assert {:commits, [_repository, _owner, nil, ["feature", "docs"], 1]} =
             List.last(non_release_calls())

    TestPage.reset()

    assert html_response(
             request_conn() |> get("/alice/public-repo/src/feature/docs/lib/demo.ex"),
             200
           )

    assert {:tree, [_repository, _owner, nil, ["feature", "docs", "lib", "demo.ex"], 1]} =
             List.last(non_release_calls())

    TestPage.reset()
    assert response(request_conn() |> get("/alice/public-repo/raw/main/lib/demo.ex"), 200)

    assert {:raw, [_repository, _owner, nil, ["main", "lib", "demo.ex"]]} =
             hd(non_release_calls())
  end

  test "missing source and raw route segments are repository-scoped 404s before page reads" do
    src =
      request_conn()
      |> FornacastWeb.RepositoryController.src(%{
        "owner" => "alice",
        "repo" => "public-repo",
        "segments" => []
      })

    assert html_response(src, 404) =~ "Repository content not found"
    assert TestPage.calls() == []

    raw =
      request_conn()
      |> FornacastWeb.RepositoryController.raw(%{
        "owner" => "alice",
        "repo" => "public-repo",
        "segments" => []
      })

    assert html_response(raw, 404) =~ "Repository content not found"
    assert TestPage.calls() == []
  end

  test "commit SHA stays authoritative while a canonical ref is retained as context" do
    assert html_response(
             request_conn()
             |> get("/alice/public-repo/commit/url-sha?ref=refs%2Ftags%2Frelease"),
             200
           ) =~ "url-sha"

    assert {:commit, [_repository, _owner, nil, "url-sha", selector]} =
             hd(non_release_calls())

    assert selector == %GitCore.RefSelector{kind: :tag, full_name: "refs/tags/release"}
  end

  test "structured query refs authorize first and return repository-scoped 404s without page reads",
       %{bob: bob} do
    for path <- [
          "/alice/public-repo?ref[]=main",
          "/alice/public-repo/commit/deadbeef?ref[]=main",
          "/alice/public-repo/search?ref[]=main&q=needle"
        ] do
      TestPage.reset()
      conn = request_conn() |> get(path)

      assert html_response(conn, 404) =~ "Repository content not found"
      assert_private_no_store(conn)
      assert TestPage.calls() == []
    end

    TestPage.reset()
    inaccessible = request_conn(bob) |> get("/alice/private-repo?ref[]=main")

    assert html_response(inaccessible, 404) =~ "Repository not found"
    refute inaccessible.resp_body =~ "Repository content not found"
    assert_private_no_store(inaccessible)
    assert TestPage.calls() == []
  end

  test "page parsing rejects invalid values before orchestration" do
    for page <- ["0", "-1", "not-a-number"] do
      conn = request_conn() |> get("/alice/public-repo/branches?page=#{page}")
      assert html_response(conn, 422) =~ "Page must be a positive integer"
      assert_private_no_store(conn)
    end

    assert TestPage.calls() == []
  end

  test "positive out-of-range pages are 404 while empty page one and exact pages render",
       %{public: repository, alice: owner} do
    TestPage.respond(:refs, {:ok, TestPage.refs_result(repository, owner, nil, 2, 1)})

    assert html_response(request_conn() |> get("/alice/public-repo/branches?page=2"), 404) =~
             "Page not found"

    TestPage.reset()
    TestPage.respond(:refs, {:ok, TestPage.refs_result(repository, owner, nil, 1, 1)})

    assert html_response(request_conn() |> get("/alice/public-repo/branches?page=1"), 200) =~
             "No branches found"

    TestPage.reset()
    TestPage.respond(:refs, {:ok, TestPage.refs_result(repository, owner, nil, 2, 2)})
    assert html_response(request_conn() |> get("/alice/public-repo/branches?page=2"), 200)
  end

  test "empty repository ref collections reject every requested page after page one",
       %{public: repository, alice: owner} do
    TestPage.respond(:refs, {:ok, TestPage.empty_result(repository, owner, nil, false)})

    for route <- ["branches", "tags"] do
      TestPage.reset()
      TestPage.respond(:refs, {:ok, TestPage.empty_result(repository, owner, nil, false)})

      assert html_response(
               request_conn() |> get("/alice/public-repo/#{route}?page=2"),
               404
             ) =~ "Page not found"
    end
  end

  test "an empty repository cannot render an arbitrary commit",
       %{public: repository, alice: owner} do
    TestPage.respond(:commit, {:ok, TestPage.empty_result(repository, owner, nil, false)})

    conn = request_conn() |> get("/alice/public-repo/commit/deadbeef")

    assert html_response(conn, 404) =~ "Repository content not found"
    assert_private_no_store(conn)
    assert [{:commit, _args}, {:release, [_result]}] = TestPage.calls()
  end

  test "commit and tree collection bounds use the same out-of-range rule",
       %{public: repository, alice: owner} do
    TestPage.respond(
      :commits,
      {:ok, TestPage.commits_result(repository, owner, nil, 3, 2)}
    )

    assert html_response(
             request_conn() |> get("/alice/public-repo/commits/main?page=3"),
             404
           ) =~ "Page not found"

    TestPage.reset()
    TestPage.respond(:tree, {:ok, TestPage.tree_result(repository, owner, nil, 3, 2)})

    assert html_response(
             request_conn() |> get("/alice/public-repo/src/main?page=3"),
             404
           ) =~ "Page not found"

    TestPage.reset()
    TestPage.respond(:tree, {:ok, TestPage.tree_result(repository, owner, nil, 2, 2)})
    assert html_response(request_conn() |> get("/alice/public-repo/src/main?page=2"), 200)
  end

  test "missing refs, commits, and paths use one repository-scoped 404 with a default Code link" do
    for {operation, kind, path} <- [
          {:commits, :ref_not_found, "/alice/public-repo/commits/missing"},
          {:commit, :commit_not_found, "/alice/public-repo/commit/missing"},
          {:tree, :path_not_found, "/alice/public-repo/src/main/missing"}
        ] do
      TestPage.reset()
      TestPage.respond(operation, {:error, error(kind, operation, "native detail")})

      body = request_conn() |> get(path) |> html_response(404)
      assert body =~ "Repository content not found"
      assert body =~ ~s(href="/alice/public-repo")
      refute body =~ "native detail"
      assert length(non_release_calls()) == 1
    end
  end

  test "search accepts an absent query and trims valid queries while retaining ref and scope" do
    assert html_response(request_conn() |> get("/alice/public-repo/search"), 200) =~
             "Enter a query"

    assert {:search, [_repository, _owner, nil, nil, nil, :path, []]} =
             hd(non_release_calls())

    TestPage.reset()

    assert html_response(
             request_conn()
             |> get(
               "/alice/public-repo/search?ref=refs%2Ftags%2Frelease&q=%20needle%20&scope=content"
             ),
             200
           ) =~ ~s(value="needle")

    assert {:search, [_repository, _owner, nil, selector, "needle", :content, []]} =
             hd(non_release_calls())

    assert selector == %GitCore.RefSelector{kind: :tag, full_name: "refs/tags/release"}
  end

  test "search validates one-to-200 characters and supported scopes without discarding input" do
    for {query, scope, safe_scope, message} <- [
          {"%20%20", "path", :path, "Enter a search query"},
          {String.duplicate("x", 201), "content", :content, "200 characters or fewer"},
          {"needle", "unsupported", :path, "Choose path or content search"}
        ] do
      TestPage.reset()

      path =
        "/alice/public-repo/search?ref=refs%2Fheads%2Fmain&q=#{query}&scope=#{scope}"

      body = request_conn() |> get(path) |> html_response(422)
      assert body =~ message
      assert body =~ ~s(name="ref")
      assert body =~ "refs/heads/main"

      assert {:search,
              [
                _repository,
                _owner,
                nil,
                %GitCore.RefSelector{},
                retained_query,
                ^safe_scope,
                opts
              ]} =
               hd(non_release_calls())

      assert Keyword.has_key?(opts, :validation_error)
      assert retained_query == String.trim(URI.decode_www_form(query))

      if scope == "unsupported" do
        assert body =~ ~s(value="needle")
        assert body =~ ~s(name="scope")
        assert body =~ ~r/<option value="path"[^>]*selected/
        assert body =~ "Choose path or content search"
      end
    end
  end

  test "search rejects a structured query value without discarding valid ref and scope" do
    conn =
      request_conn()
      |> get("/alice/public-repo/search?ref=refs%2Fheads%2Fmain&q[]=needle&scope=content")

    body = html_response(conn, 422)
    assert body =~ "Enter a search query"
    assert body =~ "refs/heads/main"
    assert_private_no_store(conn)

    assert {:search,
            [
              _repository,
              _owner,
              nil,
              %GitCore.RefSelector{kind: :branch, full_name: "refs/heads/main"},
              "",
              :content,
              opts
            ]} = hd(non_release_calls())

    assert opts[:validation_error] == :query_required
  end

  test "search truncation reasons render once in fixed file byte deadline result order",
       %{public: repository, alice: owner} do
    TestPage.respond(:search, fn
      [_repository, _owner, _viewer, selector, query, scope, _opts] ->
        result = search_result(repository, owner, selector, query, scope)
        {:ok, result}
    end)

    body =
      request_conn()
      |> get("/alice/public-repo/search?q=needle&scope=content")
      |> html_response(200)

    labels = [
      "File scan limit reached",
      "Content byte limit reached",
      "Search time limit reached",
      "Result limit reached"
    ]

    positions = Enum.map(labels, &(:binary.match(body, &1) |> elem(0)))
    assert positions == Enum.sort(positions)
    assert Enum.all?(labels, &(length(:binary.matches(body, &1)) == 1))
  end

  test "a completed search with no matches renders a stable empty result",
       %{public: repository, alice: owner} do
    TestPage.respond(:search, fn
      [_repository, _owner, _viewer, selector, query, scope, _opts] ->
        result = search_result(repository, owner, selector, query, scope)
        results = %{result.content.results | truncated_reasons: []}
        {:ok, put_in(result.content.results, results)}
    end)

    body =
      request_conn()
      |> get("/alice/public-repo/search?q=missing&scope=path")
      |> html_response(200)

    assert body =~ "No results found"
  end

  test "busy and repository-data failures use distinct sanitized copy", %{public: repository} do
    TestPage.respond(
      :search,
      {:error, error(:scan_busy, :search_tree, "native search queue")}
    )

    busy = request_conn() |> get("/alice/public-repo/search?q=needle")
    assert html_response(busy, 429) =~ "Repository is busy"
    assert Plug.Conn.get_resp_header(busy, "retry-after") == ["1"]
    assert_private_no_store(busy)

    TestPage.reset()

    storage_root = ForgeRepos.absolute_storage_path(repository)

    for kind <- [:invalid_repository, :storage_unavailable, :corrupt_repository] do
      TestPage.reset()

      TestPage.respond(
        :code,
        {:error,
         error(
           kind,
           :ref_summary,
           "#{storage_root}: native reason with %{secret: true}"
         )}
      )

      log =
        capture_log(fn ->
          body = request_conn() |> get("/alice/public-repo") |> html_response(503)
          assert body =~ "Repository data unavailable"
          refute body =~ "Repository temporarily unavailable"
          refute body =~ storage_root
          refute body =~ "native reason"
          refute body =~ "%{secret"
        end)

      assert log =~ to_string(kind)
      assert log =~ "ref_summary"
      assert log =~ "repository_id=#{repository.id}"
      assert log =~ "request_id="
      refute log =~ storage_root
      refute log =~ "native reason"
      refute log =~ "stacktrace"
      refute log =~ "%{secret"
    end

    TestPage.reset()
    TestPage.respond(:code, {:error, error(:scan_timeout, :commit_summary, "deadline")})
    transient = request_conn() |> get("/alice/public-repo")
    assert html_response(transient, 503) =~ "Repository temporarily unavailable"
    assert_private_no_store(transient)
    refute transient.resp_body =~ "Repository data unavailable"
  end

  test "cache failure recomputes through real RepositoryPage and renders the HTTP response" do
    assert Process.whereis(CompositionGitCore.MissingCache) == nil

    body =
      request_conn()
      |> Plug.Conn.put_private(:repository_page, CompositionPage)
      |> get("/alice/public-repo")
      |> html_response(200)

    assert body =~ "Snapshot #{String.duplicate("a", 40)}"

    assert [{:tree_recomputed, oid}] =
             Enum.filter(CompositionGitCore.calls(), &match?({:tree_recomputed, _}, &1))

    assert oid == String.duplicate("a", 40)
  end

  test "a push after resolution cannot mix OIDs and the next HTTP request uses the new cache key" do
    old_oid = String.duplicate("a", 40)
    new_oid = String.duplicate("b", 40)
    CompositionGitCore.reset(tip: old_oid, advance_to: new_oid)

    first_body =
      request_conn()
      |> Plug.Conn.put_private(:repository_page, CompositionPage)
      |> get("/alice/public-repo")
      |> html_response(200)

    first_calls = CompositionGitCore.calls()
    assert first_body =~ "Snapshot #{old_oid}"
    refute first_body =~ "Snapshot #{new_oid}"
    assert oid_reads(first_calls) == [old_oid]

    assert [{:tree_cache_key, {_path, :tree_history, ^old_oid, "", 1, 200}}] =
             Enum.filter(first_calls, &match?({:tree_cache_key, _}, &1))

    second_body =
      request_conn()
      |> Plug.Conn.put_private(:repository_page, CompositionPage)
      |> get("/alice/public-repo")
      |> html_response(200)

    all_calls = CompositionGitCore.calls()
    second_calls = Enum.drop(all_calls, length(first_calls))

    assert second_body =~ "Snapshot #{new_oid}"
    refute second_body =~ "Snapshot #{old_oid}"
    assert oid_reads(second_calls) == [new_oid]

    assert [{:tree_cache_key, {_path, :tree_history, ^new_oid, "", 1, 200}}] =
             Enum.filter(second_calls, &match?({:tree_cache_key, _}, &1))
  end

  test "optional README, language, and disk failures degrade inside a successful page",
       %{public: repository, alice: owner} do
    TestPage.respond(:code, {:ok, TestPage.code_result(repository, owner, nil)})

    body = request_conn() |> get("/alice/public-repo") |> html_response(200)
    assert body =~ "README temporarily unavailable"
    assert body =~ "Analysis temporarily unavailable"
    assert body =~ "Size temporarily unavailable"
    assert Enum.count(TestPage.calls(), &match?({:release, _}, &1)) == 1
  end

  test "required inline blob busy is a sanitized 503 without retry semantics" do
    TestPage.respond(:tree, {:error, error(:blob_busy, :read_blob, "native queue detail")})

    conn = request_conn() |> get("/alice/public-repo/src/main/README.md")
    assert html_response(conn, 503) =~ "Repository temporarily unavailable"
    assert Plug.Conn.get_resp_header(conn, "retry-after") == []
    refute conn.resp_body =~ "native queue detail"
  end

  test "empty repositories distinguish public readers from writers",
       %{public: repository, alice: owner} do
    TestPage.respond(:code, fn [_repository, _owner, viewer, _selector] ->
      {:ok, TestPage.empty_result(repository, owner, viewer, not is_nil(viewer))}
    end)

    reader_body = request_conn() |> get("/alice/public-repo") |> html_response(200)
    assert reader_body =~ "Clone URL"
    refute reader_body =~ "Push the first branch"
    refute reader_body =~ "git push -u origin"

    writer_body = request_conn(owner) |> get("/alice/public-repo") |> html_response(200)
    assert writer_body =~ "Push the first branch"
    assert writer_body =~ "git push -u origin main"
  end

  test "raw sends byte-for-byte data with safe headers and releases after send",
       %{public: repository, alice: owner} do
    TestPage.respond(
      :raw,
      {:ok, TestPage.raw_result(repository, owner, nil, "snow-雪.png", <<0, 1, 2>>)}
    )

    conn = request_conn() |> get("/alice/public-repo/raw/main/snow.png")
    assert response(conn, 200) == <<0, 1, 2>>
    assert_private_no_store(conn)
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png"]
    assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
    assert disposition =~ "filename*=UTF-8''snow-%E9%9B%AA.png"
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert [{:raw, _args}, {:release, [_result]}] = TestPage.calls()
  end

  test "every raster extension is allowlisted at the controller boundary and HTML and SVG are not",
       %{public: repository, alice: owner} do
    for {filename, expected} <- [
          {"a.png", "image/png"},
          {"a.JPG", "image/jpeg"},
          {"a.jPeG", "image/jpeg"},
          {"a.GIF", "image/gif"},
          {"a.webp", "image/webp"},
          {"a.AvIf", "image/avif"},
          {"a.html", "application/octet-stream"},
          {"a.SVG", "application/octet-stream"}
        ] do
      TestPage.reset()
      TestPage.respond(:raw, {:ok, TestPage.raw_result(repository, owner, nil, filename, "x")})

      conn = request_conn() |> get("/alice/public-repo/raw/main/file")
      assert Plug.Conn.get_resp_header(conn, "content-type") == [expected]
      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  test "controller raw headers sanitize controls, quote, backslash, and non-ASCII",
       %{public: repository, alice: owner} do
    hostile = "snow-雪\r\n\"\t\\cat.png"
    TestPage.respond(:raw, {:ok, TestPage.raw_result(repository, owner, nil, hostile, "x")})

    conn = request_conn() |> get("/alice/public-repo/raw/main/file")
    assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(filename="snow-_\\"\\\\cat.png")
    assert disposition =~ "filename*=UTF-8''snow-%E9%9B%AA%22%5Ccat.png"
    refute disposition =~ "\r"
    refute disposition =~ "\n"
    refute disposition =~ "\t"
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "raw busy and oversized errors have exact status and never send a data prefix" do
    TestPage.respond(:raw, {:error, error(:blob_busy, :read_blob_complete, "busy detail")})
    busy = request_conn() |> get("/alice/public-repo/raw/main/file")
    assert html_response(busy, 429) =~ "Repository is busy"
    assert Plug.Conn.get_resp_header(busy, "retry-after") == ["1"]
    refute busy.resp_body =~ "data prefix"
    refute Enum.any?(TestPage.calls(), &match?({:release, _}, &1))

    TestPage.reset()

    TestPage.respond(
      :raw,
      {:error, error(:blob_too_large, :read_blob_complete, "data prefix should not leak")}
    )

    too_large = request_conn() |> get("/alice/public-repo/raw/main/file")
    assert html_response(too_large, 413) =~ "File is too large"
    assert_private_no_store(too_large)
    refute too_large.resp_body =~ "data prefix"
    refute Enum.any?(TestPage.calls(), &match?({:release, _}, &1))
  end

  test "a truncated complete raw body is discarded and its lease is released",
       %{public: repository, alice: owner} do
    result = TestPage.raw_result(repository, owner, nil, "large.bin", "data prefix")
    result = put_in(result.content.blob.truncated, true)
    TestPage.respond(:raw, {:ok, result})

    conn = request_conn() |> get("/alice/public-repo/raw/main/large.bin")
    assert html_response(conn, 413) =~ "File is too large"
    refute conn.resp_body =~ "data prefix"
    assert [{:raw, _args}, {:release, [_result]}] = TestPage.calls()
  end

  test "rendered and raw leases release once even when response completion raises",
       %{public: repository, alice: owner} do
    html_result = TestPage.code_result(repository, owner, nil, [{:test, :lease}])
    TestPage.respond(:code, {:ok, html_result})

    assert_raise RuntimeError, "repository render failed", fn ->
      request_conn()
      |> Plug.Conn.put_private(
        :repository_html,
        FornacastWeb.RepositoryControllerTestHTML
      )
      |> get("/alice/public-repo")
    end

    assert Enum.count(TestPage.calls(), &match?({:release, _}, &1)) == 1

    TestPage.reset()
    raw_result = TestPage.raw_result(repository, owner, nil)
    TestPage.respond(:raw, {:ok, raw_result})

    assert_raise Plug.Conn.AlreadySentError, fn ->
      %{request_conn() | state: :sent}
      |> FornacastWeb.RepositoryController.raw(%{
        "owner" => "alice",
        "repo" => "public-repo",
        "segments" => ["main", "file"]
      })
    end

    assert Enum.count(TestPage.calls(), &match?({:release, _}, &1)) == 1
  end

  defp request_conn(user \\ nil) do
    conn =
      build_conn()
      |> Plug.Conn.put_private(:repository_page, TestPage)

    if user do
      Plug.Test.init_test_session(conn, user_id: user.id)
    else
      conn
    end
  end

  defp non_release_calls do
    Enum.reject(TestPage.calls(), &match?({:release, _}, &1))
  end

  defp oid_reads(calls) do
    calls
    |> Enum.flat_map(fn
      {:commit_summary, _path, oid, _opts} -> [oid]
      {:read_blob, _path, oid, _blob_path, _opts} -> [oid]
      {:tree_cache_key, {_path, :tree_history, oid, _tree_path, _page, _per_page}} -> [oid]
      {:repository_analysis, _path, oid, _opts} -> [oid]
      _call -> []
    end)
    |> Enum.uniq()
  end

  defp normalized_headers(conn) do
    conn.resp_headers
    |> Enum.reject(fn {name, _value} ->
      String.downcase(name) in ["x-request-id", "date", "server"]
    end)
    |> Enum.sort()
  end

  defp assert_private_no_store(conn) do
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(conn, "pragma") == ["no-cache"]
    conn
  end

  defp search_result(repository, owner, selector, query, scope) do
    result = TestPage.code_result(repository, owner, nil)
    chrome = result.chrome

    chrome =
      if selector do
        put_in(chrome.snapshot.ref, selector.full_name)
      else
        chrome
      end

    %FornacastWeb.RepositoryPage.Result{
      kind: :search,
      chrome: chrome,
      content: %FornacastWeb.RepositoryPage.Search{
        query: query,
        scope: scope,
        results: %GitCore.SearchResults{
          scope: scope,
          results: [],
          files_scanned: 4,
          bytes_scanned: 12,
          truncated_reasons: [:result_limit, :deadline, :file_limit, :byte_limit, :deadline]
        },
        validation_error: nil
      }
    }
  end

  defp error(kind, operation, detail) do
    %GitCore.Error{kind: kind, operation: operation, detail: detail}
  end

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
      description: "#{slug} description",
      visibility: visibility,
      storage_path: "@test/#{slug}.git",
      default_branch: "main"
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
