defmodule FornacastWeb.GitHTTPPushTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  alias ForgeRepos.GitWriteOperation
  alias Fornacast.{AuditEvent, Repo}

  @endpoint FornacastWeb.Endpoint
  @challenge ~s(Basic realm="Fornacast Git")
  @git_http_post_buffer 1024 * 1024

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

    {_api_key, secret} = insert_legacy_api_key!(user, "repo:write", "git push")

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

    assert [
             %AuditEvent{
               action: "repository.pushed",
               actor_user_id: actor_id,
               request_id: request_id,
               operation_id: operation_id,
               metadata: metadata
             }
           ] =
             events

    assert actor_id == user.id
    assert is_binary(request_id) and request_id != ""
    assert String.starts_with?(operation_id, "git_write:")
    assert metadata["ref"] == "refs/heads/main"
    assert metadata["result"] == "success"
    refute git!(["-C", work_path, "remote", "get-url", "origin"]) =~ secret
  end

  @tag :tmp_dir
  test "a large smart HTTP push continues after the receive-pack probe", %{tmp_dir: tmp_dir} do
    with_storage_root(tmp_dir)
    share_database!()
    {user, repository} = create_user_and_repository("alice")
    {_api_key, secret} = insert_legacy_api_key!(user, "repo:write", "large git push")

    work_path = Path.join(tmp_dir, "large-work")
    git!(["init", work_path])

    File.write!(
      Path.join(work_path, "large.bin"),
      :crypto.strong_rand_bytes(@git_http_post_buffer * 2)
    )

    git!(["-C", work_path, "add", "large.bin"])
    git!(["-C", work_path, "commit", "-m", "Large initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])

    port = start_http_server()
    remote_url = "http://127.0.0.1:#{port}/alice/demo.git"
    git!(["-C", work_path, "remote", "add", "origin", remote_url])
    askpass_path = write_askpass!(tmp_dir)

    # Pin Git's documented default so host configuration cannot skip the
    # large-request probe and chunked upload path exercised by this test.
    git!(
      [
        "-c",
        "http.postBuffer=#{@git_http_post_buffer}",
        "-C",
        work_path,
        "push",
        "-u",
        "origin",
        "main"
      ],
      [
        {"GIT_ASKPASS", askpass_path},
        {"GIT_ASKPASS_REQUIRE", "force"},
        {"FORNACAST_GIT_USERNAME", "alice"},
        {"FORNACAST_GIT_API_KEY", secret}
      ]
    )

    assert {:ok, [%GitCore.Ref{name: "refs/heads/main"}]} =
             repository |> ForgeRepos.absolute_storage_path() |> GitCore.branches()
  end

  @tag :tmp_dir
  test "the same client request ID cannot collide across actors and repositories", %{
    tmp_dir: tmp_dir
  } do
    with_storage_root(tmp_dir)
    share_database!()
    {alice, alice_repository} = create_user_and_repository("alice")
    {bob, bob_repository} = create_user_and_repository("bob", "other")
    {_alice_key, alice_secret} = insert_legacy_api_key!(alice, "repo:write", "alice push")
    {_bob_key, bob_secret} = insert_legacy_api_key!(bob, "repo:write", "bob push")
    alice_oid = create_commit(alice_repository, "alice")
    bob_oid = create_commit(bob_repository, "bob")
    external_request_id = "shared-client-request-id-12345"
    test_pid = self()

    native = fn path, "PACK", [{_old_oid, proposed_oid, target_ref}] ->
      git!(["--git-dir=#{path}", "update-ref", target_ref, proposed_oid])
      send(test_pid, {:http_native_invoked, path})
      {:ok, [{target_ref, "ok", nil}]}
    end

    [alice_response, bob_response] =
      GitTransport.ReceivePack.with_test_native(native, fn ->
        [
          receive_pack_post(
            "alice",
            "demo",
            alice_secret,
            external_request_id,
            receive_pack_body(alice_oid)
          ),
          receive_pack_post(
            "bob",
            "other",
            bob_secret,
            external_request_id,
            receive_pack_body(bob_oid)
          )
        ]
      end)

    assert response(alice_response, 200) =~ "ok refs/heads/main"
    assert response(bob_response, 200) =~ "ok refs/heads/main"
    assert_receive {:http_native_invoked, alice_path}
    assert_receive {:http_native_invoked, bob_path}
    assert alice_path == ForgeRepos.absolute_storage_path(alice_repository)
    assert bob_path == ForgeRepos.absolute_storage_path(bob_repository)

    assert [alice_operation, bob_operation] =
             GitWriteOperation
             |> Repo.all()
             |> Enum.sort_by(& &1.repository_id)

    assert alice_operation.repository_id == alice_repository.id
    assert bob_operation.repository_id == bob_repository.id
    refute alice_operation.request_id == bob_operation.request_id

    for operation <- [alice_operation, bob_operation] do
      assert byte_size(operation.request_id) <= 255
      refute operation.request_id == external_request_id
      refute inspect(operation) =~ external_request_id
    end

    assert [alice_audit, bob_audit] =
             AuditEvent
             |> Repo.all()
             |> Enum.sort_by(& &1.target_id)

    for audit <- [alice_audit, bob_audit] do
      refute audit.request_id == external_request_id
      refute audit.operation_id == external_request_id
      refute JSON.encode!(audit.metadata) =~ external_request_id
      refute inspect(audit) =~ external_request_id
    end
  end

  test "HTTP batch metadata distinguishes a client request ID from a generated response ID" do
    request_id = "client-request-id-12345"

    assert request_id ==
             build_conn()
             |> Plug.Conn.put_req_header("x-request-id", request_id)
             |> FornacastWeb.RequestMetadata.external_request_id()

    generated = Plug.RequestId.call(build_conn(), Plug.RequestId.init([]))
    assert [_generated_response_id] = Plug.Conn.get_resp_header(generated, "x-request-id")
    assert is_nil(FornacastWeb.RequestMetadata.external_request_id(generated))

    assert is_nil(
             build_conn()
             |> Plug.Conn.put_req_header("x-request-id", "too-short")
             |> FornacastWeb.RequestMetadata.external_request_id()
           )
  end

  @tag :tmp_dir
  test "the same actor and repository replay the client request as one durable batch", %{
    tmp_dir: tmp_dir
  } do
    with_storage_root(tmp_dir)
    share_database!()
    {alice, repository} = create_user_and_repository("alice")
    {_api_key, secret} = insert_legacy_api_key!(alice, "repo:write", "replay push")
    first_oid = create_commit(repository, "first")
    second_oid = create_commit(repository, "second")
    external_request_id = "replayed-client-request-id-123"
    path = ForgeRepos.absolute_storage_path(repository)
    test_pid = self()

    native = fn ^path, "PACK", [{_old_oid, proposed_oid, target_ref}] ->
      git!(["--git-dir=#{path}", "update-ref", target_ref, proposed_oid])
      send(test_pid, {:replay_native_invoked, proposed_oid})
      {:ok, [{target_ref, "ok", nil}]}
    end

    first_response =
      GitTransport.ReceivePack.with_test_native(native, fn ->
        receive_pack_post(
          "alice",
          "demo",
          secret,
          external_request_id,
          receive_pack_body(first_oid)
        )
      end)

    assert response(first_response, 200) =~ "ok refs/heads/main"
    assert_receive {:replay_native_invoked, ^first_oid}

    assert %GitWriteOperation{request_id: operation_batch_id} =
             Repo.one!(GitWriteOperation)

    assert {:error, :conflict} =
             ForgeRepos.prepare_receive_pack_operations(
               alice,
               repository,
               operation_batch_id,
               [{first_oid, second_oid, "refs/heads/main"}],
               System.monotonic_time(:millisecond) + 10_000
             )

    second_response =
      GitTransport.ReceivePack.with_test_native(native, fn ->
        receive_pack_post(
          "alice",
          "demo",
          secret,
          external_request_id,
          receive_pack_body(second_oid, first_oid)
        )
      end)

    assert response(second_response, 200) =~ "ng refs/heads/main Git receive-pack unavailable"
    refute_receive {:replay_native_invoked, _proposed_oid}

    assert [%GitWriteOperation{request_id: ^operation_batch_id, proposed_oid: ^first_oid}] =
             Repo.all(GitWriteOperation)

    assert [%AuditEvent{request_id: ^operation_batch_id}] = Repo.all(AuditEvent)
    assert {:ok, ^first_oid} = GitCore.exact_ref(path, "refs/heads/main")
  end

  test "receive-pack advertisement requires a valid repo:write API key" do
    {alice, _repository} = create_user_and_repository("alice")

    {_key, read_secret} = insert_legacy_api_key!(alice, "repo:read", "read")

    {revoked_key, revoked_secret} = insert_legacy_api_key!(alice, "repo:write", "revoked")

    assert {:ok, _key} = ForgeAccounts.revoke_api_key(alice, revoked_key.id)

    credentials = [
      {"missing", nil, 401, "Authentication required.\n"},
      {"read only", {"alice", read_secret}, 403, "Insufficient API key scope.\n"},
      {"revoked", {"alice", revoked_secret}, 401, "Authentication required.\n"}
    ]

    for {name, credentials, expected_status, expected_body} <- credentials do
      conn = maybe_authorize(build_conn(), credentials)
      response = get(conn, "/alice/demo.git/info/refs?service=git-receive-pack")
      assert response(response, expected_status) == expected_body, name

      expected_challenge = if expected_status == 401, do: [@challenge], else: []
      assert Plug.Conn.get_resp_header(response, "www-authenticate") == expected_challenge, name
    end
  end

  @tag :tmp_dir
  test "an account password pushes over smart HTTP", %{tmp_dir: tmp_dir} do
    with_storage_root(tmp_dir)
    share_database!()
    {_user, repository} = create_user_and_repository("alice")

    work_path = Path.join(tmp_dir, "password-work")
    git!(["init", work_path])
    File.write!(Path.join(work_path, "README.md"), "# Password push\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Initial password push"])
    git!(["-C", work_path, "branch", "-M", "main"])

    port = start_http_server()
    remote_url = "http://127.0.0.1:#{port}/alice/demo.git"
    git!(["-C", work_path, "remote", "add", "origin", remote_url])
    askpass_path = write_askpass!(tmp_dir)

    git!(["-C", work_path, "push", "-u", "origin", "main"], [
      {"GIT_ASKPASS", askpass_path},
      {"GIT_ASKPASS_REQUIRE", "force"},
      {"FORNACAST_GIT_USERNAME", "alice"},
      {"FORNACAST_GIT_API_KEY", "correct horse battery staple"}
    ])

    assert {:ok, [%GitCore.Ref{name: "refs/heads/main"}]} =
             repository |> ForgeRepos.absolute_storage_path() |> GitCore.branches()
  end

  test "receive-pack POST requires authentication and returns the smart HTTP result type" do
    {user, _repository} = create_user_and_repository("alice")

    {_key, secret} = insert_legacy_api_key!(user, "repo:write", "write")

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

    assert response(authenticated, 200) == ""

    assert Plug.Conn.get_resp_header(authenticated, "content-type") ==
             ["application/x-git-receive-pack-result"]
  end

  test "unauthenticated receive-pack does not reveal whether a repository exists" do
    create_user_and_repository("alice")
    existing = get(build_conn(), "/alice/demo.git/info/refs?service=git-receive-pack")
    missing = get(build_conn(), "/nobody/missing.git/info/refs?service=git-receive-pack")

    assert response(existing, 401) == "Authentication required.\n"
    assert response(missing, 401) == "Authentication required.\n"
    assert Plug.Conn.get_resp_header(missing, "www-authenticate") == [@challenge]
  end

  test "authenticated receive-pack does not distinguish an unauthorized private repository from missing" do
    create_user_and_repository("alice")
    {bob, _repository} = create_user_and_repository("bob", "other")

    {_key, secret} = insert_legacy_api_key!(bob, "repo:write", "write")

    for path <- [
          "/alice/demo.git/info/refs?service=git-receive-pack",
          "/nobody/missing.git/info/refs?service=git-receive-pack"
        ] do
      response = build_conn() |> maybe_authorize({"bob", secret}) |> get(path)
      assert response(response, 404) == "Repository not found.\n"
    end

    for path <- ["/alice/demo.git/git-receive-pack", "/nobody/missing.git/git-receive-pack"] do
      response =
        build_conn()
        |> maybe_authorize({"bob", secret})
        |> Plug.Conn.put_req_header("content-type", "application/x-git-receive-pack-request")
        |> post(path, "0000")

      assert response(response, 404) == "Repository not found.\n"
    end
  end

  test "receive-pack POST rejects unsupported content types" do
    {user, _repository} = create_user_and_repository("alice")

    {_key, secret} = insert_legacy_api_key!(user, "repo:write", "write")

    response =
      build_conn()
      |> maybe_authorize({"alice", secret})
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
      |> post("/alice/demo.git/git-receive-pack", "0000")

    assert response(response, 415) == "Unsupported Git content type.\n"
  end

  test "receive-pack POST rejects a request larger than the configured limit" do
    {user, _repository} = create_user_and_repository("alice")

    {_key, secret} = insert_legacy_api_key!(user, "repo:write", "write")

    original = Application.get_env(:git_transport, :receive_pack_max_bytes)
    Application.put_env(:git_transport, :receive_pack_max_bytes, 8)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:git_transport, :receive_pack_max_bytes),
        else: Application.put_env(:git_transport, :receive_pack_max_bytes, original)
    end)

    response =
      build_conn()
      |> maybe_authorize({"alice", secret})
      |> Plug.Conn.put_req_header("content-type", "application/x-git-receive-pack-request")
      |> post("/alice/demo.git/git-receive-pack", "123456789")

    assert response(response, 413) == "Git request is too large.\n"
  end

  test "receive-pack POST accepts a request when the limit is explicitly nil" do
    {user, _repository} = create_user_and_repository("alice")
    {_key, secret} = insert_legacy_api_key!(user, "repo:write", "write")
    original = Application.fetch_env(:git_transport, :receive_pack_max_bytes)
    Application.put_env(:git_transport, :receive_pack_max_bytes, nil)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:git_transport, :receive_pack_max_bytes, value)
        :error -> Application.delete_env(:git_transport, :receive_pack_max_bytes)
      end
    end)

    response =
      build_conn()
      |> maybe_authorize({"alice", secret})
      |> Plug.Conn.put_req_header("content-type", "application/x-git-receive-pack-request")
      |> post("/alice/demo.git/git-receive-pack", "0000")

    assert response(response, 200) == ""
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

  defp create_commit(repository, message) do
    path = ForgeRepos.absolute_storage_path(repository)
    tree = git!(["--git-dir=#{path}", "hash-object", "-t", "tree", "-w", "/dev/null"])
    git!(["--git-dir=#{path}", "commit-tree", tree, "-m", message])
  end

  defp receive_pack_post(username, repo_slug, secret, request_id, body) do
    build_conn()
    |> maybe_authorize({username, secret})
    |> Plug.Conn.put_req_header("content-type", "application/x-git-receive-pack-request")
    |> Plug.Conn.put_req_header("x-request-id", request_id)
    |> post("/#{username}/#{repo_slug}.git/git-receive-pack", body)
  end

  defp receive_pack_body(proposed_oid, expected_oid \\ String.duplicate("0", 40)) do
    GitTransport.PktLine.encode(
      "#{expected_oid} #{proposed_oid} refs/heads/main\0report-status\n"
    ) <>
      GitTransport.PktLine.flush() <> "PACK"
  end

  defp insert_legacy_api_key!(user, scope, name) do
    secret = "fc_pat_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    api_key =
      %ForgeAccounts.APIKey{
        user_id: user.id,
        name: name,
        token_prefix: String.slice(secret, 0, 15),
        token_hash: ForgeAccounts.APIKey.hash(secret),
        scopes: %{scope => true}
      }
      |> Repo.insert!()

    {api_key, secret}
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
          ~w(git_write_operations audit_events repository_collaborators repositories organization_members api_keys ssh_keys users),
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
