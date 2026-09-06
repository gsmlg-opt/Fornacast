defmodule FornacastWeb.GitLFSHTTPTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint
  @lfs_json "application/vnd.git-lfs+json"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    username = "lfs-http-#{System.unique_integer([:positive])}"

    assert {:ok, actor} =
             ForgeAccounts.create_user(%{
               username: username,
               email: "#{username}@example.test",
               password: "correct horse battery staple"
             })

    assert {:ok, repository} =
             ForgeRepos.create_repository(actor, %{name: "LFS HTTP", slug: "objects"})

    assert {:ok, api_key, secret} =
             ForgeAccounts.create_api_key(actor, %{name: "LFS client", scopes: ["repo"]})

    %{actor: actor, repository: repository, api_key: api_key, secret: secret}
  end

  test "Batch and Basic actions upload, verify, range-read, and dedupe", context do
    payload = "official basic transfer payload"
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)
    batch_path = lfs_path(context, "/objects/batch")

    upload_batch =
      context
      |> lfs_json_request(:post, batch_path, %{
        "operation" => "upload",
        "transfers" => ["basic"],
        "objects" => [%{"oid" => oid, "size" => byte_size(payload)}]
      })

    assert response(upload_batch, 200)
    assert [@lfs_json <> "; charset=utf-8"] = get_resp_header(upload_batch, "content-type")
    assert %{"objects" => [%{"actions" => actions}]} = JSON.decode!(upload_batch.resp_body)

    upload = actions["upload"]
    verify = actions["verify"]

    upload_response =
      build_conn()
      |> put_req_header("authorization", upload["header"]["Authorization"])
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("content-length", Integer.to_string(byte_size(payload)))
      |> put(URI.parse(upload["href"]).path, payload)

    assert response(upload_response, 200) == ""

    verify_response =
      build_conn()
      |> put_req_header("authorization", verify["header"]["Authorization"])
      |> put_req_header("accept", @lfs_json)
      |> put_req_header("content-type", @lfs_json)
      |> post(
        URI.parse(verify["href"]).path,
        JSON.encode!(%{"oid" => oid, "size" => byte_size(payload)})
      )

    assert response(verify_response, 200) == "{}"

    download_batch =
      context
      |> lfs_json_request(:post, batch_path, %{
        "operation" => "download",
        "objects" => [%{"oid" => oid, "size" => byte_size(payload)}]
      })

    assert %{"objects" => [%{"actions" => %{"download" => download}}]} =
             download_batch |> response(200) |> JSON.decode!()

    ranged =
      build_conn()
      |> put_req_header("authorization", download["header"]["Authorization"])
      |> put_req_header("range", "bytes=9-13")
      |> get(URI.parse(download["href"]).path)

    assert response(ranged, 206) == "basic"
    assert get_resp_header(ranged, "content-range") == ["bytes 9-13/#{byte_size(payload)}"]
    assert get_resp_header(ranged, "accept-ranges") == ["bytes"]

    second_batch =
      context
      |> lfs_json_request(:post, batch_path, %{
        "operation" => "upload",
        "objects" => [%{"oid" => oid, "size" => byte_size(payload)}]
      })

    assert %{"objects" => [object]} = second_batch |> response(200) |> JSON.decode!()
    refute Map.has_key?(object, "actions")
  end

  test "object action tokens cannot cross repository, OID, or operation", context do
    oid = String.duplicate("a", 64)

    batch =
      context
      |> lfs_json_request(:post, lfs_path(context, "/objects/batch"), %{
        "operation" => "upload",
        "objects" => [%{"oid" => oid, "size" => 1}]
      })
      |> response(200)
      |> JSON.decode!()

    upload = batch["objects"] |> hd() |> get_in(["actions", "upload"])
    authorization = upload["header"]["Authorization"]

    assert {:ok, other_repository} =
             ForgeRepos.create_repository(context.actor, %{name: "Other", slug: "other"})

    for path <- [
          lfs_path(%{context | repository: other_repository}, "/objects/#{oid}"),
          lfs_path(context, "/objects/#{String.duplicate("b", 64)}")
        ] do
      response =
        build_conn()
        |> put_req_header("authorization", authorization)
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-length", "1")
        |> put(path, "x")

      assert response(response, 404) == "Repository or object not found.\n"
    end

    wrong_method =
      build_conn()
      |> put_req_header("authorization", authorization)
      |> get(URI.parse(upload["href"]).path)

    assert response(wrong_method, 401) == "Authentication required.\n"
  end

  test "private repositories are masked and malformed protocol requests are bounded", context do
    oid = String.duplicate("a", 64)
    path = lfs_path(context, "/objects/batch")
    missing_path = "/#{context.actor.username}/missing.git/info/lfs/objects/batch"
    body = JSON.encode!(%{"operation" => "download", "objects" => [%{"oid" => oid, "size" => 1}]})

    for requested_path <- [path, missing_path] do
      anonymous =
        build_conn()
        |> put_req_header("content-type", @lfs_json)
        |> post(requested_path, body)

      assert response(anonymous, 401) == "Authentication required.\n"

      invalid_credentials =
        build_conn()
        |> put_req_header("authorization", "Basic " <> Base.encode64("nobody:wrong"))
        |> put_req_header("content-type", @lfs_json)
        |> post(requested_path, body)

      assert response(invalid_credentials, 401) == "Authentication required.\n"
    end

    outsider_name = "lfs-outsider-#{System.unique_integer([:positive])}"

    assert {:ok, outsider} =
             ForgeAccounts.create_user(%{
               username: outsider_name,
               email: "#{outsider_name}@example.test",
               password: "correct horse battery staple"
             })

    assert {:ok, _api_key, outsider_secret} =
             ForgeAccounts.create_api_key(outsider, %{name: "Outsider", scopes: ["repo"]})

    outsider_context = %{actor: outsider, secret: outsider_secret}

    for requested_path <- [path, missing_path] do
      masked =
        outsider_context
        |> basic_conn()
        |> put_req_header("content-type", @lfs_json)
        |> post(requested_path, body)

      assert response(masked, 404) == "Repository or object not found.\n"
    end

    malformed =
      context
      |> basic_conn()
      |> put_req_header("content-type", @lfs_json)
      |> post(path, "{")

    assert response(malformed, 400)

    wrong_type =
      context
      |> basic_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, body)

    assert response(wrong_type, 415)

    oversized_objects = List.duplicate(%{"oid" => oid, "size" => 1}, 101)

    too_many =
      context
      |> lfs_json_request(:post, path, %{
        "operation" => "download",
        "objects" => oversized_objects
      })

    assert response(too_many, 413)

    encoded_path =
      "/#{context.actor.username}/#{context.repository.slug}%2Egit/info/lfs/objects/batch"

    encoded_oversized =
      context
      |> basic_conn()
      |> put_req_header("content-type", @lfs_json)
      |> post(encoded_path, String.duplicate(" ", 1_048_577))

    assert response(encoded_oversized, 413) == "Git LFS request is too large.\n"
  end

  test "upload rejects declared size and SHA-256 mismatches without publishing", context do
    payload = "expected"

    for {oid, body, message} <- [
          {digest(payload), "short", "Object size does not match"},
          {digest(payload), "xxxxxxxx", "Object SHA-256 does not match"}
        ] do
      batch =
        context
        |> lfs_json_request(:post, lfs_path(context, "/objects/batch"), %{
          "operation" => "upload",
          "objects" => [%{"oid" => oid, "size" => byte_size(payload)}]
        })
        |> response(200)
        |> JSON.decode!()

      upload = batch["objects"] |> hd() |> get_in(["actions", "upload"])

      response =
        build_conn()
        |> put_req_header("authorization", upload["header"]["Authorization"])
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-length", Integer.to_string(byte_size(body)))
        |> put(URI.parse(upload["href"]).path, body)

      assert response(response, 422) =~ message

      assert {:error, :not_found} =
               GitLFS.open_object(context.repository, oid, byte_size(payload), :all)
    end
  end

  @tag :tmp_dir
  test "official Git LFS client uses SSH authentication and the Basic transfer API", %{
    repository: repository,
    actor: actor,
    tmp_dir: tmp_dir
  } do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    http_port = start_http_server()
    {ssh_port, key_path} = start_ssh_server(tmp_dir, actor)
    previous_base_url = Application.fetch_env!(:fornacast, :base_url)
    Application.put_env(:fornacast, :base_url, "http://127.0.0.1:#{http_port}")

    on_exit(fn -> Application.put_env(:fornacast, :base_url, previous_base_url) end)

    work_path = Path.join(tmp_dir, "client")
    payload = :crypto.strong_rand_bytes(256 * 1_024)
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)

    remote_url =
      "ssh://#{actor.username}@127.0.0.1:#{ssh_port}/#{actor.username}/#{repository.slug}.git"

    client_env = ssh_lfs_client_env(tmp_dir, key_path)

    git!(["init", work_path], client_env)
    git!(["-C", work_path, "config", "user.name", "Fornacast LFS Test"], client_env)
    git!(["-C", work_path, "config", "user.email", "lfs@example.test"], client_env)
    git!(["-C", work_path, "lfs", "install", "--local"], client_env)
    git!(["-C", work_path, "lfs", "track", "*.bin"], client_env)
    File.write!(Path.join(work_path, "asset.bin"), payload)
    git!(["-C", work_path, "add", ".gitattributes", "asset.bin"], client_env)
    git!(["-C", work_path, "commit", "-m", "Add LFS asset"], client_env)
    git!(["-C", work_path, "remote", "add", "origin", remote_url], client_env)
    git!(["-C", work_path, "lfs", "push", "--object-id", "origin", oid], client_env)

    assert :ok = GitLFS.verify_object(repository, oid, byte_size(payload))

    object_path =
      Path.join([
        work_path,
        ".git/lfs/objects",
        binary_part(oid, 0, 2),
        binary_part(oid, 2, 2),
        oid
      ])

    File.rm!(object_path)
    git!(["-C", work_path, "lfs", "fetch", "origin", "HEAD"], client_env)
    assert File.read!(object_path) == payload
  end

  @tag :tmp_dir
  test "official HTTP clone checks out LFS bytes and fails when required bytes are missing", %{
    repository: repository,
    actor: actor,
    tmp_dir: tmp_dir
  } do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    repository = repository |> Ecto.Changeset.change(visibility: :public) |> Repo.update!()
    port = start_http_server()
    previous_base_url = Application.fetch_env!(:fornacast, :base_url)
    Application.put_env(:fornacast, :base_url, "http://127.0.0.1:#{port}")
    on_exit(fn -> Application.put_env(:fornacast, :base_url, previous_base_url) end)

    payload = :crypto.strong_rand_bytes(128 * 1_024)
    oid = digest(payload)
    on_exit(fn -> ForgeBlobs.delete(oid) end)
    assert {:ok, reservation} = GitLFS.reserve_upload(repository, oid, byte_size(payload))

    reader = fn
      [chunk], _maximum -> {:more, chunk, []}
      [], _maximum -> {:done, []}
    end

    assert {:ok, staged, []} = GitLFS.stage_upload(reservation, reader, [payload])
    assert {:ok, _object} = GitLFS.commit_upload(staged)

    env = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_LFS_SKIP_SMUDGE", nil},
      {"GIT_AUTHOR_NAME", "LFS Acceptance"},
      {"GIT_AUTHOR_EMAIL", "lfs@example.test"},
      {"GIT_COMMITTER_NAME", "LFS Acceptance"},
      {"GIT_COMMITTER_EMAIL", "lfs@example.test"}
    ]

    source = Path.join(tmp_dir, "source")
    git!(["init", source], env)

    File.write!(
      Path.join(source, ".gitattributes"),
      "*.bin filter=lfs diff=lfs merge=lfs -text\n"
    )

    File.write!(
      Path.join(source, "asset.bin"),
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{oid}\nsize #{byte_size(payload)}\n"
    )

    git!(["-C", source, "add", ".gitattributes", "asset.bin"], env)
    git!(["-C", source, "commit", "-m", "Imported LFS pointer"], env)

    git!(
      [
        "-C",
        source,
        "push",
        ForgeRepos.absolute_storage_path(repository),
        "HEAD:refs/heads/main"
      ],
      env
    )

    git!(
      [
        "--git-dir",
        ForgeRepos.absolute_storage_path(repository),
        "symbolic-ref",
        "HEAD",
        "refs/heads/main"
      ],
      env
    )

    url = "http://127.0.0.1:#{port}/#{actor.username}/#{repository.slug}.git"

    filter_options = [
      "-c",
      "filter.lfs.process=git-lfs filter-process",
      "-c",
      "filter.lfs.required=true"
    ]

    checkout = Path.join(tmp_dir, "checkout")
    git!(filter_options ++ ["clone", url, checkout], env)
    assert File.read!(Path.join(checkout, "asset.bin")) == payload
    assert digest(File.read!(Path.join(checkout, "asset.bin"))) == oid

    assert :ok = ForgeBlobs.delete(oid)

    {output, status} =
      System.cmd("git", filter_options ++ ["clone", url, Path.join(tmp_dir, "missing")],
        stderr_to_stdout: true,
        env: env
      )

    assert status != 0
    assert output =~ "smudge"
    assert output =~ String.slice(oid, 0, 7)
  end

  defp lfs_json_request(context, method, path, body) do
    context
    |> basic_conn()
    |> put_req_header("accept", @lfs_json)
    |> put_req_header("content-type", @lfs_json)
    |> lfs_dispatch(method, path, JSON.encode!(body))
  end

  defp basic_conn(context) do
    build_conn()
    |> put_req_header(
      "authorization",
      "Basic " <> Base.encode64("#{context.actor.username}:#{context.secret}")
    )
  end

  defp lfs_dispatch(conn, :post, path, body), do: post(conn, path, body)

  defp lfs_path(context, suffix) do
    "/#{context.actor.username}/#{context.repository.slug}.git/info/lfs#{suffix}"
  end

  defp digest(payload), do: :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

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

  defp start_ssh_server(tmp_dir, actor) do
    key_path = Path.join(tmp_dir, "id_rsa")
    {private_key_pem, public_key} = rsa_private_and_public_key()
    File.write!(key_path, private_key_pem)
    File.chmod!(key_path, 0o600)

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(actor, %{
               title: "Git LFS acceptance",
               public_key: public_key
             })

    pid =
      start_supervised!(
        {GitTransport.Daemon,
         bind_ip: "127.0.0.1", port: 0, system_dir: Path.join(tmp_dir, "ssh")}
      )

    {GitTransport.Daemon.port(pid), key_path}
  end

  defp ssh_lfs_client_env(tmp_dir, key_path) do
    [
      {"GIT_SSH_COMMAND",
       Enum.join(
         [
           "ssh",
           "-F /dev/null",
           "-o IdentitiesOnly=yes",
           "-o KbdInteractiveAuthentication=no",
           "-o LogLevel=ERROR",
           "-o PasswordAuthentication=no",
           "-o PreferredAuthentications=publickey",
           "-o PubkeyAcceptedAlgorithms=rsa-sha2-512,rsa-sha2-256",
           "-o StrictHostKeyChecking=no",
           "-o UserKnownHostsFile=#{Path.join(tmp_dir, "known_hosts")}",
           "-i #{key_path}"
         ],
         " "
       )},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"}
    ]
  end

  defp rsa_private_and_public_key do
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} =
      private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    private_key_pem =
      :RSAPrivateKey
      |> :public_key.pem_entry_encode(private_key)
      |> List.wrap()
      |> :public_key.pem_encode()

    public_key =
      {:RSAPublicKey, modulus, exponent}
      |> List.wrap()
      |> Enum.map(&{&1, [comment: ~c"test"]})
      |> :ssh_file.encode(:auth_keys)
      |> to_string()
      |> String.trim()

    {private_key_pem, public_key}
  end

  defp git!(arguments, env) do
    case System.cmd("git", arguments, stderr_to_stdout: true, env: env) do
      {output, 0} ->
        String.trim_trailing(output)

      {output, status} ->
        flunk("git #{Enum.join(arguments, " ")} failed with #{status}:\n#{output}")
    end
  end
end
