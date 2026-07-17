defmodule FornacastWeb.GitHTTPPushTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import ExUnit.CaptureLog
  alias Fornacast.{AuditEvent, Repo}

  @endpoint FornacastWeb.Endpoint
  @challenge ~s(Basic realm="Fornacast Git")

  setup do
    Fornacast.Setup.force_initialized!()
    reset_database!()
    on_exit(&Fornacast.Setup.reset!/0)
    :ok
  end

  @tag :tmp_dir
  test "a repo:write API key pushes over smart HTTP and records the push once", %{
    tmp_dir: tmp_dir
  } do
    with_storage_root(tmp_dir)
    share_database!()
    {user, repository} = create_user_and_repository("alice")

    assert {:ok, _api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "git push",
               "scopes" => ["repo:write"]
             })

    work_path = Path.join(tmp_dir, "work")
    git!(["init", work_path])
    File.write!(Path.join(work_path, "README.md"), "# HTTP push\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])

    port = start_http_server()
    remote_url = "http://127.0.0.1:#{port}/alice/demo.git"
    git!(["-C", work_path, "remote", "add", "origin", remote_url])
    askpass_path = write_askpass!(tmp_dir)

    advertisement =
      build_conn()
      |> maybe_authorize({"alice", secret})
      |> get("/alice/demo.git/info/refs?service=git-receive-pack")

    assert response(advertisement, 200) =~ "# service=git-receive-pack"

    assert Plug.Conn.get_resp_header(advertisement, "content-type") ==
             ["application/x-git-receive-pack-advertisement"]

    git!(["-C", work_path, "push", "-u", "origin", "main"], [
      {"GIT_ASKPASS", askpass_path},
      {"GIT_ASKPASS_REQUIRE", "force"},
      {"FORNACAST_GIT_USERNAME", "alice"},
      {"FORNACAST_GIT_API_KEY", secret}
    ])

    assert {:ok, [%GitCore.Ref{name: "refs/heads/main"}]} =
             repository |> ForgeRepos.absolute_storage_path() |> GitCore.branches()

    assert %DateTime{} = Repo.get!(ForgeRepos.Repository, repository.id).last_pushed_at
    events = Repo.all(AuditEvent)

    assert [%AuditEvent{action: "repository.pushed", actor_user_id: actor_id, metadata: metadata}] =
             events

    assert actor_id == user.id
    assert metadata["refs"] == ["refs/heads/main"]
    refute git!(["-C", work_path, "remote", "get-url", "origin"]) =~ secret
  end

  test "receive-pack advertisement requires a valid repo:write API key" do
    {alice, _repository} = create_user_and_repository("alice")
    {bob, _repository} = create_user_and_repository("bob", "other")

    assert {:ok, _key, read_secret} =
             ForgeAccounts.create_api_key(alice, %{"name" => "read", "scopes" => ["repo:read"]})

    assert {:ok, revoked_key, revoked_secret} =
             ForgeAccounts.create_api_key(alice, %{
               "name" => "revoked",
               "scopes" => ["repo:write"]
             })

    assert {:ok, _key} = ForgeAccounts.revoke_api_key(alice, revoked_key.id)

    assert {:ok, _key, bob_secret} =
             ForgeAccounts.create_api_key(bob, %{"name" => "write", "scopes" => ["repo:write"]})

    credentials = [
      {"missing", nil},
      {"password", {"alice", "correct horse battery staple"}},
      {"read only", {"alice", read_secret}},
      {"revoked", {"alice", revoked_secret}},
      {"unauthorized user", {"bob", bob_secret}}
    ]

    for {name, credentials} <- credentials do
      conn = maybe_authorize(build_conn(), credentials)
      response = get(conn, "/alice/demo.git/info/refs?service=git-receive-pack")
      assert response(response, 401) == "Authentication required.\n", name
      assert Plug.Conn.get_resp_header(response, "www-authenticate") == [@challenge], name
    end
  end

  test "receive-pack POST requires authentication and returns the smart HTTP result type" do
    {user, _repository} = create_user_and_repository("alice")

    assert {:ok, _key, secret} =
             ForgeAccounts.create_api_key(user, %{"name" => "write", "scopes" => ["repo:write"]})

    unauthenticated =
      build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/x-git-receive-pack-request")
      |> post("/alice/demo.git/git-receive-pack", "0000")

    assert response(unauthenticated, 401) == "Authentication required.\n"

    authenticated =
      build_conn()
      |> maybe_authorize({"alice", secret})
      |> Plug.Conn.put_req_header("content-type", "application/x-git-receive-pack-request")
      |> post("/alice/demo.git/git-receive-pack", "0000")

    assert response(authenticated, 400) == "Incomplete Git request.\n"
  end

  test "unauthenticated receive-pack does not reveal whether a repository exists" do
    create_user_and_repository("alice")
    existing = get(build_conn(), "/alice/demo.git/info/refs?service=git-receive-pack")
    missing = get(build_conn(), "/nobody/missing.git/info/refs?service=git-receive-pack")

    assert response(existing, 401) == "Authentication required.\n"
    assert response(missing, 401) == "Authentication required.\n"
    assert Plug.Conn.get_resp_header(missing, "www-authenticate") == [@challenge]
  end

  test "receive-pack POST rejects unsupported content types" do
    {user, _repository} = create_user_and_repository("alice")

    assert {:ok, _key, secret} =
             ForgeAccounts.create_api_key(user, %{"name" => "write", "scopes" => ["repo:write"]})

    response =
      build_conn()
      |> maybe_authorize({"alice", secret})
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
      |> post("/alice/demo.git/git-receive-pack", "0000")

    assert response(response, 415) == "Unsupported Git content type.\n"
  end

  test "receive-pack POST rejects a request larger than the configured limit" do
    {user, _repository} = create_user_and_repository("alice")

    assert {:ok, _key, secret} =
             ForgeAccounts.create_api_key(user, %{"name" => "write", "scopes" => ["repo:write"]})

    original = Application.get_env(:fornacast_web, :git_receive_pack_max_bytes)
    Application.put_env(:fornacast_web, :git_receive_pack_max_bytes, 8)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:fornacast_web, :git_receive_pack_max_bytes),
        else: Application.put_env(:fornacast_web, :git_receive_pack_max_bytes, original)
    end)

    response =
      build_conn()
      |> maybe_authorize({"alice", secret})
      |> Plug.Conn.put_req_header("content-type", "application/x-git-receive-pack-request")
      |> post("/alice/demo.git/git-receive-pack", "123456789")

    assert response(response, 413) == "Git request is too large.\n"
  end

  test "push bookkeeping rolls back when its audit event cannot be written" do
    {_user, repository} = create_user_and_repository("alice")

    log =
      capture_log(fn ->
        assert :ok =
                 GitTransport.ReceivePack.record_push(
                   %{id: "not-an-integer"},
                   repository,
                   [{"refs/heads/main", "ok", nil}]
                 )
      end)

    assert Repo.get!(ForgeRepos.Repository, repository.id).last_pushed_at == nil
    assert Repo.all(AuditEvent) == []
    assert log =~ "Git receive-pack audit update failed"
  end

  defp create_user_and_repository(username, repo_slug \\ "demo") do
    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: username,
               email: "#{username}-http-push@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, repository} =
             ForgeRepos.create_repository(user, %{
               name: repo_slug,
               slug: repo_slug,
               visibility: :private
             })

    {user, repository}
  end

  defp maybe_authorize(conn, nil), do: conn

  defp maybe_authorize(conn, {username, secret}) do
    Plug.Conn.put_req_header(
      conn,
      "authorization",
      "Basic " <> Base.encode64("#{username}:#{secret}")
    )
  end

  defp write_askpass!(tmp_dir) do
    path = Path.join(tmp_dir, "git-askpass")
    File.write!(path, ~S|#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' "$FORNACAST_GIT_USERNAME" ;;
  *) printf '%s\n' "$FORNACAST_GIT_API_KEY" ;;
esac
|)
    File.chmod!(path, 0o700)
    path
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
    original = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original) end)
  end

  defp git!(args, extra_env \\ []) do
    env =
      [
        {"GIT_AUTHOR_NAME", "Fornacast Test"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_NAME", "Fornacast Test"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"},
        {"GIT_TERMINAL_PROMPT", "0"}
      ] ++ extra_env

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(
          ~w(audit_events repository_collaborators repositories organization_members api_keys ssh_keys users),
          fn table ->
            Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
          end
        )
    end
  end

  defp share_database! do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end
  end
end
