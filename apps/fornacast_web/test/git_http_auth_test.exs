defmodule FornacastWeb.GitHTTPAuthTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint FornacastWeb.Endpoint
  @challenge ~s(Basic realm="Fornacast Git")

  setup do
    Fornacast.Setup.force_initialized!()
    reset_database!()

    on_exit(&Fornacast.Setup.reset!/0)

    :ok
  end

  @tag :tmp_dir
  test "a personal API key clones a private repository over smart HTTP", %{tmp_dir: tmp_dir} do
    with_storage_root(tmp_dir)
    share_database!()

    {user, repository} = create_user_and_repository(:private)

    assert {:ok, _api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "git clone",
               "scopes" => ["repo"]
             })

    work_path = Path.join(tmp_dir, "work")
    seed_repository(repository, work_path)

    for commit_number <- 1..60 do
      File.write!(
        Path.join(work_path, "history.txt"),
        "history #{commit_number}\n",
        [:append]
      )

      git!(["-C", work_path, "add", "history.txt"])
      git!(["-C", work_path, "commit", "-m", "History #{commit_number}"])
    end

    git!(["-C", work_path, "push", "origin", "main"])

    port = start_http_server()
    clone_path = Path.join(tmp_dir, "clone")
    remote_url = "http://127.0.0.1:#{port}/alice/demo.git"
    askpass_path = Path.join(tmp_dir, "git-askpass")

    File.write!(
      askpass_path,
      ~S|#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' "$FORNACAST_GIT_USERNAME" ;;
  *) printf '%s\n' "$FORNACAST_GIT_API_KEY" ;;
