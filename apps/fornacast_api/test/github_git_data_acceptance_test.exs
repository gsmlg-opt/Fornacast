defmodule FornacastAPI.GitHubGitDataAcceptanceTest do
  use FornacastAPI.ConnCase, async: false

  import Ecto.Query

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    previous_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    previous_origin = Application.fetch_env(:fornacast_api, :base_url)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, previous_root)

      case previous_origin do
        {:ok, origin} -> Application.put_env(:fornacast_api, :base_url, origin)
        :error -> Application.delete_env(:fornacast_api, :base_url)
      end
    end)

    api_origin = start_http_server(FornacastAPI.Endpoint)
    web_origin = start_http_server(FornacastWeb.Endpoint)
    Application.put_env(:fornacast_api, :base_url, api_origin)
    %{api_origin: api_origin, web_origin: web_origin}
  end

  for version <- ["2022-11-28", "2026-03-10"] do
    @tag version: version
    test "#{version} Git-data HTTP writes remain visible through HTTP and SSH Git", context do
      owner = user("wire-owner")
      organization = organization(owner, "wire-organization")
      {_key, secret} = pat(owner, ["repo"])
      client = Map.merge(context, %{secret: secret})
      base = "/api/v3/repos/#{organization.username}/demo"

      created =
        api(client, :post, "/api/v3/orgs/#{organization.username}/repos", 201, %{
          "name" => "demo",
          "private" => true,
          "auto_init" => true
        })

      assert created["default_branch"] == "main"
      assert URI.parse(created["url"]).port == URI.parse(context.api_origin).port

      initial = api(client, :get, base <> "/git/ref/heads/main", 200)
      initial_oid = initial["object"]["sha"]

      assert [%{"name" => "main", "commit" => %{"sha" => ^initial_oid}}] =
               api(client, :get, base <> "/branches", 200)

      assert %{"ref" => "refs/heads/feature/api"} =
               api(client, :post, base <> "/git/refs", 201, %{
                 "ref" => "refs/heads/feature/api",
                 "sha" => initial_oid
               })

      assert %{"name" => "feature/api"} =
               api(client, :get, base <> "/branches/feature%2Fapi", 200)

      added =
        api(client, :put, base <> "/contents/docs%2Fguide.md", 201, %{
          "message" => "Add guide",
          "content" => Base.encode64("first\n"),
          "branch" => "feature/api"
        })

      added_oid = added["commit"]["sha"]
      blob_oid = added["content"]["sha"]

      assert %{"sha" => ^added_oid, "files" => [_]} =
               api(client, :get, base <> "/commits/" <> added_oid, 200)

      assert [%{"sha" => ^added_oid}] =
               api(client, :get, base <> "/commits?sha=feature%2Fapi&path=docs%2Fguide.md", 200)

      assert [%{"path" => "docs/guide.md"}] =
               api(client, :get, base <> "/contents/docs?ref=feature%2Fapi", 200)

      file = api(client, :get, base <> "/contents/docs/guide.md?ref=feature%2Fapi", 200)
      assert Base.decode64!(String.replace(file["content"], "\n", "")) == "first\n"

      changed =
        api(client, :put, base <> "/contents/docs/guide.md", 200, %{
          "message" => "Update guide",
          "content" => Base.encode64("second\n"),
          "sha" => blob_oid,
          "branch" => "feature/api"
        })

      api(client, :put, base <> "/contents/docs/guide.md", 409, %{
        "message" => "Stale update",
        "content" => Base.encode64("stale"),
        "sha" => blob_oid,
        "branch" => "feature/api"
      })

      removed =
        api(client, :delete, base <> "/contents/docs/guide.md", 200, %{
          "message" => "Remove guide",
          "sha" => changed["content"]["sha"],
          "branch" => "feature/api"
        })

      removed_oid = removed["commit"]["sha"]
      assert removed["content"] == nil
      api(client, :get, base <> "/contents/docs?ref=feature%2Fapi", 404)

      assert %{"object" => %{"sha" => ^removed_oid}} =
               api(client, :patch, base <> "/git/refs/heads/main", 200, %{"sha" => removed_oid})

      api(client, :patch, base <> "/git/refs/heads/main", 409, %{"sha" => initial_oid})

      api(client, :patch, base <> "/git/refs/heads/main", 422, %{
        "sha" => initial_oid,
        "force" => true
      })

      clone = Path.join(context.tmp_dir, "http-clone")
      http_url = "#{context.web_origin}/#{organization.username}/demo.git"

      http_env = [
        {"GIT_CONFIG_COUNT", "1"},
        {"GIT_CONFIG_KEY_0", "http.extraHeader"},
        {"GIT_CONFIG_VALUE_0",
         "Authorization: Basic " <> Base.encode64(owner.username <> ":" <> secret)}
      ]

      git!(["clone", "--branch", "main", http_url, clone], http_env)
      assert git!(["-C", clone, "rev-parse", "HEAD"]) == removed_oid
      assert File.read!(Path.join(clone, "README.md")) == "# demo\n"
      refute File.exists?(Path.join(clone, "docs"))
      git!(["-C", clone, "fetch", "origin"], http_env)
      assert git!(["-C", clone, "rev-parse", "origin/feature/api"]) == removed_oid

      http_oid = commit_file!(clone, "http.txt", "HTTP push\n")
      git!(["-C", clone, "push", "origin", "main"], http_env)

      assert %{"object" => %{"sha" => ^http_oid}} =
               api(client, :get, base <> "/git/ref/heads/main", 200)

      ssh_url = ssh_remote!(owner, organization, context.tmp_dir)
      ssh_env = ssh_environment(context.tmp_dir)
      ssh_oid = commit_file!(clone, "ssh.txt", "SSH push\n")
      git!(["-C", clone, "push", ssh_url, "HEAD:refs/heads/main"], ssh_env)

      assert %{"object" => %{"sha" => ^ssh_oid}} =
               api(client, :get, base <> "/git/ref/heads/main", 200)

      assert %{"sha" => ^ssh_oid} = api(client, :get, base <> "/commits/main", 200)

      final_clone = Path.join(context.tmp_dir, "ssh-clone")
      git!(["clone", ssh_url, final_clone], ssh_env)
      assert git!(["-C", final_clone, "rev-parse", "HEAD"]) == ssh_oid
      assert File.read!(Path.join(final_clone, "http.txt")) == "HTTP push\n"
      assert File.read!(Path.join(final_clone, "ssh.txt")) == "SSH push\n"
      git!(["-C", final_clone, "fsck", "--full"])

      repository = ForgeRepos.get_repository(organization.username, "demo")

      operations =
        Repo.all(
          from op in ForgeRepos.GitWriteOperation, where: op.repository_id == ^repository.id
        )

      assert operations != []
      assert Enum.all?(operations, &(&1.state == :bookkeeping_complete))
    end
  end

  defp api(client, method, path, expected_status, body \\ nil) do
    options = [
      method: method,
      url: client.api_origin <> path,
      headers: [
        {"user-agent", "fornacast-git-data-wire-acceptance/1.0"},
        {"authorization", "Bearer " <> client.secret},
        {"x-github-api-version", client.version},
        {"accept", "application/vnd.github+json"}
      ],
      retry: false,
      redirect: false,
      receive_timeout: 15_000
    ]

    options = if body, do: Keyword.put(options, :json, body), else: options
    response = Req.request!(options)
    assert response.status == expected_status, "#{method} #{path}: #{inspect(response.body)}"
    assert Req.Response.get_header(response, "x-github-api-version-selected") == [client.version]
    assert Req.Response.get_header(response, "x-github-request-id") != []
    response.body
  end

  defp start_http_server(endpoint) do
    child =
      Supervisor.child_spec(
        {Bandit, plug: endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: endpoint
      )

    pid = start_supervised!(child)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp commit_file!(clone, name, contents) do
    File.write!(Path.join(clone, name), contents)
    git!(["-C", clone, "add", name])
    git!(["-C", clone, "commit", "-m", name])
    git!(["-C", clone, "rev-parse", "HEAD"])
  end

  defp ssh_remote!(owner, organization, tmp_dir) do
    key_path = Path.join(tmp_dir, "id_rsa")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", key_path])

    assert {:ok, _} =
             ForgeAccounts.create_ssh_key(
               owner,
               %{title: "Git-data acceptance", public_key: File.read!(key_path <> ".pub")}
             )

    daemon =
      start_supervised!(
        {GitTransport.Daemon,
         name: __MODULE__.SSH,
         bind_ip: "127.0.0.1",
         port: 0,
         system_dir: Path.join(tmp_dir, "ssh")}
      )

    "ssh://#{owner.username}@127.0.0.1:#{GitTransport.Daemon.port(daemon)}/#{organization.username}/demo.git"
  end

  defp ssh_environment(tmp_dir) do
    [
      {"GIT_SSH_COMMAND",
       "ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes " <>
         "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i " <>
         shell_quote(Path.join(tmp_dir, "id_rsa"))}
    ]
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp git!(arguments, environment \\ []) do
    environment =
      [
        {"GIT_AUTHOR_NAME", "Git-data acceptance"},
        {"GIT_AUTHOR_EMAIL", "git-data@example.test"},
        {"GIT_COMMITTER_NAME", "Git-data acceptance"},
        {"GIT_COMMITTER_EMAIL", "git-data@example.test"},
        {"GIT_TERMINAL_PROMPT", "0"}
      ] ++ environment

    {output, status} =
      System.cmd("git", ["-c", "credential.helper=" | arguments],
        env: environment,
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.trim(output)
  end
end
