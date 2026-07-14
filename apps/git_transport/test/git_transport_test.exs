defmodule GitTransportTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{SSHKey, User}
  alias Fornacast.AuditEvent
  alias Fornacast.Repo

  @ed25519_public_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINUKfpNn72l8H0YnXfbkh6s4aAcrMmVsBWPfyPppa1i8 gao@mac-mini"

  setup do
    reset_database!()
  end

  test "parses supported Git SSH exec commands" do
    assert {:ok, command} = GitTransport.parse_exec("git-upload-pack 'alice/demo.git'")
    assert command.operation == :upload_pack
    assert command.owner == "alice"
    assert command.repository == "demo"

    assert {:ok, command} = GitTransport.parse_exec("git-upload-pack '/alice/demo.git'")
    assert command.path == "alice/demo.git"

    assert {:ok, command} = GitTransport.parse_exec("git-receive-pack alice/demo.git")
    assert command.operation == :receive_pack
  end

  test "rejects arbitrary or unsafe SSH exec commands" do
    assert {:error, :unsupported_command} = GitTransport.parse_exec("bash")
    assert {:error, :invalid_path} = GitTransport.parse_exec("git-upload-pack ../../repo.git")

    assert {:error, :invalid_command} =
             GitTransport.parse_exec("git-receive-pack 'alice/demo.git; rm -rf /'")

    assert {:error, :invalid_command} =
             GitTransport.parse_exec("git-upload-pack alice/demo.git extra")
  end

  test "authenticates SSH public keys through Fornacast accounts" do
    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-ssh@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(user, %{
               title: "laptop",
               public_key: @ed25519_public_key
             })

    assert {:ok, decoded_key} = SSHKey.decode_public_key(@ed25519_public_key)
    assert GitTransport.KeyCallback.is_auth_key(decoded_key, ~c"alice", [])

    assert [%{last_used_at: %DateTime{}}] = ForgeAccounts.list_user_ssh_keys(user)
    refute GitTransport.KeyCallback.is_auth_key(decoded_key, ~c"bob", [])

    assert {:ok, disabled} =
             ForgeAccounts.create_user(%{
               username: "disabled",
               email: "disabled-ssh@example.com",
               password: "correct horse battery staple"
             })

    disabled_public_key = rsa_sha2_public_key()

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(disabled, %{
               title: "laptop",
               public_key: disabled_public_key
             })

    assert {:ok, _disabled} =
             disabled
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:ok, disabled_decoded_key} = SSHKey.decode_public_key(disabled_public_key)
    refute GitTransport.KeyCallback.is_auth_key(disabled_decoded_key, ~c"disabled", [])
  end

  @tag :tmp_dir
  test "routes SSH exec through repository resolution and authorization", %{tmp_dir: tmp_dir} do
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-exec@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "exec repository"
             })

    assert {:ok, advertisement} =
             GitTransport.handle_exec("alice", "git-upload-pack 'alice/demo.git'")

    assert advertisement =~ "capabilities^{}"
    assert advertisement =~ "agent=fornacast/0.1"

    assert {:error, "ERROR: Fornacast only supports Git commands over SSH.\n"} =
             GitTransport.handle_exec("alice", "bash")

    assert {:error, "ERROR: Repository not found.\n"} =
             GitTransport.handle_exec("alice", "git-upload-pack '../../demo.git'")

    assert {:error, "ERROR: You do not have access to this repository.\n"} =
             GitTransport.handle_exec("bob", "git-upload-pack 'alice/demo.git'")
  end

  @tag :tmp_dir
  test "starts supervised OTP SSH daemon with explicit Git-only policy", %{tmp_dir: tmp_dir} do
    system_dir = Path.join(tmp_dir, "ssh")

    assert {:ok, pid} =
             GitTransport.start_ssh_daemon(
               bind_ip: "127.0.0.1",
               port: 0,
               system_dir: system_dir
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert GitTransport.Daemon.port(pid) > 0
    assert File.exists?(Path.join(system_dir, "ssh_host_rsa_key"))
    assert {:ok, info} = GitTransport.ssh_daemon_info(pid)
    assert {:port, port} = List.keyfind(info, :port, 0)
    assert port == GitTransport.Daemon.port(pid)

    options = GitTransport.Daemon.daemon_options(system_dir)
    assert Keyword.fetch!(options, :auth_methods) == ~c"publickey"
    assert Keyword.fetch!(options, :shell) == :disabled
    assert Keyword.fetch!(options, :exec) == :disabled
    assert Keyword.fetch!(options, :ssh_cli) == {GitTransport.Channel, []}
    assert Keyword.fetch!(options, :subsystems) == []
    refute Keyword.fetch!(options, :tcpip_tunnel_in)
    refute Keyword.fetch!(options, :tcpip_tunnel_out)
  end

  @tag :tmp_dir
  test "real SSH client authenticates with account key and rejects arbitrary exec", %{
    tmp_dir: tmp_dir
  } do
    share_database!()

    system_dir = Path.join(tmp_dir, "ssh")
    key_path = Path.join(tmp_dir, "id_rsa")
    {private_key_pem, public_key} = rsa_private_and_public_key()

    File.write!(key_path, private_key_pem)
    File.chmod!(key_path, 0o600)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-real-ssh@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(user, %{
               title: "generated",
               public_key: public_key
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

    {output, status} =
      System.cmd(
        "ssh",
        [
          "-F",
          "/dev/null",
          "-o",
          "IdentitiesOnly=yes",
          "-o",
          "KbdInteractiveAuthentication=no",
          "-o",
          "LogLevel=ERROR",
          "-o",
          "PasswordAuthentication=no",
          "-o",
          "PreferredAuthentications=publickey",
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=#{Path.join(tmp_dir, "known_hosts")}",
          "-i",
          key_path,
          "-p",
          Integer.to_string(port),
          "alice@127.0.0.1",
          "bash"
        ],
        stderr_to_stdout: true
      )

    assert status == 255
    assert output =~ "Fornacast only supports Git commands over SSH"
  end

  @tag :tmp_dir
  test "git ls-remote works over the OTP SSH upload-pack advertisement path", %{
    tmp_dir: tmp_dir
  } do
    share_database!()

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    system_dir = Path.join(tmp_dir, "ssh")
    key_path = Path.join(tmp_dir, "id_rsa")
    {private_key_pem, public_key} = rsa_private_and_public_key()

    File.write!(key_path, private_key_pem)
    File.chmod!(key_path, 0o600)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-ls-remote@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(user, %{
               title: "generated",
               public_key: public_key
             })

    assert {:ok, repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "ls-remote repository"
             })

    {commit_oid, _work_path} =
      populate_bare_repository!(tmp_dir, ForgeRepos.absolute_storage_path(repo))

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

    {output, status} =
      System.cmd(
        "git",
        ["ls-remote", "ssh://alice@127.0.0.1:#{port}/alice/demo.git"],
        env: [
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
        ],
        stderr_to_stdout: true
      )

    assert status == 0
    assert output =~ "#{commit_oid}\tHEAD"
    assert output =~ "#{commit_oid}\trefs/heads/main"
  end

  @tag :tmp_dir
  test "git clone and fetch work over the OTP SSH upload-pack path", %{tmp_dir: tmp_dir} do
    share_database!()

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    system_dir = Path.join(tmp_dir, "ssh")
    key_path = Path.join(tmp_dir, "id_rsa")
    clone_path = Path.join(tmp_dir, "clone")
    {private_key_pem, public_key} = rsa_private_and_public_key()

    File.write!(key_path, private_key_pem)
    File.chmod!(key_path, 0o600)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-clone@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(user, %{
               title: "generated",
               public_key: public_key
             })

    assert {:ok, repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "clone repository"
             })

    {_commit_oid, _work_path} =
      populate_bare_repository!(tmp_dir, ForgeRepos.absolute_storage_path(repo))

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

    {clone_output, clone_status} =
      System.cmd(
        "git",
        ["clone", "ssh://alice@127.0.0.1:#{port}/alice/demo.git", clone_path],
        env: [
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
        ],
        stderr_to_stdout: true
      )

    assert clone_status == 0, clone_output
    assert File.read!(Path.join(clone_path, "README.md")) == "# Demo\n"

    {fetch_output, fetch_status} =
      System.cmd(
        "git",
        ["-C", clone_path, "fetch", "origin"],
        env: [
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
        ],
        stderr_to_stdout: true
      )

    assert fetch_status == 0, fetch_output
  end

  @tag :tmp_dir
  test "git push works over the OTP SSH receive-pack path", %{tmp_dir: tmp_dir} do
    share_database!()

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_dir, "repos"))

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    system_dir = Path.join(tmp_dir, "ssh")
    key_path = Path.join(tmp_dir, "id_rsa")
    bob_key_path = Path.join(tmp_dir, "id_bob_rsa")
    work_path = Path.join(tmp_dir, "work")
    clone_path = Path.join(tmp_dir, "clone")
    {private_key_pem, public_key} = rsa_private_and_public_key()
    {bob_private_key_pem, bob_public_key} = rsa_private_and_public_key()

    File.write!(key_path, private_key_pem)
    File.chmod!(key_path, 0o600)
    File.write!(bob_key_path, bob_private_key_pem)
    File.chmod!(bob_key_path, 0o600)

    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "alice",
               email: "alice-push@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(user, %{
               title: "generated",
               public_key: public_key
             })

    assert {:ok, bob} =
             ForgeAccounts.create_user(%{
               username: "bob",
               email: "bob-push@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _key} =
             ForgeAccounts.create_ssh_key(bob, %{
               title: "generated",
               public_key: bob_public_key
             })

    assert {:ok, repo} =
             ForgeRepos.create_repository(user, %{
               name: "Demo",
               slug: "demo",
               description: "push repository"
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
    blocked_remote_url = "ssh://bob@127.0.0.1:#{port}/alice/demo.git"
    ssh_env = git_ssh_env(tmp_dir, key_path)
    bob_ssh_env = git_ssh_env(tmp_dir, bob_key_path)

    git!(["init", work_path])
    File.write!(Path.join(work_path, "README.md"), "# Demo\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", remote_url])
    git!(["-C", work_path, "remote", "add", "blocked", blocked_remote_url])
    git!(["-C", work_path, "push", "-u", "origin", "main"], ssh_env)

    {blocked_output, blocked_status} =
      git(["-C", work_path, "push", "blocked", "main"], bob_ssh_env)

    assert blocked_status != 0
    assert blocked_output =~ "You do not have access"

    repo_path = ForgeRepos.absolute_storage_path(repo)
    assert {:ok, [%GitCore.Ref{name: "refs/heads/main"}]} = GitCore.branches(repo_path)

    assert {:ok, %GitCore.Blob{data: "# Demo\n"}} =
             GitCore.read_blob(repo_path, "main", "README.md")

    File.write!(Path.join(work_path, "README.md"), "# Demo\n\nSecond line\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Second commit"])
    git!(["-C", work_path, "push", "origin", "main"], ssh_env)
    second_commit_oid = git!(["-C", work_path, "rev-parse", "HEAD"])

    assert {:ok, [%GitCore.Commit{oid: ^second_commit_oid} | _]} =
             GitCore.commit_history(repo_path, "main")

    git!(["-C", work_path, "tag", "v0.1"])
    git!(["-C", work_path, "push", "origin", "v0.1"], ssh_env)

    assert {:ok, [%GitCore.Ref{name: "refs/tags/v0.1"}]} = GitCore.tags(repo_path)

    git!(["-C", work_path, "checkout", "-b", "feature/demo"])
    File.write!(Path.join(work_path, "FEATURE.md"), "feature\n")
    git!(["-C", work_path, "add", "FEATURE.md"])
    git!(["-C", work_path, "commit", "-m", "Feature commit"])
    git!(["-C", work_path, "push", "origin", "feature/demo"], ssh_env)

    assert {:ok, branches} = GitCore.branches(repo_path)

    assert ["refs/heads/feature/demo", "refs/heads/main"] =
             branches |> Enum.map(& &1.name) |> Enum.sort()

    git!(["clone", remote_url, clone_path], ssh_env)
    assert File.read!(Path.join(clone_path, "README.md")) == "# Demo\n\nSecond line\n"

    git!(["-C", work_path, "checkout", "main"])
    git!(["-C", work_path, "reset", "--hard", "HEAD~1"])
    File.write!(Path.join(work_path, "README.md"), "# Rewritten\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Rewrite main"])

    {force_output, force_status} =
      git(["-C", work_path, "push", "--force", "origin", "main"], ssh_env)

    assert force_status != 0
    assert force_output =~ "non-fast-forward updates are not supported"

    reloaded_repo = Repo.get!(ForgeRepos.Repository, repo.id)
    assert %DateTime{} = reloaded_repo.last_pushed_at

    push_events =
      AuditEvent
      |> Repo.all()
      |> Enum.filter(&(&1.action == "repository.pushed"))

    assert length(push_events) == 4
    assert Enum.all?(push_events, &(&1.actor_user_id == user.id))
    assert Enum.all?(push_events, &(&1.target_id == Integer.to_string(repo.id)))
    assert Enum.any?(push_events, &("refs/heads/feature/demo" in &1.metadata["refs"]))
    assert Enum.any?(push_events, &("refs/tags/v0.1" in &1.metadata["refs"]))
  end

  defp rsa_sha2_public_key do
    {_private_key_pem, public_key} = rsa_private_and_public_key()
    public_key
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(reset_tables(), &Ecto.Adapters.SQL.query!(Repo, "delete from #{&1}", []))
    end
  end

  defp share_database! do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end
  end

  defp reset_tables do
    [
      "audit_events",
      "repository_collaborators",
      "repositories",
      "organization_members",
      "ssh_keys",
      "users"
    ]
  end

  defp populate_bare_repository!(tmp_dir, repo_path) do
    work_path = Path.join([tmp_dir, "work-#{System.unique_integer([:positive])}"])

    git!(["init", work_path])
    File.write!(Path.join(work_path, "README.md"), "# Demo\n")
    git!(["-C", work_path, "add", "README.md"])
    git!(["-C", work_path, "commit", "-m", "Initial commit"])
    git!(["-C", work_path, "branch", "-M", "main"])
    git!(["-C", work_path, "remote", "add", "origin", repo_path])
    git!(["-C", work_path, "push", "origin", "main"])

    {git!(["-C", work_path, "rev-parse", "HEAD"]), work_path}
  end

  defp git!(args), do: git!(args, [])

  defp git!(args, extra_env) do
    case git(args, extra_env) do
      {output, 0} -> String.trim_trailing(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}:\n#{output}")
    end
  end

  defp git(args, extra_env) do
    env =
      [
        {"GIT_AUTHOR_NAME", "Fornacast Test"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_NAME", "Fornacast Test"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"}
      ] ++ extra_env

    System.cmd("git", args, stderr_to_stdout: true, env: env)
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
