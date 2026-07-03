defmodule FornacastWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint FornacastWeb.Endpoint
  @ed25519_public_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINUKfpNn72l8H0YnXfbkh6s4aAcrMmVsBWPfyPppa1i8 gao@mac-mini"

  test "HTML escaping protects repository content in inline pages" do
    assert FornacastWeb.HTML.escape(~s|<script>alert("x")</script>|) ==
             "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"
  end

  @tag :tmp_dir
  test "health endpoint reports database, storage, and SSH daemon status", %{tmp_dir: tmp_dir} do
    reset_database!()
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    health = get(build_conn(), "/health")

    assert %{
             "status" => "ok",
             "checks" => %{
               "app" => "ok",
               "database" => "ok",
               "repository_storage" => "ok",
               "ssh_daemon" => "disabled"
             }
           } = json_response(health, 200)
  end

  @tag :tmp_dir
  test "repository browser renders README, source, raw file, and commit metadata", %{
    tmp_dir: tmp_dir
  } do
    reset_database!()
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-web@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "web repository"
             })

    work_path = Path.join(tmp_dir, "work")
    repo_path = ForgeRepos.absolute_storage_path(repo)

    git!(["init", work_path])
    File.mkdir_p!(Path.join(work_path, "docs"))
    File.write!(Path.join(work_path, "README.md"), "# Demo\n\n<script>alert('x')</script>\n")
    File.write!(Path.join([work_path, "docs", "guide.txt"]), "hello\n")
    File.write!(Path.join(work_path, "asset.bin"), <<0, 1, 2, 3>>)
    File.write!(Path.join(work_path, "large.txt"), String.duplicate("x", 1_048_577))
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "main"])
    git!(["-C", work_path, "tag", "v0.1"])
    git!(["-C", work_path, "push", "origin", "v0.1"])
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])
    git!(["-C", work_path, "checkout", "-b", "feature/demo"])
    File.write!(Path.join([work_path, "docs", "branch.txt"]), "feature branch\n")
    git!(["-C", work_path, "add", "docs/branch.txt"])
    git!(["-C", work_path, "commit", "-m", "Feature branch"])
    git!(["-C", work_path, "push", "origin", "feature/demo"])

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)

    overview = get(conn, "/alice/demo")
    assert html_response(overview, 200) =~ "<h1>Demo</h1>"
    refute html_response(overview, 200) =~ "<script>"

    source = get(conn, "/alice/demo/src/main/docs")
    assert html_response(source, 200) =~ "guide.txt"

    file = get(conn, "/alice/demo/src/main/docs/guide.txt")
    assert html_response(file, 200) =~ "hello"

    binary = get(conn, "/alice/demo/src/main/asset.bin")
    assert html_response(binary, 200) =~ "Binary or non-UTF-8 files are not rendered inline."

    large = get(conn, "/alice/demo/src/main/large.txt")
    assert html_response(large, 200) =~ "larger than 1048576 bytes"

    raw = get(conn, "/alice/demo/raw/main/docs/guide.txt")
    assert response(raw, 200) == "hello\n"

    commits = get(conn, "/alice/demo/commits/main")
    assert html_response(commits, 200) =~ "Initial commit"

    branches = get(conn, "/alice/demo/branches")
    assert html_response(branches, 200) =~ "main"

    tags = get(conn, "/alice/demo/tags")
    assert html_response(tags, 200) =~ "v0.1"

    feature_file = get(conn, "/alice/demo/src/feature/demo/docs/branch.txt")
    assert html_response(feature_file, 200) =~ "feature branch"

    feature_commits = get(conn, "/alice/demo/commits/feature/demo")
    assert html_response(feature_commits, 200) =~ "Feature branch"

    detail = get(conn, "/alice/demo/commit/#{commit_oid}")
    assert html_response(detail, 200) =~ commit_oid
    assert html_response(detail, 200) =~ "Fornacast Test"
    assert html_response(detail, 200) =~ "Changed files"
    assert html_response(detail, 200) =~ "README.md"
    assert html_response(detail, 200) =~ "diff --git a/README.md b/README.md"
  end

  @tag :tmp_dir
  test "login, SSH key, repository creation, empty state, and private access policy", %{
    tmp_dir: tmp_dir
  } do
    reset_database!()
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-flow@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, bob} =
             ForgeAccounts.create_user(%{
               username: "bob",
               email: "bob-flow@example.com",
               password: "correct horse battery staple"
             })

    login_form = get(build_conn(), "/login")
    assert html_response(login_form, 200) =~ "Login"

    login =
      post(build_conn(), "/login", %{
        "session" => %{
          "username" => "alice",
          "password" => "correct horse battery staple"
        }
      })

    assert redirected_to(login) == "/"

    key =
      login
      |> recycle()
      |> post("/ssh-keys", %{
        "ssh_key" => %{
          "title" => "laptop",
          "public_key" => @ed25519_public_key
        }
      })

    assert redirected_to(key) == "/ssh-keys"
    assert [%{fingerprint_sha256: "SHA256:" <> _}] = ForgeAccounts.list_user_ssh_keys(user)

    created =
      key
      |> recycle()
      |> post("/repos", %{
        "repository" => %{
          "name" => "Empty",
          "slug" => "empty",
          "description" => "empty repository"
        }
      })

    assert redirected_to(created) == "/alice/empty"

    empty =
      created
      |> recycle()
      |> get("/alice/empty")

    assert html_response(empty, 200) =~ "git push -u origin main"
    assert html_response(empty, 200) =~ "ssh://alice@"

    forbidden =
      build_conn()
      |> Plug.Test.init_test_session(user_id: bob.id)
      |> get("/alice/empty")

    assert html_response(forbidden, 403) =~ "You do not have access"
  end

  @tag :tmp_dir
  test "repository browser renders content pushed over Fornacast SSH", %{tmp_dir: tmp_dir} do
    reset_database!()
    share_database!()

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    system_dir = Path.join(tmp_dir, "ssh")
    key_path = Path.join(tmp_dir, "id_rsa")
    work_path = Path.join(tmp_dir, "work")
    {private_key_pem, public_key} = rsa_private_and_public_key()

    File.write!(key_path, private_key_pem)
    File.chmod!(key_path, 0o600)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-web-ssh@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(user, %{
               title: "generated",
               public_key: public_key
             })

    assert {:ok, _repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "web repository from ssh push"
             })

    assert {:ok, pid} =
             GitTransport.start_ssh_daemon(
               bind_ip: "127.0.0.1",
               port: 0,
               system_dir: system_dir
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    port = GitTransport.Daemon.port(pid)
    remote_url = "ssh://alice@127.0.0.1:#{port}/alice/demo.git"
    ssh_env = git_ssh_env(tmp_dir, key_path)

    git!(["init", work_path])
    File.mkdir_p!(Path.join(work_path, "lib"))
    File.write!(Path.join(work_path, "README.md"), "# Pushed README\n")
    File.write!(Path.join([work_path, "lib", "demo.ex"]), "defmodule Demo, do: :ok\n")
    git!(["-C", work_path, "add", "."])
    git!(["-C", work_path, "commit", "-m", "Initial SSH push"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", remote_url])
    git!(["-C", work_path, "push", "-u", "origin", "main"], ssh_env)
    commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    conn =
      build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)

    overview = get(conn, "/alice/demo")
    assert html_response(overview, 200) =~ "Pushed README"

    source = get(conn, "/alice/demo/src/main/lib")
    assert html_response(source, 200) =~ "demo.ex"

    file = get(conn, "/alice/demo/src/main/lib/demo.ex")
    assert html_response(file, 200) =~ "defmodule Demo"

    commits = get(conn, "/alice/demo/commits/main")
    assert html_response(commits, 200) =~ "Initial SSH push"

    detail = get(conn, "/alice/demo/commit/#{commit_oid}")
    assert html_response(detail, 200) =~ "diff --git a/README.md b/README.md"
  end

  defp git!(args), do: git!(args, [])

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(
          reset_tables(),
          &Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{&1}", [])
        )
    end
  end

  defp share_database! do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      Ecto.Adapters.SQL.Sandbox.mode(Fornacast.Repo, {:shared, self()})
    end
  end

  defp reset_tables do
    ["audit_events", "repository_collaborators", "repositories", "ssh_keys", "users"]
  end

  defp git!(args, extra_env) do
    env =
      [
        {"GIT_AUTHOR_NAME", "Fornacast Test"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_NAME", "Fornacast Test"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"}
      ] ++ extra_env

    case System.cmd("git", args, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end

  defp git_ssh_env(tmp_dir, key_path) do
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
           "-o StrictHostKeyChecking=no",
           "-o UserKnownHostsFile=#{Path.join(tmp_dir, "known_hosts")}",
           "-i #{key_path}"
         ],
         " "
       )}
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
      |> String.replace_prefix("ssh-rsa", "rsa-sha2-256")
      |> String.trim()

    {private_key_pem, public_key}
  end
end
