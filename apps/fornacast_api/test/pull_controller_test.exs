defmodule FornacastAPI.PullControllerTest do
  use FornacastAPI.ConnCase, async: false

  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, PullRequest}

  @user_agent "fornacast-pull-api-test/1.0"
  @versions [nil, "2022-11-28", "2026-03-10"]

  setup do
    on_exit(fn ->
      Repo.delete_all(MergeOperation)
      Repo.delete_all(PullRequest)
    end)

    :ok
  end

  test "all six pull routes are wired for default and explicit versions" do
    alice = user("alice")
    repository = repository(alice, "example")
    create_branch!(repository, "main")
    create_branch!(repository, "feature/api")
    pull = pull(repository, alice, 8)
    {_key, secret} = pat(alice, ["public_repo"])

    for version <- @versions do
      listed = api_conn(nil, version) |> get("/api/v3/repos/alice/example/pulls")
      assert [_] = json_response(listed, 200)

      created =
        api_conn(nil, version)
        |> put_req_header("content-type", "application/json")
        |> post("/api/v3/repos/alice/example/pulls", ~s({"title":"x","head":"h","base":"b"}))

      assert json_response(created, 401)["message"] == "Requires authentication"

      shown = api_conn(nil, version) |> get("/api/v3/repos/alice/example/pulls/8")
      shown_body = json_response(shown, 200)
      assert shown_body["number"] == 8
      assert shown_body["html_url"] == "http://localhost:4890/api/v3/repos/alice/example/pulls/8"
      assert shown_body["diff_url"] == shown_body["html_url"]
      assert shown_body["patch_url"] == shown_body["html_url"]

      updated =
        api_conn(nil, version)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/v3/repos/alice/example/pulls/8", ~s({"title":"x"}))

      assert json_response(updated, 401)["message"] == "Requires authentication"

      merge_check =
        api_conn(nil, version) |> get("/api/v3/repos/alice/example/pulls/8/merge")

      assert json_response(merge_check, 404)["message"] == "Not Found"

      merge =
        api_conn(secret, version)
        |> put_req_header("content-type", "application/json")
        |> put("/api/v3/repos/alice/example/pulls/8/merge", ~s({"merge_method":"squash"}))

      assert json_response(merge, 422)["message"] == "Validation Failed"
    end

    merged_at = ~U[2026-07-21 00:00:00Z]

    pull
    |> Ecto.Changeset.change(merged_at: merged_at, merge_commit_sha: String.duplicate("c", 40))
    |> Repo.update!()

    Issue
    |> Repo.get!(pull.issue_id)
    |> Ecto.Changeset.change(state: :closed, closed_at: merged_at)
    |> Repo.update!()

    for version <- ["2022-11-28", "2026-03-10"] do
      assert response(
               api_conn(nil, version) |> get("/api/v3/repos/alice/example/pulls/8/merge"),
               204
             ) == ""

      pull_body =
        api_conn(nil, version)
        |> get("/api/v3/repos/alice/example/pulls/8")
        |> json_response(200)

      issue_body =
        api_conn(nil, version)
        |> get("/api/v3/repos/alice/example/issues/8")
        |> json_response(200)

      [listed_issue] =
        api_conn(nil, version)
        |> get("/api/v3/repos/alice/example/issues?state=all")
        |> json_response(200)

      assert pull_body["merged_at"] == "2026-07-21T00:00:00Z"
      assert issue_body["pull_request"]["merged_at"] == pull_body["merged_at"]
      assert listed_issue["pull_request"]["merged_at"] == pull_body["merged_at"]
    end

    assert pull.issue_id
  end

  test "authentication scopes and private masking precede mutation body parsing" do
    alice = user("alice")
    bob = user("bob")
    repository(alice, "public")

    {:ok, private} =
      ForgeRepos.create_repository(alice, %{
        name: "private",
        slug: "private",
        visibility: :private
      })

    {_key, insufficient_secret} = pat(alice, ["read:org"])
    {_key, bob_secret} = pat(bob, ["repo"])
    {_key, repo_secret} = pat(alice, ["repo"])
    {_key, read_secret} = pat(alice, ["repo:read"])

    for version <- ["2022-11-28", "2026-03-10"] do
      missing = post_raw(api_conn(nil, version), "/api/v3/repos/alice/public/pulls", "{")
      assert json_response(missing, 401)["message"] == "Requires authentication"

      insufficient =
        post_raw(api_conn(insufficient_secret, version), "/api/v3/repos/alice/public/pulls", "{")

      assert json_response(insufficient, 403)["message"] ==
               "Resource not accessible by personal access token"

      assert get_resp_header(insufficient, "x-accepted-oauth-scopes") == ["public_repo, repo"]

      hidden = post_raw(api_conn(bob_secret, version), "/api/v3/repos/alice/private/pulls", "{")
      assert json_response(hidden, 404)["message"] == "Not Found"
      assert get_resp_header(hidden, "x-accepted-oauth-scopes") == [""]

      public_read = api_conn(read_secret, version) |> get("/api/v3/repos/alice/public/pulls")
      assert json_response(public_read, 200) == []

      assert get_resp_header(public_read, "x-accepted-oauth-scopes") == [
               "public_repo, repo, repo:read, repo:write"
             ]

      read_mutation =
        post_raw(api_conn(read_secret, version), "/api/v3/repos/alice/public/pulls", "{")

      assert json_response(read_mutation, 403)["message"] ==
               "Resource not accessible by personal access token"

      repo_mutation =
        post_raw(api_conn(repo_secret, version), "/api/v3/repos/alice/public/pulls", "{")

      assert json_response(repo_mutation, 400)["message"] == "Bad Request"
    end

    assert private.visibility == :private
  end

  test "reader authors create and update while writers merge and list filters paginate" do
    alice = user("alice")
    bob = user("bob")
    eve = user("eve")
    repository = repository(alice, "workflow")
    grant_reader!(repository, bob)
    grant_reader!(repository, eve)
    create_branch!(repository, "main")
    create_branch!(repository, "feature/api", "main")
    create_branch!(repository, "feature/two", "main")
    {_key, bob_secret} = pat(bob, ["public_repo"])
    {_key, eve_secret} = pat(eve, ["public_repo"])
    {_key, owner_secret} = pat(alice, ["public_repo"])

    created =
      post_json(api_conn(bob_secret, "2022-11-28"), "/api/v3/repos/alice/workflow/pulls", %{
        "title" => "Add API",
        "body" => "Implements the subset",
        "head" => "feature/api",
        "base" => "main"
      })

    created_body = json_response(created, 201)
    assert created_body["number"] == 1
    assert created_body["head"]["ref"] == "feature/api"

    second =
      post_json(api_conn(bob_secret, "2022-11-28"), "/api/v3/repos/alice/workflow/pulls", %{
        "title" => "Second",
        "head" => "feature/two",
        "base" => "main"
      })

    assert json_response(second, 201)["number"] == 2

    page =
      api_conn(nil, "2022-11-28")
      |> get(
        "/api/v3/repos/alice/workflow/pulls?state=open&sort=created&direction=asc&page=1&per_page=1&ignored=yes"
      )

    assert [%{"number" => 1}] = json_response(page, 200)
    assert [links] = get_resp_header(page, "link")
    assert links =~ "page=2"
    assert links =~ "per_page=1"

    filtered =
      api_conn(nil, "2022-11-28")
      |> get("/api/v3/repos/alice/workflow/pulls?head=alice%3Afeature%2Ftwo&base=main")

    assert [%{"number" => 2}] = json_response(filtered, 200)

    author_update =
      patch_json(api_conn(bob_secret, "2022-11-28"), "/api/v3/repos/alice/workflow/pulls/1", %{
        "title" => "Author edit"
      })

    assert json_response(author_update, 200)["title"] == "Author edit"

    denied =
      patch_json(api_conn(eve_secret, "2022-11-28"), "/api/v3/repos/alice/workflow/pulls/1", %{
        "title" => "Denied"
      })

    assert json_response(denied, 403)["message"] == "Forbidden"

    writer_update =
      patch_json(api_conn(owner_secret, "2022-11-28"), "/api/v3/repos/alice/workflow/pulls/1", %{
        "body" => "Writer edit"
      })

    assert json_response(writer_update, 200)["body"] == "Writer edit"

    stale_merge =
      put_json(
        api_conn(owner_secret, "2022-11-28"),
        "/api/v3/repos/alice/workflow/pulls/1/merge",
        %{"sha" => String.duplicate("f", 40), "merge_method" => "merge"}
      )

    assert json_response(stale_merge, 409)["message"] == "Conflict"

    merged =
      put_json(
        api_conn(owner_secret, "2022-11-28"),
        "/api/v3/repos/alice/workflow/pulls/1/merge",
        %{
          "commit_title" => "Merge API",
          "commit_message" => "Exact message",
          "sha" => created_body["head"]["sha"],
          "merge_method" => "merge"
        }
      )

    assert %{"merged" => true, "message" => "Pull Request successfully merged", "sha" => sha} =
             json_response(merged, 200)

    assert byte_size(sha) == 40

    pull_body =
      api_conn(nil, "2022-11-28")
      |> get("/api/v3/repos/alice/workflow/pulls/1")
      |> json_response(200)

    issue_body =
      api_conn(nil, "2022-11-28")
      |> get("/api/v3/repos/alice/workflow/issues/1")
      |> json_response(200)

    listed_issue =
      api_conn(nil, "2022-11-28")
      |> get("/api/v3/repos/alice/workflow/issues?state=all")
      |> json_response(200)
      |> Enum.find(&(&1["number"] == 1))

    assert is_binary(pull_body["merged_at"])
    assert issue_body["pull_request"]["merged_at"] == pull_body["merged_at"]
    assert listed_issue["pull_request"]["merged_at"] == pull_body["merged_at"]

    repository
    |> Ecto.Changeset.change(allow_merge_commit: false)
    |> Repo.update!()

    disabled =
      put_json(
        api_conn(owner_secret, "2022-11-28"),
        "/api/v3/repos/alice/workflow/pulls/2/merge",
        %{"merge_method" => "merge"}
      )

    assert json_response(disabled, 405)["message"] == "Pull Request is not mergeable"

    repository
    |> Ecto.Changeset.change(allow_merge_commit: true)
    |> Repo.update!()

    closed =
      patch_json(api_conn(bob_secret, "2022-11-28"), "/api/v3/repos/alice/workflow/pulls/2", %{
        "state" => "closed"
      })

    assert json_response(closed, 200)["state"] == "closed"

    conflict =
      put_json(
        api_conn(owner_secret, "2022-11-28"),
        "/api/v3/repos/alice/workflow/pulls/2/merge",
        %{"merge_method" => "merge"}
      )

    assert json_response(conflict, 405)["message"] == "Pull Request is not mergeable"

    unknown =
      patch_json(api_conn(owner_secret, "2022-11-28"), "/api/v3/repos/alice/workflow/pulls/2", %{
        "draft" => true
      })

    assert json_response(unknown, 422)["message"] == "Validation Failed"
  end

  test "issue composition skips pull-link queries for ordinary issues and batches pull links once" do
    alice = user("alice")
    repository = repository(alice, "issues")
    create_branch!(repository, "main")
    create_branch!(repository, "feature/api", "main")

    Repo.insert!(%Issue{
      repository_id: repository.id,
      number: 1,
      kind: :issue,
      title: "Ordinary",
      state: :open,
      author_user_id: alice.id
    })

    {ordinary_list, ordinary_list_queries} =
      count_pull_link_queries(fn ->
        api_conn(nil, "2022-11-28") |> get("/api/v3/repos/alice/issues/issues?state=all")
      end)

    assert [%{"number" => 1}] = json_response(ordinary_list, 200)

    pull(repository, alice, 2)

    {one_pull_list, one_pull_list_queries} =
      count_pull_link_queries(fn ->
        api_conn(nil, "2022-11-28") |> get("/api/v3/repos/alice/issues/issues?state=all")
      end)

    assert [%{"number" => 2, "pull_request" => %{}}, %{"number" => 1}] =
             json_response(one_pull_list, 200)

    pull(repository, alice, 3)

    {two_pull_list, two_pull_list_queries} =
      count_pull_link_queries(fn ->
        api_conn(nil, "2022-11-28") |> get("/api/v3/repos/alice/issues/issues?state=all")
      end)

    assert [
             %{"number" => 3, "pull_request" => %{}},
             %{"number" => 2, "pull_request" => %{}},
             %{"number" => 1}
           ] = json_response(two_pull_list, 200)

    assert ordinary_list_queries == 0
    assert one_pull_list_queries == 1
    assert two_pull_list_queries == 1

    {_ordinary, ordinary_queries} =
      count_pull_link_queries(fn ->
        api_conn(nil, "2022-11-28") |> get("/api/v3/repos/alice/issues/issues/1")
      end)

    {pull_conn, pull_queries} =
      count_pull_link_queries(fn ->
        api_conn(nil, "2022-11-28") |> get("/api/v3/repos/alice/issues/issues/2")
      end)

    assert json_response(pull_conn, 200)["pull_request"]["merged_at"] == nil
    assert ordinary_queries == 0
    assert pull_queries == 1
  end

  test "pull representations are JSON-only and reject diff and patch accepts" do
    alice = user("alice")
    repository(alice, "example")

    for accept <- ["application/vnd.github.diff", "application/vnd.github.patch"] do
      conn =
        api_conn(nil, "2022-11-28")
        |> put_req_header("accept", accept)
        |> get("/api/v3/repos/alice/example/pulls")

      assert json_response(conn, 406)["message"] == "Not Acceptable"
    end
  end

  defp repository(owner, slug) do
    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{
        name: slug,
        slug: slug,
        visibility: :public,
        default_branch: "main",
        has_issues: true,
        allow_merge_commit: true
      })

    repository
  end

  defp pull(repository, author, number) do
    issue =
      Repo.insert!(%Issue{
        repository_id: repository.id,
        number: number,
        kind: :pull_request,
        title: "Add API",
        body: "Implements the subset",
        state: :open,
        author_user_id: author.id
      })

    Repo.insert!(%PullRequest{
      repository_id: repository.id,
      issue_id: issue.id,
      head_ref: "refs/heads/feature/api",
      base_ref: "refs/heads/main",
      head_sha: snapshot_oid(repository, "feature/api"),
      base_sha: snapshot_oid(repository, "main"),
      mergeable: true,
      mergeable_state: :mergeable
    })
  end

  defp create_branch!(repository, branch, parent \\ nil) do
    path = ForgeRepos.absolute_storage_path(repository)

    tree_file =
      Path.join(System.tmp_dir!(), "pull-api-tree-#{System.unique_integer([:positive])}")

    content_file = tree_file <> "-content"
    File.write!(content_file, branch)
    on_exit(fn -> File.rm(tree_file) end)
    on_exit(fn -> File.rm(content_file) end)
    {blob, 0} = System.cmd("git", ["--git-dir=#{path}", "hash-object", "-w", content_file])
    raw_tree = ["100644 file", <<0>>, Base.decode16!(String.trim(blob), case: :lower)]
    File.write!(tree_file, raw_tree)

    {tree, 0} =
      System.cmd("git", ["--git-dir=#{path}", "hash-object", "-t", "tree", "-w", tree_file])

    parent_args = if parent, do: ["-p", snapshot_oid(repository, parent)], else: []

    {commit, 0} =
      System.cmd(
        "git",
        ["--git-dir=#{path}", "commit-tree", String.trim(tree)] ++ parent_args ++ ["-m", branch],
        env: [
          {"GIT_AUTHOR_NAME", "Test"},
          {"GIT_AUTHOR_EMAIL", "test@example.test"},
          {"GIT_COMMITTER_NAME", "Test"},
          {"GIT_COMMITTER_EMAIL", "test@example.test"}
        ]
      )

    {_, 0} =
      System.cmd("git", [
        "--git-dir=#{path}",
        "update-ref",
        "refs/heads/#{branch}",
        String.trim(commit)
      ])
  end

  defp snapshot_oid(repository, branch) do
    {:ok, snapshot} =
      GitCore.resolve_snapshot(
        ForgeRepos.absolute_storage_path(repository),
        %GitCore.RefSelector{kind: :branch, full_name: "refs/heads/#{branch}"}
      )

    snapshot.oid
  end

  defp api_conn(secret, version) do
    build_conn()
    |> put_req_header("user-agent", @user_agent)
    |> put_optional_version(version)
    |> put_optional_authorization(secret)
  end

  defp put_optional_version(conn, nil), do: conn

  defp put_optional_version(conn, version),
    do: put_req_header(conn, "x-github-api-version", version)

  defp put_optional_authorization(conn, nil), do: conn

  defp put_optional_authorization(conn, secret),
    do: put_req_header(conn, "authorization", "Bearer #{secret}")

  defp grant_reader!(repository, user) do
    %ForgeRepos.Collaborator{}
    |> ForgeRepos.Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: user.id,
      role: :read
    })
    |> Repo.insert!()
  end

  defp post_json(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> post(path, JSON.encode!(body))

  defp patch_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> patch(path, JSON.encode!(body))

  defp put_json(conn, path, body),
    do:
      conn |> put_req_header("content-type", "application/json") |> put(path, JSON.encode!(body))

  defp post_raw(conn, path, body) do
    conn |> put_req_header("content-type", "application/json") |> post(path, body)
  end

  defp count_pull_link_queries(fun) do
    ref = make_ref()
    handler = {__MODULE__, ref}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:fornacast, :repo, :query],
        fn _event, _measurements, metadata, {pid, query_ref} ->
          if metadata[:source] == "pull_requests", do: send(pid, {query_ref, :query})
        end,
        {parent, ref}
      )

    try do
      result = fun.()
      {result, drain_queries(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(ref, count) do
    receive do
      {^ref, :query} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end
end
