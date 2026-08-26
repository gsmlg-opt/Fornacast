defmodule GitCore.RemoteTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "mirrors through the enforced public request and returns a safe result", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    pat = "github_pat_secret"
    inherited_secret = "must-not-reach-remote"
    original_sentinel = System.get_env("REMOTE_SECRET_SENTINEL")
    System.put_env("REMOTE_SECRET_SENTINEL", inherited_secret)

    on_exit(fn ->
      if original_sentinel,
        do: System.put_env("REMOTE_SECRET_SENTINEL", original_sentinel),
        else: System.delete_env("REMOTE_SECRET_SENTINEL")
    end)

    request = request_fixture(tmp_dir)
    resolver = public_resolver()
    injected_marker = "remote-helper-injected-#{System.unique_integer([:positive])}"
    injected_marker_path = Path.join(File.cwd!(), injected_marker)

    credential_root =
      Path.join(tmp_dir, "credential root;touch${IFS}#{injected_marker};#")

    on_exit(fn -> File.rm(injected_marker_path) end)

    assert {:ok,
            %GitCore.Remote.Result{
              path: path,
              empty?: false,
              default_branch: "main",
              refs: 1,
              bytes: bytes
            }} =
             GitCore.Remote.mirror(request, pat,
               git: fake_git.git,
               resolver: resolver,
               credential_root: credential_root
             )

    assert path == request.destination
    assert bytes > 0
    assert {:ok, _oid} = GitCore.exact_ref(path, "refs/heads/main")
    assert {:ok, nil} = GitCore.exact_ref(path, "refs/pull/1/head")
    assert symbolic_head(path) == "refs/heads/main"
    refute File.exists?(Path.join(path, "hooks"))

    argv = File.read!(fake_git.argv_log)
    environment = File.read!(fake_git.env_log)
    credential_input = File.read!(fake_git.stdin_log)

    assert argv =~ "ARG=https://github.com/octocat/hello-world.git"
    assert argv =~ "ARG=http.followRedirects=false"
    assert argv =~ "ARG=protocol.allow=never"
    assert argv =~ "ARG=http.curloptResolve=github.com:443:"
    assert argv =~ "ARG=credential.helper=cache --socket='"
    refute argv =~ pat
    refute environment =~ pat
    refute environment =~ inherited_secret
    assert environment =~ "PATH=/no-such-path"
    assert credential_input =~ "protocol=https"
    assert credential_input =~ "host=github.com"
    assert credential_input =~ "username_bytes=#{byte_size(request.credential_login)}"
    assert credential_input =~ "password_bytes=#{byte_size(pat)}"
    assert credential_input =~ "retrieved_username_bytes=#{byte_size(request.credential_login)}"
    assert credential_input =~ "retrieved_password_bytes=#{byte_size(pat)}"
    refute credential_input =~ pat
    refute_tree_contains?(request.destination, pat)
    refute File.exists?(injected_marker_path)
    assert {:ok, []} = File.ls(credential_root)
  end

  @tag :tmp_dir
  test "two first-use operations share a freshly created private credential root", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    credential_root = Path.join(tmp_dir, "fresh-credentials")
    arrivals = :atomics.new(1, signed: false)

    resolver = fn
      "github.com", :a ->
        :atomics.add_get(arrivals, 1, 1)
        await_atomic(arrivals, 2, System.monotonic_time(:millisecond) + 2_000)
        [{140, 82, 121, 3}]

      "github.com", :aaaa ->
        [{0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154}]
    end

    requests = [
      request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "first.git")}),
      request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "second.git")})
    ]

    results =
      Task.async_stream(
        requests,
        fn request ->
          GitCore.Remote.mirror(request, "github_pat_secret",
            git: fake_git.git,
            resolver: resolver,
            credential_root: credential_root
          )
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %GitCore.Remote.Result{}}}, &1))
    assert {:ok, %File.Stat{mode: mode}} = File.stat(credential_root)
    assert Bitwise.band(mode, 0o777) == 0o700
    assert {:ok, []} = File.ls(credential_root)
  end

  @tag :tmp_dir
  test "bounds hanging cancel and heartbeat callbacks while cleaning every owner", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    credential_root = Path.join(tmp_dir, "bounded-control-credentials")

    for {name, expected_kind, callback_opts} <- [
          {"cancel", :cancelled,
           [
             cancel?: fn ->
               if File.exists?(fake_git.child_pid) do
                 send(Process.get(:control_test_pid), {:callback_started, :cancel, self()})

                 receive do
                 after
                   1_000 -> true
                 end
               else
                 false
               end
             end
           ]},
          {"heartbeat", :heartbeat_failed,
           [
             heartbeat: fn ->
               if File.exists?(fake_git.child_pid) do
                 send(Process.get(:control_test_pid), {:callback_started, :heartbeat, self()})

                 receive do
                 after
                   1_000 -> :invalid
                 end
               else
                 :ok
               end
             end
           ]}
        ] do
      destination = Path.join(tmp_dir, "bounded-#{name}.git")
      request = request_fixture(tmp_dir, %{destination: destination})
      File.write!(fake_git.mode_file, "block")
      File.rm(fake_git.child_pid)
      test_pid = self()

      callback_opts =
        Enum.map(callback_opts, fn {key, callback} ->
          {key,
           fn ->
             Process.put(:control_test_pid, test_pid)
             callback.()
           end}
        end)

      started_at = System.monotonic_time(:millisecond)

      result =
        GitCore.Remote.mirror(
          request,
          "github_pat_secret",
          [
            git: fake_git.git,
            resolver: public_resolver(),
            credential_root: credential_root
          ] ++ callback_opts
        )

      quarantine = assert_cleanup_pending(result, expected_kind, destination)
      assert {:ok, []} = File.ls(quarantine)

      elapsed = System.monotonic_time(:millisecond) - started_at
      assert elapsed < 750, "#{name} callback cleanup took #{elapsed}ms"
      callback_kind = String.to_existing_atom(name)
      assert_receive {:callback_started, ^callback_kind, callback_worker}
      eventually(fn -> refute Elixir.Process.alive?(callback_worker) end)
      child_pid = fake_git.child_pid |> File.read!() |> String.trim()
      eventually(fn -> refute os_process_alive?(child_pid) end)
      assert {:ok, []} = File.ls(credential_root)
    end

    assert :ok =
             GitCore.RemoteLimiter.with_permit(fn -> :ok end, server: GitCore.RemoteLimiter)

    deadline_request =
      request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "callback-deadline.git")})

    deadline_callback = fn ->
      receive do
      after
        1_000 -> false
      end
    end

    test_pid = self()

    with_limits([remote_wall_time_ms: 50], fn ->
      result =
        GitCore.Remote.mirror(deadline_request, "github_pat_secret",
          git: fake_git.git,
          resolver: public_resolver(),
          credential_root: credential_root,
          cancel?: fn ->
            send(test_pid, {:deadline_callback_started, self()})
            deadline_callback.()
          end
        )

      quarantine = assert_cleanup_pending(result, :timeout, deadline_request.destination)
      assert {:ok, []} = File.ls(quarantine)
    end)

    assert_receive {:deadline_callback_started, deadline_worker}
    eventually(fn -> refute Elixir.Process.alive?(deadline_worker) end)
  end

  @tag :tmp_dir
  test "fails closed for raised, thrown, and invalid callback returns", %{tmp_dir: tmp_dir} do
    fake_git = write_fake_git!(tmp_dir)

    cases = [
      {:cancel_raise, [cancel?: fn -> raise "cancel callback failed" end], :cancelled},
      {:cancel_throw, [cancel?: fn -> throw(:cancel_callback_failed) end], :cancelled},
      {:cancel_invalid, [cancel?: fn -> :invalid end], :cancelled},
      {:heartbeat_raise, [heartbeat: fn -> raise "heartbeat callback failed" end],
       :heartbeat_failed},
      {:heartbeat_throw, [heartbeat: fn -> throw(:heartbeat_callback_failed) end],
       :heartbeat_failed},
      {:heartbeat_invalid, [heartbeat: fn -> :invalid end], :heartbeat_failed}
    ]

    for {name, callback_opts, expected_kind} <- cases do
      request = request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "#{name}.git")})
      started_at = System.monotonic_time(:millisecond)

      result =
        GitCore.Remote.mirror(
          request,
          "github_pat_secret",
          [
            git: fake_git.git,
            resolver: public_resolver(),
            credential_root: Path.join(tmp_dir, "callback-credentials")
          ] ++ callback_opts
        )

      quarantine = assert_cleanup_pending(result, expected_kind, request.destination)
      assert {:ok, []} = File.ls(quarantine)

      elapsed = System.monotonic_time(:millisecond) - started_at
      assert elapsed < 750, "#{name} callback cleanup took #{elapsed}ms"
    end

    eventually(fn -> assert Task.Supervisor.children(GitCore.RemoteTaskSupervisor) == [] end)
  end

  @tag :tmp_dir
  test "caller and supervisor death terminate a running control callback and remote group", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    test_pid = self()

    for owner_kind <- [:caller, :supervisor] do
      destination = Path.join(tmp_dir, "control-owner-#{owner_kind}.git")
      credential_root = Path.join(tmp_dir, "control-owner-#{owner_kind}-credentials")
      request = request_fixture(tmp_dir, %{destination: destination})
      quarantines_before = cleanup_quarantines(tmp_dir)
      File.write!(fake_git.mode_file, "block")
      File.rm(fake_git.child_pid)

      supervisor =
        if owner_kind == :supervisor do
          {:ok, supervisor} = Task.Supervisor.start_link()
          Elixir.Process.unlink(supervisor)
          supervisor
        end

      on_exit(fn ->
        if is_pid(supervisor) and Elixir.Process.alive?(supervisor),
          do: Elixir.Process.exit(supervisor, :kill)

        File.rm_rf(destination)
        File.rm_rf(credential_root)
      end)

      callback = fn ->
        if File.exists?(fake_git.child_pid) do
          send(test_pid, {:owner_callback_started, owner_kind, self()})

          receive do
          after
            30_000 -> false
          end
        else
          false
        end
      end

      caller =
        spawn(fn ->
          opts = [
            git: fake_git.git,
            resolver: public_resolver(),
            credential_root: credential_root,
            cancel?: callback
          ]

          opts = if supervisor, do: Keyword.put(opts, :task_supervisor, supervisor), else: opts
          result = GitCore.Remote.mirror(request, "github_pat_secret", opts)
          send(test_pid, {:owner_callback_result, owner_kind, result})
        end)

      assert_receive {:owner_callback_started, ^owner_kind, callback_worker}, 5_000
      child_pid = fake_git.child_pid |> File.read!() |> String.trim()
      stopped_at = System.monotonic_time(:millisecond)

      case owner_kind do
        :caller -> Elixir.Process.exit(caller, :kill)
        :supervisor -> Elixir.Process.exit(supervisor, :kill)
      end

      eventually(fn -> refute Elixir.Process.alive?(callback_worker) end)
      eventually(fn -> refute os_process_alive?(child_pid) end)
      assert System.monotonic_time(:millisecond) - stopped_at < 6_000

      case owner_kind do
        :caller ->
          eventually(fn -> refute File.exists?(destination) end)
          eventually(fn -> assert {:ok, []} = File.ls(credential_root) end)
          assert [caller_quarantine] = new_cleanup_quarantines(tmp_dir, quarantines_before)
          assert_private_quarantine(caller_quarantine, destination)

          argv_before_retry = File.read(fake_git.argv_log)

          retry_result =
            GitCore.Remote.mirror(request, "github_pat_secret",
              git: fake_git.git,
              resolver: fn _host, _family ->
                send(test_pid, :owner_retry_resolver_invoked)
                []
              end,
              credential_root: credential_root
            )

          retry_quarantine =
            assert_cleanup_pending(retry_result, :previous_failure, destination)

          assert retry_quarantine == caller_quarantine
          assert File.read(fake_git.argv_log) == argv_before_retry
          refute_receive :owner_retry_resolver_invoked

        :supervisor ->
          assert_receive {:owner_callback_result, :supervisor, supervisor_result}, 5_000

          _quarantine =
            assert_cleanup_pending(supervisor_result, :owner_down, destination)

          eventually(fn -> refute File.exists?(destination) end)
          eventually(fn -> assert {:ok, []} = File.ls(credential_root) end)
      end

      assert :ok =
               GitCore.RemoteLimiter.with_permit(fn -> :ok end, server: GitCore.RemoteLimiter)
    end
  end

  test "repeated control checks leave no callback worker exit messages" do
    previous_trap_exit = Elixir.Process.flag(:trap_exit, true)
    parent_monitor = Elixir.Process.monitor(self())

    try do
      opts = [
        cancel?: fn -> false end,
        heartbeat: fn -> :ok end,
        absolute_deadline: System.monotonic_time(:millisecond) + 5_000,
        parent_monitor: parent_monitor,
        owner_exit_pid: self()
      ]

      for _iteration <- 1..100 do
        assert :ok = GitCore.Remote.Control.check(opts)
      end

      refute_receive {:EXIT, _callback_worker, _reason}
      refute_receive {:DOWN, _monitor, :process, _callback_worker, _reason}
    after
      Elixir.Process.demonitor(parent_monitor, [:flush])
      Elixir.Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  test "callback worker monitors its owner across the unlink acknowledgement handoff" do
    test_pid = self()

    owner =
      spawn(fn ->
        Elixir.Process.flag(:trap_exit, true)
        parent_monitor = Elixir.Process.monitor(test_pid)

        result =
          GitCore.Remote.Control.check(
            cancel?: fn -> false end,
            heartbeat: fn -> :ok end,
            absolute_deadline: System.monotonic_time(:millisecond) + 5_000,
            parent_monitor: parent_monitor,
            owner_exit_pid: test_pid,
            test_handoff_observer: test_pid
          )

        send(test_pid, {:handoff_owner_result, result})
      end)

    assert_receive {:control_handoff, ^owner, callback_worker, _reply}, 2_000
    assert Elixir.Process.alive?(callback_worker)
    assert {:links, links} = Elixir.Process.info(callback_worker, :links)
    refute owner in links
    Elixir.Process.exit(owner, :kill)
    eventually(fn -> refute Elixir.Process.alive?(callback_worker) end)
    refute_receive {:handoff_owner_result, _result}
  end

  @tag :tmp_dir
  test "rejects invalid requests, credentials, and options without deleting an existing path", %{
    tmp_dir: tmp_dir
  } do
    request = request_fixture(tmp_dir)
    destination = request.destination
    File.mkdir!(destination)
    sentinel = Path.join(destination, "sentinel")
    File.write!(sentinel, "keep")

    assert {:error, %GitCore.Remote.Error{kind: :destination_exists}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               git: System.find_executable("git"),
               resolver: public_resolver(),
               credential_root: Path.join(tmp_dir, "credentials")
             )

    assert File.read!(sentinel) == "keep"

    for {invalid_request, expected_kind} <- [
          {%{request | provider: :gitlab}, :unsupported_provider},
          {%{request | owner: "../octocat"}, :invalid_request},
          {%{request | repository: "repo/name"}, :invalid_request},
          {%{request | credential_login: "bad\nlogin"}, :invalid_credential},
          {%{request | default_branch: "../main"}, :invalid_request},
          {%{request | destination: "relative.git"}, :invalid_destination}
        ] do
      assert {:error, %GitCore.Remote.Error{kind: ^expected_kind}} =
               GitCore.Remote.mirror(invalid_request, "github_pat_secret")
    end

    for invalid_pat <- ["", "bad\npat", "bad" <> <<0>> <> "pat", String.duplicate("p", 4_097)] do
      assert {:error, %GitCore.Remote.Error{kind: :invalid_credential}} =
               GitCore.Remote.mirror(request, invalid_pat)
    end

    assert {:error, %GitCore.Remote.Error{kind: :invalid_options}} =
             GitCore.Remote.mirror(request, "github_pat_secret", unknown: true)

    assert {:error, %GitCore.Remote.Error{kind: :invalid_options}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               resolver: public_resolver(),
               resolver: public_resolver()
             )

    real_parent = Path.join(tmp_dir, "real-parent")
    linked_parent = Path.join(tmp_dir, "linked-parent")
    File.mkdir!(real_parent)
    File.ln_s!(real_parent, linked_parent)

    linked_request = %{
      request
      | destination: Path.join(linked_parent, "linked-destination.git")
    }

    assert {:error, %GitCore.Remote.Error{kind: :invalid_destination}} =
             GitCore.Remote.mirror(linked_request, "github_pat_secret",
               git: System.find_executable("git"),
               resolver: public_resolver(),
               credential_root: Path.join(tmp_dir, "other-credentials")
             )

    refute File.exists?(Path.join(real_parent, "linked-destination.git"))

    assert {:error, %GitCore.Remote.Error{kind: :invalid_options}} =
             GitCore.Remote.mirror(
               %{request | destination: Path.join(tmp_dir, "unused-destination.git")},
               "github_pat_secret",
               credential_root: Path.join(linked_parent, "credentials")
             )

    shared_root = Path.join(tmp_dir, "shared-root")
    File.mkdir!(shared_root)
    File.chmod!(shared_root, 0o755)
    shared_destination = Path.join(tmp_dir, "shared-root-destination.git")

    on_exit(fn ->
      File.chmod(shared_root, 0o755)
      File.rm_rf(shared_destination)
    end)

    assert {:error, %GitCore.Remote.Error{kind: :invalid_options}} =
             GitCore.Remote.mirror(
               %{request | destination: shared_destination},
               "github_pat_secret",
               git: write_fake_git!(tmp_dir).git,
               resolver: public_resolver(),
               credential_root: shared_root
             )

    assert {:ok, %File.Stat{mode: shared_mode}} = File.stat(shared_root)
    assert Bitwise.band(shared_mode, 0o777) == 0o755

    for broad_root <- [System.tmp_dir!(), "/"] do
      assert {:ok, %File.Stat{mode: mode_before}} = File.stat(broad_root)

      assert {:error, %GitCore.Remote.Error{kind: :invalid_options}} =
               GitCore.Remote.mirror(
                 %{request | destination: Path.join(tmp_dir, "broad-root.git")},
                 "github_pat_secret",
                 credential_root: broad_root
               )

      assert {:ok, %File.Stat{mode: mode_after}} = File.stat(broad_root)
      assert mode_after == mode_before
    end

    secret = "github_pat_never_inspect"
    error = %GitCore.Remote.Error{kind: :invalid_credential, detail: secret}
    refute inspect(error) =~ secret
    assert inspect(error) == "#GitCore.Remote.Error<kind: :invalid_credential>"
  end

  test "host policy pins all public A and AAAA answers and rejects every non-public answer" do
    assert {:ok, policy} = GitCore.Remote.HostPolicy.resolve_github(public_resolver())
    assert length(policy.addresses) == 2
    assert policy.curlopt_resolve =~ "github.com:443:140.82.121.3"
    assert policy.curlopt_resolve =~ "[2606:50c0:8000::154]"

    blocked = [
      {0, 0, 0, 1},
      {10, 0, 0, 1},
      {100, 64, 0, 1},
      {127, 0, 0, 1},
      {169, 254, 1, 1},
      {172, 16, 0, 1},
      {192, 0, 0, 1},
      {192, 0, 2, 1},
      {192, 168, 0, 1},
      {198, 18, 0, 1},
      {198, 51, 100, 1},
      {203, 0, 113, 1},
      {224, 0, 0, 1},
      {240, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 0},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 2},
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1},
      {0x64, 0xFF9B, 0, 0, 0, 0, 0, 1},
      {0x100, 0, 0, 0, 0, 0, 0, 1},
      {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
      {0x2002, 0, 0, 0, 0, 0, 0, 1},
      {0x3FFF, 0, 0, 0, 0, 0, 0, 1},
      {0xFC00, 0, 0, 0, 0, 0, 0, 1},
      {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0xFF00, 0, 0, 0, 0, 0, 0, 1}
    ]

    for address <- blocked do
      resolver = fn
        "github.com", :a ->
          if tuple_size(address) == 4, do: [address], else: [{140, 82, 121, 3}]

        "github.com", :aaaa ->
          if tuple_size(address) == 8,
            do: [address],
            else: [{0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154}]
      end

      assert {:error, :host_policy} = GitCore.Remote.HostPolicy.resolve_github(resolver)
    end

    assert {:error, :host_policy} = GitCore.Remote.HostPolicy.resolve_github(fn _, _ -> [] end)
  end

  @tag :tmp_dir
  test "mirror failures retain a private cleanup quarantine with safe classification", %{
    tmp_dir: tmp_dir
  } do
    request = request_fixture(tmp_dir)

    host_result =
      GitCore.Remote.mirror(request, "github_pat_secret",
        git: write_fake_git!(tmp_dir).git,
        resolver: fn
          "github.com", :a -> [{127, 0, 0, 1}]
          "github.com", :aaaa -> []
        end,
        credential_root: Path.join(tmp_dir, "credentials")
      )

    host_quarantine = assert_cleanup_pending(host_result, :host_policy, request.destination)
    assert {:ok, []} = File.ls(host_quarantine)

    slow_request = %{
      request
      | destination: Path.join(tmp_dir, "slow-host-policy.git")
    }

    with_limits([remote_wall_time_ms: 50], fn ->
      slow_result =
        GitCore.Remote.mirror(slow_request, "github_pat_secret",
          git: write_fake_git!(tmp_dir).git,
          resolver: fn _host, _family ->
            Elixir.Process.sleep(500)
            [{140, 82, 121, 3}]
          end,
          credential_root: Path.join(tmp_dir, "slow-credentials")
        )

      slow_quarantine = assert_cleanup_pending(slow_result, :timeout, slow_request.destination)
      assert {:ok, []} = File.ls(slow_quarantine)
    end)
  end

  @tag :tmp_dir
  test "repeated failures reuse one deterministic quarantine before external effects", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    request = request_fixture(tmp_dir)
    resolver_calls = :atomics.new(1, signed: false)
    credential_root = Path.join(tmp_dir, "repeated-credentials")

    resolver = fn _host, _family ->
      :atomics.add_get(resolver_calls, 1, 1)
      []
    end

    started_at = System.monotonic_time(:millisecond)

    first_result =
      GitCore.Remote.mirror(request, "github_pat_secret",
        git: fake_git.git,
        resolver: resolver,
        credential_root: credential_root
      )

    first_quarantine =
      assert_cleanup_pending(first_result, :host_policy, request.destination)

    calls_after_failure = :atomics.get(resolver_calls, 1)
    argv_after_failure = File.read(fake_git.argv_log)

    second_result =
      GitCore.Remote.mirror(request, "github_pat_secret",
        git: fake_git.git,
        resolver: resolver,
        credential_root: credential_root
      )

    second_quarantine =
      assert_cleanup_pending(second_result, :previous_failure, request.destination)

    assert second_quarantine == first_quarantine
    assert {:ok, []} = File.ls(first_quarantine)
    assert :atomics.get(resolver_calls, 1) == calls_after_failure
    assert File.read(fake_git.argv_log) == argv_after_failure
    refute File.exists?(credential_root)
    assert MapSet.size(cleanup_quarantines(tmp_dir)) == 1
    assert System.monotonic_time(:millisecond) - started_at < 1_500

    remote_source =
      __DIR__
      |> Path.join("../lib/git_core/remote.ex")
      |> Path.expand()
      |> File.read!()

    refute remote_source =~ "File.rm_rf"
  end

  @tag :tmp_dir
  test "different canonical destinations use distinct strict hashed cleanup slots", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    credential_root = Path.join(tmp_dir, "hashed-slot-credentials")

    requests = [
      request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "private-alpha-name.git")}),
      request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "private-beta-name.git")})
    ]

    quarantines =
      Enum.map(requests, fn request ->
        result =
          GitCore.Remote.mirror(request, "github_pat_secret",
            git: fake_git.git,
            resolver: fn _host, _family -> [] end,
            credential_root: credential_root
          )

        quarantine = assert_cleanup_pending(result, :host_policy, request.destination)
        assert quarantine == expected_cleanup_slot(request.destination)
        refute Path.basename(quarantine) =~ Path.basename(request.destination)
        quarantine
      end)

    assert [first, second] = quarantines
    refute first == second
    assert MapSet.size(cleanup_quarantines(tmp_dir)) == 2
  end

  @tag :tmp_dir
  test "preexisting malformed cleanup slots fail closed before resolver or git", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    resolver_calls = :atomics.new(1, signed: false)
    credential_root = Path.join(tmp_dir, "bad-slot-credentials")

    resolver = fn _host, _family ->
      :atomics.add_get(resolver_calls, 1, 1)
      []
    end

    for kind <- [:regular, :symlink, :broad_directory] do
      destination = Path.join(tmp_dir, "bad-slot-#{kind}.git")
      request = request_fixture(tmp_dir, %{destination: destination})
      quarantine = expected_cleanup_slot(destination)

      case kind do
        :regular ->
          File.write!(quarantine, "not a cleanup directory")

        :symlink ->
          target = Path.join(tmp_dir, "bad-slot-target-#{kind}")
          File.mkdir!(target)
          File.chmod!(target, 0o700)
          File.ln_s!(target, quarantine)

        :broad_directory ->
          File.mkdir!(quarantine)
          File.chmod!(quarantine, 0o755)
      end

      assert {:error, %GitCore.Remote.Error{kind: :unsafe_cleanup_state}} =
               GitCore.Remote.mirror(request, "github_pat_secret",
                 git: fake_git.git,
                 resolver: resolver,
                 credential_root: credential_root
               )

      refute File.exists?(destination)
    end

    assert :atomics.get(resolver_calls, 1) == 0
    assert {:error, :enoent} = File.read(fake_git.argv_log)
    refute File.exists?(credential_root)
  end

  @tag :tmp_dir
  test "concurrent mirrors for one destination retain at most one cleanup slot", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    request = request_fixture(tmp_dir)
    test_pid = self()
    first_resolver_call = :atomics.new(1, signed: false)
    limiter = start_supervised!({GitCore.RemoteLimiter, server: nil, capacity: 2}, id: make_ref())

    resolver = fn _host, _family ->
      if :atomics.compare_exchange(first_resolver_call, 1, 0, 1) == :ok do
        send(test_pid, {:concurrent_resolver_started, self()})

        receive do
          :release_concurrent_resolver -> :ok
        end
      end

      []
    end

    opts = [
      git: fake_git.git,
      resolver: resolver,
      credential_root: Path.join(tmp_dir, "concurrent-slot-credentials"),
      limiter: limiter
    ]

    first = Task.async(fn -> GitCore.Remote.mirror(request, "github_pat_secret", opts) end)
    assert_receive {:concurrent_resolver_started, resolver_worker}, 2_000
    second = Task.async(fn -> GitCore.Remote.mirror(request, "github_pat_secret", opts) end)

    assert {:error, %GitCore.Remote.Error{kind: :destination_exists}} = Task.await(second, 5_000)
    send(resolver_worker, :release_concurrent_resolver)

    first_quarantine =
      first
      |> Task.await(5_000)
      |> assert_cleanup_pending(:host_policy, request.destination)

    assert first_quarantine == expected_cleanup_slot(request.destination)
    assert MapSet.size(cleanup_quarantines(tmp_dir)) == 1
  end

  @tag :tmp_dir
  test "credential daemon startup is bounded and leaves no socket state", %{tmp_dir: tmp_dir} do
    fake_git = write_fake_git!(tmp_dir)
    request = request_fixture(tmp_dir)
    credential_root = Path.join(tmp_dir, "credentials")
    File.write!(fake_git.mode_file, "credential-timeout")

    with_limits([remote_credential_startup_ms: 200], fn ->
      result =
        GitCore.Remote.mirror(request, "github_pat_secret",
          git: fake_git.git,
          resolver: public_resolver(),
          credential_root: credential_root
        )

      quarantine = assert_cleanup_pending(result, :credential_unavailable, request.destination)
      assert {:ok, []} = File.ls(quarantine)
    end)

    assert {:ok, []} = File.ls(credential_root)
  end

  @tag :tmp_dir
  test "supports empty mirrors and refreshes only heads and tags without deleting on failure", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    credential_root = Path.join(tmp_dir, "credentials")
    empty_request = request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "empty.git")})
    File.write!(fake_git.mode_file, "empty")

    assert {:ok, %GitCore.Remote.Result{empty?: true, refs: 0}} =
             GitCore.Remote.mirror(empty_request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    request = request_fixture(tmp_dir)
    File.write!(fake_git.mode_file, "success")

    assert {:ok, %GitCore.Remote.Result{empty?: false, refs: 1}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    {:ok, first_oid} = GitCore.exact_ref(request.destination, "refs/heads/main")
    File.write!(fake_git.mode_file, "refresh")

    assert {:ok, %GitCore.Remote.Result{empty?: false, refs: 2}} =
             GitCore.Remote.refresh(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    assert {:ok, second_oid} = GitCore.exact_ref(request.destination, "refs/heads/main")
    refute first_oid == second_oid
    assert {:ok, _tag_oid} = GitCore.exact_ref(request.destination, "refs/tags/v1")
    assert {:ok, nil} = GitCore.exact_ref(request.destination, "refs/pull/2/head")
    assert Enum.all?(local_config(request.destination), &(not String.starts_with?(&1, "remote.")))

    argv = File.read!(fake_git.argv_log)
    assert argv =~ "ARG=--no-auto-maintenance"
    assert argv =~ "ARG=--no-write-fetch-head"

    File.write!(fake_git.mode_file, "fetch-fail")

    assert {:error, %GitCore.Remote.Error{kind: :process_exit}} =
             GitCore.Remote.refresh(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    assert File.dir?(request.destination)
    assert {:ok, ^second_oid} = GitCore.exact_ref(request.destination, "refs/heads/main")
  end

  @tag :tmp_dir
  test "bounds output and disk while rejecting corrupt, linked, alternate, and shallow mirrors",
       %{
         tmp_dir: tmp_dir
       } do
    fake_git = write_fake_git!(tmp_dir)
    credential_root = Path.join(tmp_dir, "credentials")

    cases = [
      {"output", :output_limit, [remote_output_bytes: 128]},
      {"process-fail", :process_exit, []},
      {"disk-block", :repository_limit, [remote_repository_bytes: 512]},
      {"corrupt", :source_validation, []},
      {"symlink", :source_validation, []},
      {"alternate", :source_validation, []},
      {"shallow", :source_validation, []}
    ]

    for {mode, expected_kind, limit_overrides} <- cases do
      destination = Path.join(tmp_dir, "#{mode}.git")
      request = request_fixture(tmp_dir, %{destination: destination})
      File.write!(fake_git.mode_file, mode)
      _result = File.rm(fake_git.child_pid)

      with_limits(limit_overrides, fn ->
        result =
          GitCore.Remote.mirror(request, "github_pat_secret",
            git: fake_git.git,
            resolver: public_resolver(),
            credential_root: credential_root
          )

        quarantine = assert_cleanup_pending(result, expected_kind, destination)

        if mode == "corrupt" do
          assert File.read!(Path.join(quarantine, "corrupt")) == "not a repository"
        end
      end)

      if File.exists?(fake_git.child_pid) do
        child_pid = fake_git.child_pid |> File.read!() |> String.trim()
        eventually(fn -> refute os_process_alive?(child_pid) end)
      end
    end
  end

  @tag :tmp_dir
  test "rejects missing defaults, excess refs, unsafe config, and invalid refresh storage", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    credential_root = Path.join(tmp_dir, "credentials")

    for {mode, expected_kind, overrides} <- [
          {"missing-default", :default_branch, []},
          {"many-refs", :ref_limit, [remote_refs: 2]},
          {"unsafe-config", :unsafe_config, []}
        ] do
      request = request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "#{mode}.git")})
      File.write!(fake_git.mode_file, mode)

      with_limits(overrides, fn ->
        result =
          GitCore.Remote.mirror(request, "github_pat_secret",
            git: fake_git.git,
            resolver: public_resolver(),
            credential_root: credential_root
          )

        _quarantine = assert_cleanup_pending(result, expected_kind, request.destination)
      end)
    end

    request = request_fixture(tmp_dir)
    File.write!(fake_git.mode_file, "success")

    assert {:ok, %GitCore.Remote.Result{}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    unsafe_link = Path.join(request.destination, "unsafe-refresh-link")
    File.ln_s!(System.tmp_dir!(), unsafe_link)

    assert {:error, %GitCore.Remote.Error{kind: :source_validation}} =
             GitCore.Remote.refresh(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    assert File.dir?(request.destination)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(unsafe_link)

    File.rm!(unsafe_link)
    hooks = Path.join(request.destination, "hooks")
    File.mkdir!(hooks)
    hook = Path.join(hooks, "pre-fetch")
    File.write!(hook, "must remain untouched")
    before_refresh = File.read!(fake_git.argv_log) |> occurrences("ARG=fetch")

    assert {:error, %GitCore.Remote.Error{kind: :source_validation}} =
             GitCore.Remote.refresh(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    assert File.read!(hook) == "must remain untouched"
    assert File.read!(fake_git.argv_log) |> occurrences("ARG=fetch") == before_refresh
  end

  @tag :tmp_dir
  test "cancellation, heartbeat failure, timeout, and owner death terminate descendants", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    credential_root = Path.join(tmp_dir, "credentials")

    for {mode, expected_kind, callback_opts} <- [
          {"trickle", :cancelled, [cancel?: fn -> File.exists?(fake_git.child_pid) end]},
          {"block", :heartbeat_failed,
           [heartbeat: fn -> if File.exists?(fake_git.child_pid), do: :error, else: :ok end]},
          {"ignore-term", :timeout, []}
        ] do
      destination = Path.join(tmp_dir, "#{expected_kind}.git")
      request = request_fixture(tmp_dir, %{destination: destination})
      File.write!(fake_git.mode_file, mode)
      _result = File.rm(fake_git.child_pid)

      overrides =
        if expected_kind == :timeout,
          do: [remote_wall_time_ms: 300, remote_kill_escalation_ms: 1_000],
          else: []

      with_limits(overrides, fn ->
        result =
          GitCore.Remote.mirror(
            request,
            "github_pat_secret",
            [
              git: fake_git.git,
              resolver: public_resolver(),
              credential_root: credential_root
            ] ++ callback_opts
          )

        quarantine = assert_cleanup_pending(result, expected_kind, destination)
        assert {:ok, []} = File.ls(quarantine)
      end)

      child_pid = fake_git.child_pid |> File.read!() |> String.trim()
      eventually(fn -> refute os_process_alive?(child_pid) end)
      assert {:ok, []} = File.ls(credential_root)
    end

    owner_destination = Path.join(tmp_dir, "owner-death.git")
    owner_request = request_fixture(tmp_dir, %{destination: owner_destination})
    File.write!(fake_git.mode_file, "block")
    _result = File.rm(fake_git.child_pid)
    test_pid = self()
    owner_quarantines_before = cleanup_quarantines(tmp_dir)

    owner =
      spawn(fn ->
        send(test_pid, :owner_started)

        GitCore.Remote.mirror(owner_request, "github_pat_secret",
          git: fake_git.git,
          resolver: public_resolver(),
          credential_root: credential_root
        )
      end)

    assert_receive :owner_started
    eventually(fn -> assert File.exists?(fake_git.child_pid) end)
    child_pid = fake_git.child_pid |> File.read!() |> String.trim()
    Elixir.Process.exit(owner, :kill)
    eventually(fn -> refute os_process_alive?(child_pid) end)
    eventually(fn -> refute File.exists?(owner_destination) end, 750)
    eventually(fn -> assert {:ok, []} = File.ls(credential_root) end, 750)
    assert [owner_quarantine] = new_cleanup_quarantines(tmp_dir, owner_quarantines_before)
    assert_private_quarantine(owner_quarantine, owner_destination)

    hard_destination = Path.join(tmp_dir, "hard-owner-death.git")
    hard_request = request_fixture(tmp_dir, %{destination: hard_destination})
    existing_tasks = MapSet.new(Task.Supervisor.children(GitCore.RemoteTaskSupervisor))
    File.write!(fake_git.mode_file, "block")
    _result = File.rm(fake_git.child_pid)

    spawn(fn ->
      result =
        GitCore.Remote.mirror(hard_request, "github_pat_secret",
          git: fake_git.git,
          resolver: public_resolver(),
          credential_root: credential_root
        )

      send(test_pid, {:hard_owner_result, result})
    end)

    eventually(fn -> assert File.exists?(fake_git.child_pid) end)

    internal_owner =
      eventually(fn ->
        new_tasks =
          GitCore.RemoteTaskSupervisor
          |> Task.Supervisor.children()
          |> MapSet.new()
          |> MapSet.difference(existing_tasks)
          |> MapSet.to_list()

        assert length(new_tasks) == 1
        hd(new_tasks)
      end)

    hard_child_pid = fake_git.child_pid |> File.read!() |> String.trim()
    Elixir.Process.exit(internal_owner, :kill)

    assert_receive {:hard_owner_result,
                    {:error, %GitCore.Remote.Error{kind: :remote_unavailable}}},
                   5_000

    eventually(fn -> refute os_process_alive?(hard_child_pid) end)
    assert File.dir?(hard_destination)

    eventually(fn ->
      assert :ok = GitCore.Remote.CredentialReaper.reap(credential_root)
      assert {:ok, []} = File.ls(credential_root)
    end)

    File.rm_rf!(hard_destination)

    supervisor_destination = Path.join(tmp_dir, "supervisor-death.git")
    supervisor_request = request_fixture(tmp_dir, %{destination: supervisor_destination})
    isolated_supervisor = start_supervised!({Task.Supervisor, name: nil}, id: make_ref())
    File.write!(fake_git.mode_file, "block")
    _result = File.rm(fake_git.child_pid)

    caller =
      spawn(fn ->
        result =
          GitCore.Remote.mirror(supervisor_request, "github_pat_secret",
            git: fake_git.git,
            resolver: public_resolver(),
            credential_root: credential_root,
            task_supervisor: isolated_supervisor
          )

        send(test_pid, {:isolated_supervisor_result, result})
      end)

    eventually(fn -> assert File.exists?(fake_git.child_pid) end)
    supervised_child_pid = fake_git.child_pid |> File.read!() |> String.trim()
    assert :ok = Supervisor.stop(isolated_supervisor, :shutdown, 20_000)

    assert_receive {:isolated_supervisor_result, isolated_result}, 20_000

    _quarantine =
      assert_cleanup_pending(isolated_result, :owner_down, supervisor_destination)

    eventually(fn -> refute os_process_alive?(supervised_child_pid) end)
    eventually(fn -> refute File.exists?(supervisor_destination) end, 750)
    refute Elixir.Process.alive?(caller)
  end

  @tag :tmp_dir
  test "credential reaper removes only canonical orphans and preserves live groups", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "credentials")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    orphan = private_operation_directory!(root, "o")
    assert :ok = GitCore.Remote.CredentialReaper.write_metadata(orphan, 2_000_000_000)
    metadata = Path.join(orphan, "operation.json")
    assert {:ok, %File.Stat{mode: orphan_mode}} = File.lstat(metadata)
    assert Bitwise.band(orphan_mode, 0o777) == 0o600
    refute File.read!(metadata) =~ "github_pat"
    assert :ok = GitCore.Remote.CredentialReaper.reap(root)
    refute File.exists?(orphan)

    sleep = System.find_executable("sleep") || flunk("sleep executable is required")

    assert {:ok, live_pid, live_os_pid} =
             :exec.run([sleep, "30"], [:monitor, {:group, 0}, :kill_group])

    live = private_operation_directory!(root, "l")
    assert :ok = GitCore.Remote.CredentialReaper.write_metadata(live, live_os_pid)
    assert :ok = GitCore.Remote.CredentialReaper.reap(root)
    assert File.dir?(live)
    _result = :exec.kill(live_pid, :sigkill)
    eventually(fn -> refute live_os_pid in GitCore.Remote.Process.which_children() end)
    assert :ok = GitCore.Remote.CredentialReaper.reap(root)
    refute File.exists?(live)

    unsafe = private_operation_directory!(root, "s")
    assert :ok = GitCore.Remote.CredentialReaper.write_metadata(unsafe, 2_000_000_001)
    File.ln_s!(System.tmp_dir!(), Path.join(unsafe, "unsafe-link"))
    assert {:error, :unsafe_credential_state} = GitCore.Remote.CredentialReaper.reap(root)
    assert File.dir?(unsafe)

    linked_root = Path.join(tmp_dir, "linked-credentials")
    File.ln_s!(root, linked_root)

    assert {:error, :unsafe_credential_state} =
             GitCore.Remote.CredentialReaper.reap(linked_root)
  end

  @tag :tmp_dir
  test "credential cleanup is deadline bounded and mirror cleanup failures are typed", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "bounded-credentials")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    orphan = private_operation_directory!(root, "b")
    assert :ok = GitCore.Remote.CredentialReaper.write_metadata(orphan, 2_000_000_002)

    for index <- 1..2_000 do
      File.write!(Path.join(orphan, "entry-#{index}"), "fixture")
    end

    started_at = System.monotonic_time(:millisecond)

    with_limits([remote_cleanup_wait_ms: 1], fn ->
      assert {:error, :cleanup_timeout} = GitCore.Remote.CredentialReaper.reap(root)
    end)

    assert System.monotonic_time(:millisecond) - started_at < 1_000

    fake_git = write_fake_git!(tmp_dir)
    request = request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "cleanup-blocked.git")})
    credential_root = Path.join(System.tmp_dir!(), "remote-cleanup-#{System.unique_integer()}")
    File.write!(fake_git.mode_file, "trickle")

    on_exit(fn ->
      File.chmod(tmp_dir, 0o700)
      File.rm_rf(request.destination)
      File.rm_rf(credential_root)
    end)

    cancel = fn ->
      if File.exists?(fake_git.child_pid) do
        File.chmod!(tmp_dir, 0o500)
        true
      else
        false
      end
    end

    assert {:error, %GitCore.Remote.Error{kind: :unsafe_cleanup_state}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root,
               cancel?: cancel
             )

    assert File.dir?(request.destination)
    File.chmod!(tmp_dir, 0o700)
  end

  @tag :tmp_dir
  test "a hard-killed reaper caller owns and terminates its filesystem worker", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "owned-reaper")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    orphan = private_operation_directory!(root, "w")
    assert :ok = GitCore.Remote.CredentialReaper.write_metadata(orphan, 2_000_000_003)
    sentinel = Path.join(orphan, "sentinel")
    File.write!(sentinel, "keep")

    for index <- 1..3_000 do
      File.write!(Path.join(orphan, "entry-#{index}"), "fixture")
    end

    test_pid = self()

    caller =
      spawn(fn ->
        receive do
          :reap -> send(test_pid, {:reap_result, GitCore.Remote.CredentialReaper.reap(root)})
        end
      end)

    assert 1 = :erlang.trace(caller, true, [:procs])
    send(caller, :reap)
    assert_receive {:trace, ^caller, :spawn, worker, _mfa}, 2_000
    assert true = :erlang.suspend_process(worker)

    on_exit(fn ->
      if Elixir.Process.alive?(worker) do
        :erlang.resume_process(worker)
        Elixir.Process.exit(worker, :kill)
      end
    end)

    assert {:links, links} = Elixir.Process.info(caller, :links)
    assert worker in links
    Elixir.Process.exit(caller, :kill)
    eventually(fn -> refute Elixir.Process.alive?(worker) end)
    Elixir.Process.sleep(100)
    assert File.read!(sentinel) == "keep"
    refute_receive {:reap_result, _result}
  end

  @tag :tmp_dir
  test "mirror cleanup never removes a replacement destination", %{tmp_dir: tmp_dir} do
    fake_git = write_fake_git!(tmp_dir)
    request = request_fixture(tmp_dir)
    moved_destination = Path.join(tmp_dir, "moved-original.git")
    replacement_marker = Path.join(request.destination, "replacement")
    swapped = :atomics.new(1, signed: false)
    File.write!(fake_git.mode_file, "block")

    on_exit(fn ->
      File.rm_rf(request.destination)
      File.rm_rf(moved_destination)
    end)

    cancel = fn ->
      if File.exists?(fake_git.child_pid) and
           :atomics.compare_exchange(swapped, 1, 0, 1) == :ok do
        File.rename!(request.destination, moved_destination)
        File.mkdir!(request.destination)
        File.write!(replacement_marker, "keep")
        true
      else
        :atomics.get(swapped, 1) == 1
      end
    end

    assert {:error, %GitCore.Remote.Error{kind: :unsafe_cleanup_state}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: Path.join(tmp_dir, "credentials"),
               cancel?: cancel
             )

    assert File.read!(replacement_marker) == "keep"

    assert [] =
             Path.wildcard(Path.join(tmp_dir, ".fornacast-cleanup-*"), match_dot: true)

    assert File.dir?(moved_destination)
  end

  @tag :tmp_dir
  test "cleanup rechecks identity inside its worker before quarantine rename", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    request = request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "worker-race.git")})
    moved_destination = Path.join(tmp_dir, "worker-race-original.git")
    replacement_marker = Path.join(request.destination, "replacement")
    existing_tasks = MapSet.new(Task.Supervisor.children(GitCore.RemoteTaskSupervisor))
    test_pid = self()

    on_exit(fn ->
      File.rm_rf(request.destination)
      File.rm_rf(moved_destination)
    end)

    caller =
      spawn(fn ->
        result =
          GitCore.Remote.mirror(request, "github_pat_secret",
            git: fake_git.git,
            resolver: public_resolver(),
            credential_root: Path.join(tmp_dir, "worker-race-credentials"),
            cancel?: fn ->
              send(test_pid, {:worker_race_callback, self()})

              receive do
              after
                30_000 -> false
              end
            end
          )

        send(test_pid, {:worker_race_result, result})
      end)

    assert_receive {:worker_race_callback, callback_worker}, 2_000

    owner =
      eventually(fn ->
        new_tasks =
          GitCore.RemoteTaskSupervisor
          |> Task.Supervisor.children()
          |> MapSet.new()
          |> MapSet.difference(existing_tasks)
          |> MapSet.to_list()

        assert length(new_tasks) == 1
        hd(new_tasks)
      end)

    assert 1 = :erlang.trace(owner, true, [:procs])
    cleanup_worker = traced_spawn_from(owner, GitCore.Remote, 2_000)
    assert true = :erlang.suspend_process(cleanup_worker)

    on_exit(fn ->
      if Elixir.Process.alive?(cleanup_worker) do
        :erlang.resume_process(cleanup_worker)
        Elixir.Process.exit(cleanup_worker, :kill)
      end
    end)

    File.rename!(request.destination, moved_destination)
    File.mkdir!(request.destination)
    File.write!(replacement_marker, "keep")
    assert true = :erlang.resume_process(cleanup_worker)

    assert_receive {:worker_race_result,
                    {:error, %GitCore.Remote.Error{kind: :unsafe_cleanup_state}}},
                   5_000

    eventually(fn -> refute Elixir.Process.alive?(callback_worker) end)
    assert File.read!(replacement_marker) == "keep"
    assert File.dir?(moved_destination)
    assert [] = Path.wildcard(Path.join(tmp_dir, ".fornacast-cleanup-*"), match_dot: true)
    refute Elixir.Process.alive?(caller)
  end

  @tag :tmp_dir
  test "mirror rejects a successful git process that swaps the created destination", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    request = request_fixture(tmp_dir)
    File.write!(fake_git.mode_file, "swap-success")

    assert {:error, %GitCore.Remote.Error{kind: :unsafe_cleanup_state}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: Path.join(tmp_dir, "credentials")
             )

    assert File.dir?(request.destination <> ".swapped-original")
    assert File.dir?(request.destination)

    assert [] =
             Path.wildcard(Path.join(tmp_dir, ".fornacast-cleanup-*"), match_dot: true)
  end

  @tag :tmp_dir
  test "requires private destination mode for mirror, refresh, and failure cleanup", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    credential_root = Path.join(tmp_dir, "mode-credentials")
    request = request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "chmod-root.git")})
    File.write!(fake_git.mode_file, "chmod-root")

    assert {:error, %GitCore.Remote.Error{kind: :unsafe_cleanup_state}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    assert File.dir?(request.destination)
    assert {:ok, %File.Stat{mode: broad_mode}} = File.stat(request.destination)
    assert Bitwise.band(broad_mode, 0o777) == 0o755

    refresh_request =
      request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "broad-refresh.git")})

    File.write!(fake_git.mode_file, "success")

    assert {:ok, %GitCore.Remote.Result{}} =
             GitCore.Remote.mirror(refresh_request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    File.chmod!(refresh_request.destination, 0o755)
    argv_before_refresh = File.read!(fake_git.argv_log)

    assert {:error, %GitCore.Remote.Error{kind: :invalid_destination}} =
             GitCore.Remote.refresh(refresh_request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root
             )

    assert File.read!(fake_git.argv_log) == argv_before_refresh

    failure_request =
      request_fixture(tmp_dir, %{destination: Path.join(tmp_dir, "broad-failure.git")})

    File.write!(fake_git.mode_file, "block")
    File.rm(fake_git.child_pid)

    cancel = fn ->
      if File.exists?(fake_git.child_pid) do
        File.chmod!(failure_request.destination, 0o755)
        true
      else
        false
      end
    end

    assert {:error, %GitCore.Remote.Error{kind: :unsafe_cleanup_state}} =
             GitCore.Remote.mirror(failure_request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: credential_root,
               cancel?: cancel
             )

    assert File.dir?(failure_request.destination)
    assert {:ok, %File.Stat{mode: failure_mode}} = File.stat(failure_request.destination)
    assert Bitwise.band(failure_mode, 0o777) == 0o755

    assert [] =
             Path.wildcard(Path.join(tmp_dir, ".fornacast-cleanup-*"), match_dot: true)
  end

  @tag :tmp_dir
  test "rejects a destination whose private ancestor becomes a symlink mid-transfer", %{
    tmp_dir: tmp_dir
  } do
    fake_git = write_fake_git!(tmp_dir)
    destination_parent = Path.join(tmp_dir, "destination-parent")
    moved_parent = Path.join(tmp_dir, "destination-parent-real")
    File.mkdir!(destination_parent)

    request =
      request_fixture(tmp_dir, %{destination: Path.join(destination_parent, "repository.git")})

    File.write!(fake_git.mode_file, "slow-success")
    swapped = :atomics.new(1, signed: false)

    on_exit(fn ->
      case File.lstat(destination_parent) do
        {:ok, %File.Stat{type: :symlink}} -> File.rm(destination_parent)
        _other -> :ok
      end

      File.rm_rf(moved_parent)
    end)

    cancel = fn ->
      if File.exists?(fake_git.child_pid) and
           :atomics.compare_exchange(swapped, 1, 0, 1) == :ok do
        File.rename!(destination_parent, moved_parent)
        File.ln_s!(moved_parent, destination_parent)
      end

      false
    end

    assert {:error, %GitCore.Remote.Error{kind: :unsafe_cleanup_state}} =
             GitCore.Remote.mirror(request, "github_pat_secret",
               git: fake_git.git,
               resolver: public_resolver(),
               credential_root: Path.join(tmp_dir, "ancestor-credentials"),
               cancel?: cancel
             )

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(destination_parent)
    assert File.dir?(Path.join(moved_parent, "repository.git"))
    assert [] = Path.wildcard(Path.join(tmp_dir, ".fornacast-cleanup-*"), match_dot: true)
  end

  test "dedicated remote limiter enforces its own capacity and releases dead owners" do
    limiter = start_supervised!({GitCore.RemoteLimiter, server: nil, capacity: 1}, id: make_ref())
    test_pid = self()

    owner =
      spawn(fn ->
        GitCore.RemoteLimiter.with_permit(
          fn ->
            send(test_pid, :remote_permit_held)
            receive do: (:release -> :ok)
          end,
          server: limiter
        )
      end)

    assert_receive :remote_permit_held

    assert {:error, :busy} =
             GitCore.RemoteLimiter.with_permit(fn -> :unexpected end, server: limiter)

    Elixir.Process.exit(owner, :kill)

    eventually(fn ->
      assert :ok = GitCore.RemoteLimiter.with_permit(fn -> :ok end, server: limiter)
    end)
  end

  test "release and runtime image carry one erlexec manager, its port, Git, and SHELL" do
    root = Path.expand("../../..", __DIR__)
    dockerfile = File.read!(Path.join(root, "Dockerfile"))
    [_build, runtime] = String.split(dockerfile, "FROM ${DEBIAN_IMAGE} AS app", parts: 2)

    assert runtime =~ ~r/apt-get install.*?\bgit\b/s
    assert runtime =~ "SHELL=/bin/sh"

    child_specs = GitCore.Application.child_specs()

    refute Enum.any?(child_specs, fn spec ->
             Supervisor.child_spec(spec, []).id == :exec
           end)

    remote_supervisor = Enum.find(child_specs, &(&1.id == GitCore.RemoteTaskSupervisor))
    assert remote_supervisor.shutdown == 16_000

    child_ids = Enum.map(child_specs, & &1.id)

    assert Enum.find_index(child_ids, &(&1 == GitCore.RemoteTaskSupervisor)) <
             Enum.find_index(child_ids, &(&1 == GitCore.RemoteLimiter))

    erlexec_priv = :erlexec |> :code.priv_dir() |> to_string()
    assert [exec_port] = Path.wildcard(Path.join(erlexec_priv, "**/exec-port"))
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.stat(exec_port)
    assert Bitwise.band(mode, 0o111) != 0
  end

  defp write_fake_git!(tmp_dir) do
    fake_git = Path.join(tmp_dir, "fake-git")
    real_git = System.find_executable("git") || flunk("git executable is required")
    shell = System.find_executable("sh") || flunk("sh executable is required")
    sleep = System.find_executable("sleep") || flunk("sleep executable is required")
    ln = System.find_executable("ln") || flunk("ln executable is required")
    mv = System.find_executable("mv") || flunk("mv executable is required")
    chmod = System.find_executable("chmod") || flunk("chmod executable is required")
    argv_log = Path.join(tmp_dir, "argv.log")
    env_log = Path.join(tmp_dir, "env.log")
    stdin_log = Path.join(tmp_dir, "stdin.log")
    mode_file = Path.join(tmp_dir, "mode")
    child_pid = Path.join(tmp_dir, "child.pid")

    File.write!(fake_git, """
    #!#{shell}
    set -eu

    {
      printf 'BEGIN\\n'
      for argument in "$@"; do printf 'ARG=%s\\n' "$argument"; done
      printf 'END\\n'
    } >> #{shell_quote(argv_log)}

    {
      printf 'HOME=%s\\n' "${HOME-unset}"
      printf 'PATH=%s\\n' "${PATH-unset}"
      printf 'GIT_CONFIG_NOSYSTEM=%s\\n' "${GIT_CONFIG_NOSYSTEM-unset}"
      printf 'GIT_CONFIG_GLOBAL=%s\\n' "${GIT_CONFIG_GLOBAL-unset}"
      printf 'GIT_TERMINAL_PROMPT=%s\\n' "${GIT_TERMINAL_PROMPT-unset}"
      printf 'GIT_ALLOW_PROTOCOL=%s\\n' "${GIT_ALLOW_PROTOCOL-unset}"
      printf 'GIT_PROTOCOL_FROM_USER=%s\\n' "${GIT_PROTOCOL_FROM_USER-unset}"
      printf 'REMOTE_SECRET_SENTINEL=%s\\n' "${REMOTE_SECRET_SENTINEL-unset}"
    } >> #{shell_quote(env_log)}

    mode="success"
    if [ -f #{shell_quote(mode_file)} ]; then IFS= read -r mode < #{shell_quote(mode_file)} || true; fi

    case "${1-}" in
      credential-cache--daemon)
        if [ "$mode" = "credential-timeout" ]; then exec #{shell_quote(sleep)} 300; fi
        exec #{shell_quote(real_git)} "$@"
        ;;
      credential-cache)
        action=""
        for argument in "$@"; do action="$argument"; done

        if [ "$action" = "store" ]; then
          protocol=""
          host=""
          username=""
          password=""

          while IFS='=' read -r key value; do
            case "$key" in
              protocol) protocol="$value" ;;
              host) host="$value" ;;
              username) username="$value" ;;
              password) password="$value" ;;
            esac
          done

          {
            printf 'protocol=%s\\n' "$protocol"
            printf 'host=%s\\n' "$host"
            printf 'username_bytes=%s\\n' "${#username}"
            printf 'password_bytes=%s\\n' "${#password}"
          } >> #{shell_quote(stdin_log)}

          {
            printf 'protocol=%s\\n' "$protocol"
            printf 'host=%s\\n' "$host"
            printf 'username=%s\\n' "$username"
            printf 'password=%s\\n\\n' "$password"
          } | #{shell_quote(real_git)} "$@"
          exit $?
        fi

        exec #{shell_quote(real_git)} "$@"
        ;;
    esac

    command_name=""
    destination=""
    repository_path=""
    credential_helper=""
    for argument in "$@"; do
      destination="$argument"
      case "$argument" in
        clone|fetch|config|remote|for-each-ref|update-ref|fsck|symbolic-ref)
          if [ -z "$command_name" ]; then command_name="$argument"; fi
          ;;
        "credential.helper=cache --socket="*)
          credential_helper="$argument"
          ;;
        --git-dir=*)
          repository_path=${argument#--git-dir=}
          ;;
      esac
    done

    if [ "$command_name" = "clone" ]; then
      cached=$(printf 'protocol=https\\nhost=github.com\\n\\n' | #{shell_quote(real_git)} -c credential.helper= -c "$credential_helper" credential fill)
      printf '%s\\n' "$cached" | while IFS='=' read -r key value; do
        case "$key" in
          username) printf 'retrieved_username_bytes=%s\\n' "${#value}" ;;
          password) printf 'retrieved_password_bytes=%s\\n' "${#value}" ;;
        esac
      done >> #{shell_quote(stdin_log)}

      if [ "$mode" = "output" ]; then
        i=0
        while [ "$i" -lt 4096 ]; do printf 'remote-output' >&2; i=$((i + 1)); done
        exit 41
      fi

      if [ "$mode" = "process-fail" ]; then exit 43; fi

      if [ "$mode" = "corrupt" ]; then
        printf 'not a repository' > "$destination/corrupt"
        exit 0
      fi

      if [ "$mode" = "trickle" ]; then
        #{shell_quote(sleep)} 300 &
        child=$!
        printf '%s\\n' "$child" > #{shell_quote(child_pid)}

        while true; do
          printf 'x'
          #{shell_quote(sleep)} 0.01
        done
      fi

      if [ "$mode" = "block" ] || [ "$mode" = "ignore-term" ]; then
        if [ "$mode" = "ignore-term" ]; then
          trap '' TERM
          #{shell_quote(shell)} -c 'trap "" TERM; exec #{sleep} 300' &
        else
          #{shell_quote(sleep)} 300 &
        fi

        child=$!
        printf '%s\\n' "$child" > #{shell_quote(child_pid)}
        wait "$child"
        exit $?
      fi

      if [ "$mode" = "slow-success" ]; then
        #{shell_quote(sleep)} 0.4 &
        child=$!
        printf '%s\n' "$child" > #{shell_quote(child_pid)}
        wait "$child"
      fi

      #{shell_quote(real_git)} init --bare --object-format=sha1 "$destination" >/dev/null

      if [ "$mode" = "disk-block" ]; then
        i=0
        while [ "$i" -lt 4096 ]; do printf 'x' >> "$destination/oversized"; i=$((i + 1)); done
        #{shell_quote(sleep)} 300 &
        child=$!
        printf '%s\\n' "$child" > #{shell_quote(child_pid)}
        wait "$child"
        exit $?
      fi

      if [ "$mode" != "empty" ]; then
        tree=$(#{shell_quote(real_git)} --git-dir="$destination" mktree </dev/null)
        commit=$(GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.test GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.test #{shell_quote(real_git)} --git-dir="$destination" commit-tree "$tree" -m fixture)
        branch="main"
        if [ "$mode" = "missing-default" ]; then branch="other"; fi
        #{shell_quote(real_git)} --git-dir="$destination" update-ref "refs/heads/$branch" "$commit"
        #{shell_quote(real_git)} --git-dir="$destination" update-ref refs/pull/1/head "$commit"

        if [ "$mode" = "many-refs" ]; then
          #{shell_quote(real_git)} --git-dir="$destination" update-ref refs/tags/v1 "$commit"
        fi
      fi

      #{shell_quote(real_git)} --git-dir="$destination" remote add origin https://github.com/octocat/hello-world.git
      #{shell_quote(real_git)} --git-dir="$destination" config remote.origin.mirror true

      if [ "$mode" = "symlink" ]; then
        #{shell_quote(ln)} -s /tmp "$destination/unsafe-link"
      fi

      if [ "$mode" = "alternate" ]; then
        printf '/tmp/objects\\n' > "$destination/objects/info/alternates"
      fi

      if [ "$mode" = "shallow" ]; then
        printf '%s\\n' "$commit" > "$destination/shallow"
      fi

      if [ "$mode" = "unsafe-config" ]; then
        #{shell_quote(real_git)} --git-dir="$destination" config http.proxy http://127.0.0.1:1
      fi

      if [ "$mode" = "swap-success" ]; then
        #{shell_quote(mv)} "$destination" "$destination.swapped-original"
        #{shell_quote(real_git)} init --bare --object-format=sha1 "$destination" >/dev/null
      fi

      if [ "$mode" = "chmod-root" ]; then
        #{shell_quote(chmod)} 0755 "$destination"
      fi

      exit 0
    fi

    if [ "$command_name" = "fetch" ]; then
      if [ "$mode" = "fetch-fail" ]; then exit 42; fi

      parent=$(#{shell_quote(real_git)} --git-dir="$repository_path" rev-parse refs/heads/main)
      tree=$(#{shell_quote(real_git)} --git-dir="$repository_path" mktree </dev/null)
      commit=$(GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.test GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.test #{shell_quote(real_git)} --git-dir="$repository_path" commit-tree "$tree" -p "$parent" -m refresh)
      #{shell_quote(real_git)} --git-dir="$repository_path" update-ref refs/heads/main "$commit"
      #{shell_quote(real_git)} --git-dir="$repository_path" update-ref refs/tags/v1 "$commit"
      #{shell_quote(real_git)} --git-dir="$repository_path" update-ref refs/pull/2/head "$commit"
      exit 0
    fi

    exec #{shell_quote(real_git)} "$@"
    """)

    File.chmod!(fake_git, 0o700)

    %{
      git: fake_git,
      argv_log: argv_log,
      env_log: env_log,
      stdin_log: stdin_log,
      mode_file: mode_file,
      child_pid: child_pid
    }
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp occurrences(value, pattern), do: length(:binary.matches(value, pattern))

  defp assert_cleanup_pending(result, original_kind, destination) do
    assert {:error,
            %GitCore.Remote.Error{
              kind: :cleanup_pending,
              detail:
                detail = %{
                  original_kind: ^original_kind,
                  quarantine_path: quarantine_path,
                  identity: identity
                }
            } = error} = result

    refute File.exists?(destination)
    assert_private_quarantine(quarantine_path, destination)

    assert {:ok,
            %File.Stat{
              type: :directory,
              mode: mode,
              major_device: major_device,
              minor_device: minor_device,
              inode: inode
            }} = File.lstat(quarantine_path)

    assert identity == %{
             mode: Bitwise.band(mode, 0o777),
             major_device: major_device,
             minor_device: minor_device,
             inode: inode
           }

    refute inspect(error) =~ quarantine_path
    refute inspect(error) =~ "github_pat"
    refute inspect(detail) =~ quarantine_path
    refute inspect(detail) =~ "github_pat"
    refute inspect(detail) =~ "verified-octocat"
    quarantine_path
  end

  defp assert_private_quarantine(quarantine_path, destination) do
    assert Path.dirname(quarantine_path) == Path.dirname(destination)

    assert Path.basename(quarantine_path) =~
             ~r/\A\.fornacast-cleanup-v1-[A-Za-z0-9_-]{43}\z/

    assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(quarantine_path)
    assert Bitwise.band(mode, 0o777) == 0o700
    :ok
  end

  defp cleanup_quarantines(parent) do
    parent
    |> Path.join(".fornacast-cleanup-*")
    |> Path.wildcard(match_dot: true)
    |> MapSet.new()
  end

  defp expected_cleanup_slot(destination) do
    digest =
      :sha256
      |> :crypto.hash("fornacast.git-core.remote.cleanup-slot.v1\0" <> destination)
      |> Base.url_encode64(padding: false)

    Path.join(Path.dirname(destination), ".fornacast-cleanup-v1-" <> digest)
  end

  defp new_cleanup_quarantines(parent, before) do
    parent
    |> cleanup_quarantines()
    |> MapSet.difference(before)
    |> MapSet.to_list()
  end

  defp request_fixture(tmp_dir, attrs \\ %{}) do
    struct!(
      GitCore.Remote.Request,
      Map.merge(
        %{
          provider: :github,
          owner: "octocat",
          repository: "hello-world",
          credential_login: "verified-octocat",
          destination: Path.join(tmp_dir, "hello-world.git"),
          default_branch: "main"
        },
        attrs
      )
    )
  end

  defp public_resolver do
    fn
      "github.com", :a -> [{140, 82, 121, 3}]
      "github.com", :aaaa -> [{0x2606, 0x50C0, 0x8000, 0, 0, 0, 0, 0x154}]
    end
  end

  defp local_config(path) do
    git = System.find_executable("git") || flunk("git executable is required")

    {output, 0} =
      System.cmd(git, ["--git-dir=#{path}", "config", "--local", "--name-only", "--list"])

    String.split(output, "\n", trim: true)
  end

  defp symbolic_head(path) do
    git = System.find_executable("git") || flunk("git executable is required")
    {output, 0} = System.cmd(git, ["--git-dir=#{path}", "symbolic-ref", "HEAD"])
    String.trim(output)
  end

  defp private_operation_directory!(root, character) do
    path = Path.join(root, "op-#{String.duplicate(character, 22)}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp refute_tree_contains?(path, secret) do
    path
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.each(fn entry ->
      case File.lstat(entry) do
        {:ok, %File.Stat{type: :regular}} -> refute File.read!(entry) =~ secret
        _other -> :ok
      end
    end)
  end

  defp with_limits(overrides, fun) do
    original = Application.get_env(:git_core, :limits)
    configured = Keyword.merge(original || [], overrides)
    Application.put_env(:git_core, :limits, configured)

    try do
      fun.()
    after
      if original,
        do: Application.put_env(:git_core, :limits, original),
        else: Application.delete_env(:git_core, :limits)
    end
  end

  defp eventually(assertion, attempts \\ 200)

  defp eventually(assertion, attempts) when attempts > 0 do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Elixir.Process.sleep(20)
      eventually(assertion, attempts - 1)
  end

  defp eventually(assertion, 0), do: assertion.()

  defp await_atomic(counter, target, deadline) do
    cond do
      :atomics.get(counter, 1) >= target ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "concurrent remote operations did not reach the resolver barrier"

      true ->
        Elixir.Process.sleep(5)
        await_atomic(counter, target, deadline)
    end
  end

  defp traced_spawn_from(owner, module, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    traced_spawn_from(owner, module, deadline, timeout, [])
  end

  defp traced_spawn_from(owner, module, deadline, timeout, seen) do
    receive do
      {:trace, ^owner, :spawn, worker, mfa} ->
        if spawned_by_module?(mfa, module) do
          worker
        else
          remaining = max(deadline - System.monotonic_time(:millisecond), 0)
          traced_spawn_from(owner, module, deadline, remaining, [mfa | seen])
        end
    after
      timeout ->
        flunk("expected #{inspect(module)} worker spawn; saw #{inspect(Enum.reverse(seen))}")
    end
  end

  defp spawned_by_module?({module, _function, _arity}, module), do: true

  defp spawned_by_module?({:erlang, :apply, [fun, []]}, module) when is_function(fun) do
    :erlang.fun_info(fun, :module) == {:module, module}
  end

  defp spawned_by_module?(_mfa, _module), do: false

  defp os_process_alive?(pid) do
    kill = System.find_executable("kill") || flunk("kill executable is required")

    case System.cmd(kill, ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