esac
|
    )

    File.chmod!(askpass_path, 0o700)

    {output, status} =
      git(["clone", remote_url, clone_path], [
        {"GIT_ASKPASS", askpass_path},
        {"GIT_ASKPASS_REQUIRE", "force"},
        {"FORNACAST_GIT_USERNAME", "alice"},
        {"FORNACAST_GIT_API_KEY", secret}
      ])

    assert status == 0, output
    assert File.read!(Path.join(clone_path, "README.md")) == "# Demo\n"
    assert git!(["-C", clone_path, "remote", "get-url", "origin"]) == remote_url
    refute git!(["-C", clone_path, "config", "--get", "remote.origin.url"]) =~ secret

    File.write!(Path.join(work_path, "README.md"), "# Demo\n\nPulled update\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Update README"])
    git!(["-C", work_path, "push", "origin", "main"])

    {pull_output, pull_status} =
      git(["-C", clone_path, "pull", "origin", "main"], [
        {"GIT_ASKPASS", askpass_path},
        {"GIT_ASKPASS_REQUIRE", "force"},
        {"FORNACAST_GIT_USERNAME", "alice"},
        {"FORNACAST_GIT_API_KEY", secret}
      ])

    assert pull_status == 0, pull_output
    assert File.read!(Path.join(clone_path, "README.md")) == "# Demo\n\nPulled update\n"
  end

  @tag :tmp_dir
  test "a public repository remains cloneable without credentials", %{tmp_dir: tmp_dir} do
    with_storage_root(tmp_dir)
    share_database!()

    {_user, repository} = create_user_and_repository(:public)
    seed_repository(repository, Path.join(tmp_dir, "work"))
    port = start_http_server()
    clone_path = Path.join(tmp_dir, "clone")

    {output, status} =
      git(["clone", "http://127.0.0.1:#{port}/alice/demo.git", clone_path])

    assert status == 0, output
    assert File.read!(Path.join(clone_path, "README.md")) == "# Demo\n"
  end

  @tag :tmp_dir
  test "a public_repo API key clones a public repository over smart HTTP", %{tmp_dir: tmp_dir} do
    with_storage_root(tmp_dir)
    share_database!()

    {user, repository} = create_user_and_repository(:public)

    assert {:ok, _api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "public git clone",
               "scopes" => ["public_repo"]
             })

    seed_repository(repository, Path.join(tmp_dir, "work"))
    port = start_http_server()
    clone_path = Path.join(tmp_dir, "clone")
    remote_url = "http://127.0.0.1:#{port}/alice/demo.git"
    authorization = "Authorization: Basic " <> Base.encode64("alice:#{secret}")

    {output, status} =
      git(["-c", "http.extraHeader=#{authorization}", "clone", remote_url, clone_path])

    assert status == 0, output
    assert File.read!(Path.join(clone_path, "README.md")) == "# Demo\n"
    assert git!(["-C", clone_path, "remote", "get-url", "origin"]) == remote_url
    refute git!(["-C", clone_path, "config", "--get", "remote.origin.url"]) =~ secret
  end

  test "private fetch rejects account passwords with a Basic challenge" do
    create_user_and_repository(:private)

    response = request_info_refs("alice", "correct horse battery staple")

    assert response(response, 401) == "Authentication required.\n"
    assert Plug.Conn.get_resp_header(response, "www-authenticate") == [@challenge]
  end

  test "Git discovery applies classic and legacy PAT scopes using repository visibility" do
    {user, _private_repository} = create_user_and_repository(:private)

    assert {:ok, _public_repository} =
             ForgeRepos.create_repository(user, %{
               name: "Public Demo",
               slug: "public-demo",
               description: "Public Git HTTP scope test",
               visibility: :public
             })

    scope_cases = [
      {"repo", :public, :read, 200},
      {"repo", :private, :read, 200},
      {"public_repo", :public, :read, 200},
      {"public_repo", :private, :read, 403},
      {"repo:read", :private, :read, 200},
      {"repo:write", :private, :read, 200},
      {"read:org", :public, :read, 403},
      {"write:org", :public, :read, 403},
      {"repo", :private, :write, 200},
      {"public_repo", :public, :write, 200},
      {"public_repo", :private, :write, 403},
      {"repo:write", :private, :write, 200},
      {"repo:read", :private, :write, 403}
    ]

    for {{scope, visibility, operation, expected_status}, index} <-
          Enum.with_index(scope_cases, 1) do
      secret = create_scope_key_secret!(user, scope, index)

      repository_path =
        if visibility == :public, do: "/alice/public-demo.git", else: "/alice/demo.git"

      service = if operation == :read, do: "git-upload-pack", else: "git-receive-pack"
      case_name = "#{scope} #{visibility} #{operation}"

      response = request_info_refs("alice", secret, repository_path, service)

      assert response.status == expected_status, case_name

      if expected_status == 200 do
        assert response.resp_body =~ "# service=#{service}", case_name
      else
        assert Plug.Conn.get_resp_header(response, "www-authenticate") == [], case_name
      end
    end
  end

  test "private fetch rejects invalid API keys with a Basic challenge" do
    {user, _repository} = create_user_and_repository(:private)

    assert {:ok, _api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "git clone",
               "scopes" => ["repo"]
             })

    credentials = [
      {"invalid API key", "alice", "fc_pat_invalid"},
      {"wrong username", "bob", secret}
    ]

    for {case_name, username, password} <- credentials do
      response = request_info_refs(username, password)

      assert response(response, 401) == "Authentication required.\n", case_name
      assert Plug.Conn.get_resp_header(response, "www-authenticate") == [@challenge], case_name
    end
  end

  test "private fetch rejects revoked, expired, and disabled-owner API keys with a Basic challenge" do
    {user, _repository} = create_user_and_repository(:private)

    assert {:ok, api_key, revoked_secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "revoked",
               "scopes" => ["repo"]
             })

    assert {:ok, _api_key} = ForgeAccounts.revoke_api_key(user, api_key.id)

    assert {:ok, _api_key, expired_secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "expired",
               "scopes" => ["repo"],
               "expires_at" => DateTime.add(DateTime.utc_now(:second), -60, :second)
             })

    assert {:ok, disabled_owner} =
             ForgeAccounts.create_user(%{
               username: "disabled",
               email: "disabled-git-http@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _api_key, disabled_secret} =
             ForgeAccounts.create_api_key(disabled_owner, %{
               "name" => "disabled owner",
               "scopes" => ["repo"]
             })

    assert {:ok, _disabled_owner} =
             disabled_owner
             |> ForgeAccounts.User.state_changeset(%{state: :disabled})
             |> Fornacast.Repo.update()

    credentials = [
      {"revoked", "alice", revoked_secret},
      {"expired", "alice", expired_secret},
      {"disabled owner", "disabled", disabled_secret}
    ]

    for {case_name, username, secret} <- credentials do
      response = request_info_refs(username, secret)

      assert response(response, 401) == "Authentication required.\n", case_name
      assert Plug.Conn.get_resp_header(response, "www-authenticate") == [@challenge], case_name
    end
  end

  test "private fetch accepts a case-insensitive Basic scheme with horizontal whitespace" do
    {user, _repository} = create_user_and_repository(:private)

    assert {:ok, _api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "git clone",
               "scopes" => ["repo"]
             })

    encoded = Base.encode64("alice:#{secret}")

    response =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", " \tBAsIc\t#{encoded} \t")
      |> get("/alice/demo.git/info/refs?service=git-upload-pack")

    assert response(response, 200) =~ "# service=git-upload-pack"
  end

  test "public fetch validates an Authorization header when one is provided" do
    create_user_and_repository(:public)

    response = request_info_refs("alice", "incorrect password")

    assert response(response, 401) == "Authentication required.\n"
    assert Plug.Conn.get_resp_header(response, "www-authenticate") == [@challenge]
  end

  test "public fetch rejects unsupported, malformed, and multiple Authorization headers" do
    {user, _repository} = create_user_and_repository(:public)

    assert {:ok, _api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "valid header",
               "scopes" => ["repo"]
             })

    headers = [
      {"Bearer authorization", [{"authorization", "Bearer token"}]},
      {"malformed Basic authorization", [{"authorization", "Basic not-base64"}]},
      {"terminal newline",
       [{"authorization", "Basic " <> Base.encode64("alice:#{secret}") <> "\n"}]},
      {"multiple authorization headers",
       [
         {"authorization", "Basic " <> Base.encode64("alice:fc_pat_invalid")},
         {"authorization", "Basic " <> Base.encode64("alice:fc_pat_also_invalid")}
       ]}
    ]

    for {case_name, authorization_headers} <- headers do
      response =
        build_conn()
        |> Map.update!(:req_headers, &(authorization_headers ++ &1))
        |> get("/alice/demo.git/info/refs?service=git-upload-pack")

      assert response(response, 401) == "Authentication required.\n", case_name
      assert Plug.Conn.get_resp_header(response, "www-authenticate") == [@challenge], case_name
    end
  end

  test "anonymous upload-pack does not reveal whether a private repository exists" do
    create_user_and_repository(:private)

    for path <- ["/alice/demo.git", "/nobody/missing.git"] do
      discovery = get(build_conn(), "#{path}/info/refs?service=git-upload-pack")
      upload = upload_pack_request(build_conn(), path, "0000")

      assert response(discovery, 401) == "Authentication required.\n"
      assert Plug.Conn.get_resp_header(discovery, "www-authenticate") == [@challenge]
      assert response(upload, 401) == "Authentication required.\n"
      assert Plug.Conn.get_resp_header(upload, "www-authenticate") == [@challenge]
    end
  end

  test "authenticated upload-pack does not distinguish unauthorized private and missing repositories" do
    create_user_and_repository(:private)

    assert {:ok, bob} =
             ForgeAccounts.create_user(%{
               username: "bob",
               email: "bob-git-http@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _api_key, secret} =
             ForgeAccounts.create_api_key(bob, %{
               "name" => "git clone",
               "scopes" => ["repo"]
             })

    authorization = "Basic " <> Base.encode64("bob:#{secret}")

    for path <- ["/alice/demo.git", "/nobody/missing.git"] do
      discovery =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", authorization)
        |> get("#{path}/info/refs?service=git-upload-pack")

      upload =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", authorization)
        |> upload_pack_request(path, "0000")

      assert response(discovery, 404) == "Repository not found.\n"
      assert response(upload, 404) == "Repository not found.\n"
    end
  end

  test "private Git endpoints mask inaccessible repositories before checking PAT scope" do
    create_user_and_repository(:private)

    assert {:ok, bob} =
             ForgeAccounts.create_user(%{
               username: "bob",
               email: "bob-insufficient-git-scope@example.com",
               password: "correct horse battery staple"
             })

    secret = create_scope_key_secret!(bob, "read:org", 99)

    for service <- ["git-upload-pack", "git-receive-pack"] do
      response = request_info_refs("bob", secret, "/alice/demo.git", service)

      assert response(response, 404) == "Repository not found.\n", service
      assert Plug.Conn.get_resp_header(response, "www-authenticate") == [], service
    end
  end

  test "public upload-pack rejects a request larger than the configured limit" do
    create_user_and_repository(:public)

    original_limit = Application.get_env(:fornacast_web, :git_upload_pack_max_bytes)
    Application.put_env(:fornacast_web, :git_upload_pack_max_bytes, 8)

    on_exit(fn ->
      if is_nil(original_limit) do
        Application.delete_env(:fornacast_web, :git_upload_pack_max_bytes)
      else
        Application.put_env(:fornacast_web, :git_upload_pack_max_bytes, original_limit)
      end
    end)

    response = upload_pack_request(build_conn(), "/alice/demo.git", "123456789")

    assert response(response, 413) == "Git request is too large.\n"
  end

  defp create_user_and_repository(visibility) do
    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-git-http@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, repository} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "Git HTTP authentication test",
               visibility: visibility
             })

    {user, repository}
  end

  defp request_info_refs(
         username,
         password,
         repository_path \\ "/alice/demo.git",
         service \\ "git-upload-pack"
       ) do
    build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64("#{username}:#{password}")
    )
    |> get("#{repository_path}/info/refs?service=#{service}")
  end

  defp create_scope_key_secret!(user, scope, index)
       when scope in ["repo:read", "repo:write"] do
    secret = "fc_pat_legacy_scope_#{index}"

    %ForgeAccounts.APIKey{
      user_id: user.id,
      name: "legacy scope case #{index}",
      token_prefix: String.slice(secret, 0, 15),
      token_hash: ForgeAccounts.APIKey.hash(secret),
      scopes: %{scope => true}
    }
    |> Fornacast.Repo.insert!()

    secret
  end

  defp create_scope_key_secret!(user, scope, index) do
    assert {:ok, _api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "classic scope case #{index}",
               "scopes" => [scope]
             })

    secret
  end

  defp upload_pack_request(conn, repository_path, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/x-git-upload-pack-request")
    |> post("#{repository_path}/git-upload-pack", body)
  end

  defp seed_repository(repository, work_path) do
    git!(["init", work_path])
    File.write!(Path.join(work_path, "README.md"), "# Demo\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])

    git!([
      "-C",
      work_path,
      "remote",
      "add",
      "origin",
      ForgeRepos.absolute_storage_path(repository)
    ])

    git!(["-C", work_path, "push", "origin", "main"])
  end

  defp start_http_server do
    pid =
      start_supervised!(
        {Bandit,
         plug: FornacastWeb.Endpoint,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp with_storage_root(tmp_dir) do
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)
  end

  defp git!(args) do
    case git(args) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end

  defp git(args, extra_env \\ []) do
    env =
      [
        {"GIT_AUTHOR_NAME", "Fornacast Test"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_NAME", "Fornacast Test"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"},
        {"GIT_TERMINAL_PROMPT", "0"}
      ] ++ extra_env

    System.cmd("git", args, stderr_to_stdout: true, env: env)
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(reset_tables(), fn table ->
          Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{table}", [])
        end)
    end
  end

  defp share_database! do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      Ecto.Adapters.SQL.Sandbox.mode(Fornacast.Repo, {:shared, self()})
    end
  end

  defp reset_tables do
    [
      "audit_events",
      "repository_collaborators",
      "repositories",
      "organization_members",
      "api_keys",
      "ssh_keys",
      "users"
    ]
  end
end
