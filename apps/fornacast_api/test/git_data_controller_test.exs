defmodule FornacastAPI.GitDataControllerTest do
  use FornacastAPI.ConnCase, async: false

  defmodule PausingBodyAdapter do
    @behaviour Plug.Conn.Adapter

    def read_req_body(%{delegate: delegate, test_pid: test_pid, ref: ref} = state, opts) do
      send(test_pid, {ref, :body_read, self()})

      receive do
        {^ref, :continue_body} ->
          delegate
          |> Plug.Adapters.Test.Conn.read_req_body(opts)
          |> wrap_state(state)
      end
    end

    def send_resp(%{delegate: delegate} = state, status, headers, body) do
      delegate
      |> Plug.Adapters.Test.Conn.send_resp(status, headers, body)
      |> wrap_state(state)
    end

    def send_file(%{delegate: delegate} = state, status, headers, path, offset, length) do
      delegate
      |> Plug.Adapters.Test.Conn.send_file(status, headers, path, offset, length)
      |> wrap_state(state)
    end

    def send_chunked(%{delegate: delegate} = state, status, headers) do
      delegate
      |> Plug.Adapters.Test.Conn.send_chunked(status, headers)
      |> wrap_state(state)
    end

    def chunk(%{delegate: delegate} = state, body) do
      delegate
      |> Plug.Adapters.Test.Conn.chunk(body)
      |> wrap_state(state)
    end

    def inform(%{delegate: delegate}, status, headers),
      do: Plug.Adapters.Test.Conn.inform(delegate, status, headers)

    def upgrade(%{delegate: delegate} = state, protocol, opts) do
      case Plug.Adapters.Test.Conn.upgrade(delegate, protocol, opts) do
        {:ok, updated_delegate} -> {:ok, %{state | delegate: updated_delegate}}
        {:error, reason} -> {:error, reason}
      end
    end

    def push(%{delegate: delegate}, path, headers),
      do: Plug.Adapters.Test.Conn.push(delegate, path, headers)

    def get_peer_data(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_peer_data(delegate)

    def get_sock_data(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_sock_data(delegate)

    def get_ssl_data(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_ssl_data(delegate)

    def get_http_protocol(%{delegate: delegate}),
      do: Plug.Adapters.Test.Conn.get_http_protocol(delegate)

    defp wrap_state({status, body, updated_delegate}, state) when status in [:ok, :more],
      do: {status, body, %{state | delegate: updated_delegate}}
  end

  import Ecto.Query
  alias ForgeRepos.{GitWriteOperation, Repository}
  alias Fornacast.AuditEvent

  @moduletag :tmp_dir
  @versions ["2022-11-28", "2026-03-10"]

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous) end)
    :ok
  end

  test "both contracts initialize, read, write, fast-forward and clone real Git data", %{
    tmp_dir: tmp_dir
  } do
    for {version, index} <- Enum.with_index(@versions) do
      actor = user("git-owner-#{index}")
      {_key, secret} = pat(actor, ["repo"])
      base = "/api/v3/repos/#{actor.username}/demo"

      created =
        request(:post, "/api/v3/user/repos", secret, version, %{
          "name" => "demo",
          "auto_init" => true,
          "private" => true
        })
        |> json_response(201)

      assert created["default_branch"] == "main"
      repository = ForgeRepos.get_repository(actor.username, "demo")
      path = ForgeRepos.absolute_storage_path(repository)

      initial =
        request(:get, base <> "/git/ref/heads/main", secret, version) |> json_response(200)

      initial_oid = initial["object"]["sha"]
      assert initial["ref"] == "refs/heads/main"
      assert git!(["--git-dir", path, "show", "main:README.md"]) == "# demo"

      assert [%{"name" => "main", "commit" => %{"sha" => ^initial_oid}, "protected" => false}] =
               request(:get, base <> "/branches", secret, version) |> json_response(200)

      assert %{"name" => "main"} =
               request(:get, base <> "/branches/main", secret, version) |> json_response(200)

      ref_body = %{"ref" => "refs/heads/feature/api", "sha" => initial_oid}

      assert %{"ref" => "refs/heads/feature/api"} =
               request(:post, base <> "/git/refs", secret, version, ref_body)
               |> json_response(201)

      assert %{"name" => "feature/api"} =
               request(:get, base <> "/branches/feature%2Fapi", secret, version)
               |> json_response(200)

      first =
        request(:put, base <> "/contents/docs%2Fguide.txt", secret, version, %{
          "message" => "Add guide",
          "content" => Base.encode64("first\n"),
          "branch" => "feature/api"
        })
        |> json_response(201)

      blob = first["content"]["sha"]
      first_oid = first["commit"]["sha"]
      assert first["content"]["path"] == "docs/guide.txt"

      read =
        request(:get, base <> "/contents/docs/guide.txt?ref=feature%2Fapi", secret, version)
        |> json_response(200)

      assert Base.decode64!(String.replace(read["content"], "\n", "")) == "first\n"

      assert [%{"path" => "docs/guide.txt", "type" => "file"}] =
               request(:get, base <> "/contents/docs?ref=feature%2Fapi", secret, version)
               |> json_response(200)

      updated =
        request(:put, base <> "/contents/docs/guide.txt", secret, version, %{
          "message" => "Update guide",
          "content" => Base.encode64("second\n"),
          "branch" => "feature/api",
          "sha" => blob,
          "author" => %{"name" => "Custom Author", "email" => "custom@example.test"}
        })
        |> json_response(200)

      updated_oid = updated["commit"]["sha"]
      assert updated["commit"]["author"]["name"] == "Custom Author"

      assert request(:put, base <> "/contents/docs/guide.txt", secret, version, %{
               "message" => "stale",
               "content" => Base.encode64("bad"),
               "branch" => "feature/api",
               "sha" => blob
             }).status == 409

      assert %{"object" => %{"sha" => ^updated_oid}} =
               request(:patch, base <> "/git/refs/heads/main", secret, version, %{
                 "sha" => updated_oid,
                 "force" => false
               })
               |> json_response(200)

      assert request(:patch, base <> "/git/refs/heads/main", secret, version, %{
               "sha" => initial_oid
             }).status == 409

      assert request(:patch, base <> "/git/refs/heads/main", secret, version, %{
               "sha" => initial_oid,
               "force" => true
             }).status == 422

      assert request(:post, base <> "/git/refs", secret, version, ref_body).status == 422

      commits = request(:get, base <> "/commits?sha=feature%2Fapi&per_page=1", secret, version)
      assert [%{"sha" => ^updated_oid}] = json_response(commits, 200)
      assert get_resp_header(commits, "link") != []

      assert [%{"sha" => ^updated_oid}] =
               request(
                 :get,
                 base <>
                   "/commits?sha=feature%2Fapi&author=custom@example.test&path=docs/guide.txt",
                 secret,
                 version
               )
               |> json_response(200)

      assert %{"sha" => ^first_oid, "files" => [_]} =
               request(:get, base <> "/commits/" <> first_oid, secret, version)
               |> json_response(200)

      clone = Path.join(tmp_dir, "clone-#{index}")
      git!(["clone", path, clone])
      assert File.read!(Path.join(clone, "docs/guide.txt")) == "second\n"

      deleted =
        request(:delete, base <> "/contents/docs/guide.txt", secret, version, %{
          "message" => "Delete guide",
          "sha" => updated["content"]["sha"]
        })
        |> json_response(200)

      assert deleted["content"] == nil
      assert request(:get, base <> "/contents/docs/guide.txt", secret, version).status == 404
      assert request(:get, base <> "/contents/docs", secret, version).status == 404
      git!(["-C", clone, "fetch", "origin"])
      assert git!(["-C", clone, "rev-parse", "origin/main"]) == deleted["commit"]["sha"]

      operations =
        Repo.all(from op in GitWriteOperation, where: op.repository_id == ^repository.id)

      assert length(operations) == 6
      assert Enum.all?(operations, &(&1.state == :bookkeeping_complete))

      assert Repo.aggregate(from(a in AuditEvent, where: not is_nil(a.operation_id)), :count) ==
               (index + 1) * 6

      assert %Repository{last_pushed_at: %DateTime{}} = Repo.get!(Repository, repository.id)
    end
  end

  test "masking and scopes precede mutation body reads while invalid input never advances refs" do
    owner = user("private-git-owner")
    reader = user("private-git-reader")
    {_owner_key, owner_secret} = pat(owner, ["repo"])
    {_reader_key, reader_secret} = pat(reader, ["repo"])
    {_limited_key, limited_secret} = pat(owner, ["read:org"])

    request(:post, "/api/v3/user/repos", owner_secret, hd(@versions), %{
      "name" => "demo",
      "private" => true,
      "auto_init" => true
    })
    |> json_response(201)

    base = "/api/v3/repos/#{owner.username}/demo"

    for secret <- [nil, reader_secret] do
      assert request(:put, base <> "/contents/secret.txt", secret, hd(@versions), "invalid JSON").status in [
               401,
               404
             ]

      assert request(:get, base <> "/branches", secret, hd(@versions)).status == 404
    end

    assert request(
             :put,
             base <> "/contents/secret.txt",
             limited_secret,
             hd(@versions),
             "invalid JSON"
           ).status == 403

    assert request(:put, base <> "/contents/secret.txt", owner_secret, hd(@versions), %{
             "message" => "bad",
             "content" => "not base64"
           }).status == 422

    assert request(
             :put,
             base <> "/contents/secret.txt",
             owner_secret,
             hd(@versions),
             ~s({"message":"one","message":"two","content":"YQ=="})
           ).status == 400

    assert request(
             :get,
             base <> "/commits/main",
             owner_secret,
             hd(@versions),
             nil,
             "application/vnd.github.diff"
           ).status == 406

    assert request(
             :get,
             base <> "/contents/README.md",
             owner_secret,
             hd(@versions),
             nil,
             "application/vnd.github.raw+json"
           ).resp_body == "# demo\n"

    assert %{"encoding" => "base64"} =
             request(
               :get,
               base <> "/contents/README.md",
               owner_secret,
               hd(@versions),
               nil,
               "application/vnd.github.raw+json;q=0, application/json;q=1"
             )
             |> json_response(200)

    for path <- [
          "/branches/main%252Fbad",
          "/git/ref/heads%252Fmain",
          "/contents/%252e%252e/README.md",
          "/contents/docs%252Ffile"
        ] do
      assert request(:get, base <> path, owner_secret, hd(@versions)).status == 422
    end
  end

  test "visibility and PAT scope are rechecked after a slow contents body" do
    actor = user("visibility-race")
    {_key, secret} = pat(actor, ["public_repo"])

    request(:post, "/api/v3/user/repos", secret, hd(@versions), %{
      "name" => "demo",
      "auto_init" => true
    })
    |> json_response(201)

    repository = ForgeRepos.get_repository(actor.username, "demo")
    path = ForgeRepos.absolute_storage_path(repository)
    {:ok, before_oid} = GitCore.exact_ref(path, "refs/heads/main")
    count = Repo.aggregate(GitWriteOperation, :count)
    ref = make_ref()

    conn =
      build_conn()
      |> put_req_header("user-agent", "git-data-test/1.0")
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("content-type", "application/json")

    conn =
      Plug.Adapters.Test.Conn.conn(
        conn,
        :put,
        "/api/v3/repos/#{actor.username}/demo/contents/secret.txt",
        JSON.encode!(%{"message" => "race", "content" => "YQ=="})
      )

    {Plug.Adapters.Test.Conn, delegate} = conn.adapter

    conn = %{
      conn
      | adapter: {PausingBodyAdapter, %{delegate: delegate, test_pid: self(), ref: ref}}
    }

    task =
      Task.async(fn ->
        receive do
          {^ref, :start} -> FornacastAPI.Endpoint.call(conn, FornacastAPI.Endpoint.init([]))
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, {ref, :start})
    assert_receive {^ref, :body_read, request_pid}, 2_000

    Repo.update_all(from(r in Repository, where: r.id == ^repository.id),
      set: [visibility: :private]
    )

    send(request_pid, {ref, :continue_body})
    response = Task.await(task, 5_000)
    assert response.status == 403
    assert get_resp_header(response, "x-accepted-oauth-scopes") == ["repo"]
    assert {:ok, ^before_oid} = GitCore.exact_ref(path, "refs/heads/main")
    assert Repo.aggregate(GitWriteOperation, :count) == count
  end

  test "unrepresentable page values return validation rather than crashing the native boundary" do
    {base, secret, _repository} = initialized("pagination-owner")

    for endpoint <- ["branches", "commits"], page <- ["18446744073709551616", "+1", "abc", "0"] do
      response =
        request(
          :get,
          base <> "/" <> endpoint <> "?page=" <> URI.encode_www_form(page),
          secret,
          hd(@versions)
        )

      assert response.status == 422
    end
  end

  test "missing and noncommit ref targets preserve typed public errors" do
    {base, secret, _repository} = initialized("target-owner")

    file =
      request(:get, base <> "/contents/README.md", secret, hd(@versions)) |> json_response(200)

    for target <- [file["sha"], String.duplicate("f", 40)] do
      assert request(:post, base <> "/git/refs", secret, hd(@versions), %{
               "ref" => "refs/heads/bad",
               "sha" => target
             }).status == 422

      assert request(:patch, base <> "/git/refs/heads/main", secret, hd(@versions), %{
               "sha" => target
             }).status == 422

      assert request(:get, base <> "/commits/" <> target, secret, hd(@versions)).status == 404
    end
  end

  test "noncanonical Base64 padding bits are rejected before writing objects or operations" do
    {base, secret, repository} = initialized("base64-owner")
    path = ForgeRepos.absolute_storage_path(repository)

    before =
      git!(["--git-dir", path, "cat-file", "--batch-all-objects", "--batch-check=%(objectname)"])

    count = Repo.aggregate(GitWriteOperation, :count)

    assert request(:put, base <> "/contents/bad.txt", secret, hd(@versions), %{
             "message" => "bad",
             "content" => "YR=="
           }).status == 422

    assert git!([
             "--git-dir",
             path,
             "cat-file",
             "--batch-all-objects",
             "--batch-check=%(objectname)"
           ]) == before

    assert Repo.aggregate(GitWriteOperation, :count) == count
  end

  test "a post-publication bookkeeping failure recovers once without replaying the Git effect" do
    {base, secret, repository} = initialized("recovery-api-owner")
    path = ForgeRepos.absolute_storage_path(repository)
    {:ok, initial} = GitCore.exact_ref(path, "refs/heads/main")
    before_audits = Repo.aggregate(AuditEvent, :count)

    failed =
      ForgeRepos.GitWriteRecovery.with_test_complete_multi_hook(
        fn multi, _operation ->
          Ecto.Multi.run(multi, :injected_failure, fn _repo, _changes ->
            {:error, :injected_failure}
          end)
        end,
        fn ->
          request(:put, base <> "/contents/recovered.txt", secret, hd(@versions), %{
            "message" => "recover",
            "content" => "b2sK"
          })
        end
      )

    assert failed.status == 503
    {:ok, published} = GitCore.exact_ref(path, "refs/heads/main")
    refute published == initial

    operation =
      Repo.one!(
        from op in GitWriteOperation,
          where: op.repository_id == ^repository.id and op.proposed_oid == ^published
      )

    assert operation.state == :ref_advanced
    assert operation.lease_owner == nil
    assert Repo.aggregate(AuditEvent, :count) == before_audits
    assert :ok = ForgeRepos.GitWriteRecovery.reconcile_repository(repository)
    assert :ok = ForgeRepos.GitWriteRecovery.reconcile_repository(repository)
    assert Repo.get!(GitWriteOperation, operation.id).state == :bookkeeping_complete
    assert Repo.aggregate(AuditEvent, :count) == before_audits + 1
    assert {:ok, ^published} = GitCore.exact_ref(path, "refs/heads/main")

    assert request(:get, base <> "/contents/recovered.txt", secret, hd(@versions))
           |> json_response(200)
           |> Map.fetch!("content") == "b2sK"
  end

  test "read phase rechecks private masking and PAT scope before accessing Git" do
    {base, _secret, repository} = initialized("read-visibility-owner")
    owner = ForgeAccounts.get_user_by_username("read-visibility-owner")
    {_key, public_secret} = pat(owner, ["public_repo"])

    for {secret, expected} <- [{nil, 404}, {public_secret, 403}] do
      Repo.update_all(from(r in Repository, where: r.id == ^repository.id),
        set: [visibility: :public]
      )

      response =
        ForgeRepos.with_test_read_phase_hook(
          fn ->
            Repo.update_all(from(r in Repository, where: r.id == ^repository.id),
              set: [visibility: :private]
            )

            :ok
          end,
          fn -> request(:get, base <> "/contents/README.md", secret, hd(@versions)) end
        )

      assert response.status == expected
    end
  end

  test "commit time filters are inclusive and malformed dates are typed validation" do
    {base, secret, _repository} = initialized("date-filter-owner")

    signature = %{
      "name" => "Dated Author",
      "email" => "dated@example.test",
      "date" => "2026-01-02T00:00:00Z"
    }

    created =
      request(:put, base <> "/contents/dated.txt", secret, hd(@versions), %{
        "message" => "Dated commit",
        "content" => "ZGF0ZWQK",
        "author" => signature,
        "committer" => signature
      })
      |> json_response(201)

    oid = created["commit"]["sha"]

    query =
      URI.encode_query(%{"since" => "2026-01-02T00:00:00Z", "until" => "2026-01-02T00:00:00Z"})

    assert [%{"sha" => ^oid}] =
             request(:get, base <> "/commits?" <> query, secret, hd(@versions))
             |> json_response(200)

    assert [] =
             request(
               :get,
               base <> "/commits?until=2026-01-01T00%3A00%3A00Z",
               secret,
               hd(@versions)
             )
             |> json_response(200)

    assert request(:get, base <> "/commits?since=tomorrow", secret, hd(@versions)).status == 422
  end

  test "lowered body, blob and scan ceilings fail without partial data or mutation" do
    {base, secret, repository} = initialized("limit-owner")
    previous = Application.get_env(:git_core, :limits, [])
    path = ForgeRepos.absolute_storage_path(repository)
    {:ok, initial} = GitCore.exact_ref(path, "refs/heads/main")
    count = Repo.aggregate(GitWriteOperation, :count)

    try do
      Application.put_env(:git_core, :limits, Keyword.put(previous, :blob_bytes, 1))
      assert request(:get, base <> "/contents/README.md", secret, hd(@versions)).status == 413

      assert request(:put, base <> "/contents/large.txt", secret, hd(@versions), %{
               "message" => "large",
               "content" => "YWI="
             }).status == 413

      Application.put_env(:git_core, :limits, Keyword.put(previous, :contents_json_bytes, 16))

      assert request(:put, base <> "/contents/large.txt", secret, hd(@versions), %{
               "message" => "large",
               "content" => "YQ=="
             }).status == 413

      Application.put_env(:git_core, :limits, previous)

      request(:put, base <> "/contents/second.txt", secret, hd(@versions), %{
        "message" => "second",
        "content" => "YQ=="
      })
      |> json_response(201)

      Application.put_env(:git_core, :limits, Keyword.put(previous, :commit_visits, 1))
      assert request(:get, base <> "/commits", secret, hd(@versions)).status == 503
      Application.put_env(:git_core, :limits, Keyword.put(previous, :tree_entry_visits, 1))
      assert request(:get, base <> "/contents", secret, hd(@versions)).status == 503
    after
      Application.put_env(:git_core, :limits, previous)
    end

    assert Repo.aggregate(GitWriteOperation, :count) == count + 1
    {:ok, final} = GitCore.exact_ref(path, "refs/heads/main")
    assert initial != final
    assert git!(["--git-dir", path, "show", "main:second.txt"]) == "a"
  end

  defp initialized(username) do
    actor = user(username)
    {_key, secret} = pat(actor, ["repo"])

    request(:post, "/api/v3/user/repos", secret, hd(@versions), %{
      "name" => "demo",
      "auto_init" => true
    })
    |> json_response(201)

    {"/api/v3/repos/#{actor.username}/demo", secret,
     ForgeRepos.get_repository(actor.username, "demo")}
  end

  defp request(
         method,
         path,
         secret,
         version,
         body \\ nil,
         accept \\ "application/vnd.github+json"
       ) do
    conn =
      build_conn()
      |> put_req_header("user-agent", "git-data-test/1.0")
      |> put_req_header("x-github-api-version", version)
      |> put_req_header("accept", accept)

    conn = if secret, do: put_req_header(conn, "authorization", "Bearer " <> secret), else: conn
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn
    body = if is_map(body), do: Jason.encode!(body), else: body
    conn = dispatch(conn, @endpoint, method, path, body)

    if conn.status in [200, 201] and
         String.starts_with?(hd(get_resp_header(conn, "content-type")), "application/json") do
      if template = contract_path(path) do
        document =
          Path.expand("../priv/openapi/ghes-3.21-#{version}.json", __DIR__)
          |> File.read!()
          |> JSON.decode!()
          |> OpenApiSpex.OpenApi.Decode.decode()

        schema =
          document.paths
          |> Map.fetch!(template)
          |> Map.fetch!(method)
          |> Map.fetch!(:responses)
          |> Map.fetch!(Integer.to_string(conn.status))
          |> Map.fetch!(:content)
          |> Map.fetch!("application/json")
          |> Map.fetch!(:schema)

        assert {:ok, _} = OpenApiSpex.cast_value(JSON.decode!(conn.resp_body), schema, document)
      end
    end

    conn
  end

  defp contract_path(path) do
    case Regex.run(~r{\A/api/v3/repos/[^/]+/[^/]+(/[^?]*)}, path) do
      [_, suffix] ->
        suffix =
          cond do
            String.starts_with?(suffix, "/branches/") -> "/branches/{branch}"
            String.starts_with?(suffix, "/git/ref/") -> "/git/ref/{ref}"
            String.starts_with?(suffix, "/git/refs/") -> "/git/refs/{ref}"
            String.starts_with?(suffix, "/commits/") -> "/commits/{ref}"
            String.starts_with?(suffix, "/contents/") -> "/contents/{path}"
            true -> suffix
          end

        "/repos/{owner}/{repo}" <> suffix

      _ ->
        nil
    end
  end

  defp git!(args) do
    {output, status} = System.cmd("git", args, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
