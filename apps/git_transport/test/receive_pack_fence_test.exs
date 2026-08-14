defmodule GitTransport.ReceivePackFenceTest.Reconciler do
  @behaviour ForgeRepos.RepositoryWriteReconcilers

  @impl true
  def reconcile_repository_locked(_repository, path, _deadline) do
    send(self(), {:reconciled, path})
    :ok
  end
end

defmodule GitTransport.ReceivePackFenceTest.BlockedRecovery do
  @behaviour ForgeRepos.RepositoryWriteReconcilers

  @impl true
  def reconcile_repository_locked(_repository, _path, _deadline),
    do: {:error, :unavailable}
end

defmodule GitTransport.ReceivePackFenceTest do
  use ExUnit.Case, async: false

  alias ForgeRepos.Repository
  alias GitTransport.ReceivePack

  @zero_oid String.duplicate("0", 40)
  @one_oid String.duplicate("1", 40)

  setup %{tmp_dir: tmp_dir} do
    wait_for_persisted_workers(0)

    original_root = Application.fetch_env(:fornacast, :repo_storage_root)
    original_reconcilers = Application.fetch_env(:forge_repos, :repository_write_reconcilers)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {10, :receive_pack_test, __MODULE__.Reconciler}
    ])

    on_exit(fn ->
      restore_env(:fornacast, :repo_storage_root, original_root)
      restore_env(:forge_repos, :repository_write_reconcilers, original_reconcilers)
    end)

    repository = %Repository{
      id: System.unique_integer([:positive]),
      storage_path: "test/demo.git"
    }

    {:ok, repository: repository}
  end

  @tag :tmp_dir
  test "reconciles before native mutation and uses the fence-resolved path once", %{
    repository: repository
  } do
    expected_path = ForgeRepos.absolute_storage_path(repository)
    parent = self()

    native = fn path, pack, commands ->
      assert_receive {:reconciled, ^path}
      send(parent, {:native, path, pack, commands})
      {:ok, [{"refs/heads/main", "ok", nil}]}
    end

    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} =
             ReceivePack.with_test_native(native, fn ->
               ReceivePack.response(repository, request(), "PACK")
             end)

    assert_receive {:native, ^expected_path, "PACK", [{@zero_oid, @one_oid, "refs/heads/main"}]}

    refute_receive {:native, _, _, _}
  end

  @tag :tmp_dir
  test "serializes native mutations for the same repository", %{repository: repository} do
    parent = self()

    first =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :first, self()})

        receive do
          :release -> {:ok, [{"refs/heads/main", "ok", nil}]}
        end
      end)

    assert_receive {:native_entered, :first, first_worker}
    on_exit(fn -> send(first_worker, :release) end)

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :second})
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_waiters(1)
    refute_receive {:native_entered, :second}
    send(first_worker, :release)
    assert_receive {:native_entered, :second}

    assert {:ok, _response, _statuses} = Task.await(first)
    assert {:ok, _response, _statuses} = Task.await(second)
  end

  @tag :tmp_dir
  test "mutates two repositories concurrently while a third waits for node capacity", %{
    repository: repository
  } do
    parent = self()

    repositories =
      for suffix <- 1..3 do
        %Repository{
          id: repository.id + suffix,
          storage_path: "test/demo-#{suffix}.git"
        }
      end

    native = fn _path, pack, _commands ->
      send(parent, {:native_entered, pack, self()})

      receive do
        :release -> {:ok, [{"refs/heads/main", "ok", nil}]}
      end
    end

    [first_repo, second_repo, third_repo] = repositories
    first = response_task(first_repo, native, "FIRST")
    second = response_task(second_repo, native, "SECOND")
    assert_receive {:native_entered, "FIRST", first_pid}
    assert_receive {:native_entered, "SECOND", second_pid}

    third = response_task(third_repo, native, "THIRD")
    wait_for_waiters(1)
    refute_receive {:native_entered, "THIRD", _pid}

    send(first_pid, :release)
    assert_receive {:native_entered, "THIRD", third_pid}
    send(second_pid, :release)
    send(third_pid, :release)

    for task <- [first, second, third] do
      assert {:ok, _response, _statuses} = Task.await(task)
    end
  end

  @tag :tmp_dir
  test "blocked recovery renders protocol ng statuses without invoking native mutation", %{
    repository: repository
  } do
    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {10, :blocked_recovery, __MODULE__.BlockedRecovery}
    ])

    native = fn _path, _pack, _commands ->
      send(self(), :native_invoked)
      {:ok, []}
    end

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             ReceivePack.with_test_native(native, fn ->
               ReceivePack.response(repository, request(), "SECRET PACK")
             end)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"
    refute response =~ "blocked_recovery"
    refute response =~ "SECRET PACK"
    refute_receive :native_invoked
  end

  @tag :tmp_dir
  test "keeps the writer lease after the deadline until a long native mutation returns", %{
    repository: repository
  } do
    original_limits = Application.fetch_env(:git_core, :limits)

    limits =
      Application.get_env(:git_core, :limits, [])
      |> Keyword.put(:content_deadline_ms, 25)

    Application.put_env(:git_core, :limits, limits)
    on_exit(fn -> restore_env(:git_core, :limits, original_limits) end)
    parent = self()

    first =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :long, self()})

        receive do
          :release -> {:ok, [{"refs/heads/main", "ok", nil}]}
        end
      end)

    assert_receive {:native_entered, :long, first_worker}
    on_exit(fn -> send(first_worker, :release) end)
    Process.sleep(30)

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :timed_out_waiter})
        {:ok, []}
      end)

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             Task.await(second)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"
    refute_receive {:native_entered, :timed_out_waiter}
    assert Task.yield(first, 0) == nil

    send(first_worker, :release)
    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(first)

    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} =
             response_task(repository, fn _path, _pack, _commands ->
               {:ok, [{"refs/heads/main", "ok", nil}]}
             end)
             |> Task.await()
  end

  @tag :tmp_dir
  test "caller death cannot release a repository while its dirty NIF is still running", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "dirty-nif-entered")
    release_path = Path.join(tmp_dir, "dirty-nif-release")
    on_exit(fn -> File.write(release_path, "release") end)
    parent = self()

    dirty_native = fn _path, _pack, _commands ->
      {:ok, {}} = GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)
      {:ok, [{"refs/heads/main", "ok", nil}]}
    end

    caller =
      spawn(fn ->
        result =
          ReceivePack.with_test_native(dirty_native, fn ->
            ReceivePack.response(repository, request(), "PACK")
          end)

        send(parent, {:first_response, result})
      end)

    caller_monitor = Process.monitor(caller)
    wait_for_file(entered_path)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 500

    other_repository = %Repository{
      id: repository.id + 1,
      storage_path: "test/other.git"
    }

    assert {:ok, _response, _statuses} =
             response_task(other_repository, fn _path, _pack, _commands ->
               send(parent, :other_repository_entered)
               {:ok, [{"refs/heads/main", "ok", nil}]}
             end)
             |> Task.await()

    assert_receive :other_repository_entered

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, :second_native_entered)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_waiters(1)
    refute_receive :second_native_entered
    File.write!(release_path, "release")
    assert_receive :second_native_entered
    assert {:ok, _response, _statuses} = Task.await(second)
    refute_receive {:first_response, _result}
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "dirty NIF worker and fence survive worker supervisor crash and restart", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "supervisor-crash-dirty-nif-entered")
    release_path = Path.join(tmp_dir, "supervisor-crash-dirty-nif-release")
    on_exit(fn -> File.write(release_path, "release") end)
    parent = self()

    first =
      response_task(repository, fn _path, _pack, _commands ->
        {:ok, {}} = GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_file(entered_path)
    original_manager = Process.whereis(GitTransport.ReceivePackWorkerManager)
    manager_monitor = Process.monitor(original_manager)
    Process.exit(original_manager, :kill)
    assert_receive {:DOWN, ^manager_monitor, :process, ^original_manager, :killed}
    wait_for_worker_manager_restart(original_manager)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 1
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 1

    original_supervisor = Process.whereis(GitTransport.ReceivePackWorkerSupervisor)
    supervisor_monitor = Process.monitor(original_supervisor)
    Process.exit(original_supervisor, :kill)
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^original_supervisor, :killed}
    wait_for_worker_supervisor_restart(original_supervisor)
    assert Task.yield(first, 0) == nil
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 1

    restarted_supervisor = Process.whereis(GitTransport.ReceivePackWorkerSupervisor)
    restarted_monitor = Process.monitor(restarted_supervisor)
    Process.exit(restarted_supervisor, :kill)

    assert_receive {:DOWN, ^restarted_monitor, :process, ^restarted_supervisor, :killed}
    wait_for_worker_supervisor_restart(restarted_supervisor)
    assert Task.yield(first, 0) == nil
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 1

    other_repository = %Repository{
      id: repository.id + 1,
      storage_path: "test/supervisor-crash-other.git"
    }

    assert {:ok, _response, _statuses} =
             response_task(other_repository, fn _path, _pack, _commands ->
               send(parent, :supervisor_crash_other_entered)
               {:ok, [{"refs/heads/main", "ok", nil}]}
             end)
             |> Task.await()

    assert_receive :supervisor_crash_other_entered

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, :supervisor_crash_same_entered)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_waiters(1)
    refute_receive :supervisor_crash_same_entered
    File.write!(release_path, "release")
    assert {:ok, _response, _statuses} = Task.await(first)
    assert_receive :supervisor_crash_same_entered
    assert {:ok, _response, _statuses} = Task.await(second)
    wait_for_workers(0)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 0
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 0
  end

  @tag :tmp_dir
  test "native errors and raises render ng and release the writer lease", %{
    repository: repository
  } do
    assert {:ok, _response, [{"refs/heads/main", "ng", "Git receive-pack failed"}]} =
             ReceivePack.with_test_native(
               fn _path, _pack, _commands -> {:error, :native_failed} end,
               fn -> ReceivePack.response(repository, request(), "PACK") end
             )

    assert {:ok, _response, [{"refs/heads/main", "ng", "Git receive-pack failed"}]} =
             ReceivePack.with_test_native(
               fn _path, _pack, _commands -> raise "native crashed" end,
               fn -> ReceivePack.response(repository, request(), "PACK") end
             )

    assert {:ok, lease} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :ok = GitCore.RepositoryWriteLimiter.release(lease)
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "worker crashes before a result render ng and release the writer lease", %{
    repository: repository
  } do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
                 ReceivePack.with_test_native(
                   fn _path, _pack, _commands -> exit(:simulated_worker_crash) end,
                   fn -> ReceivePack.response(repository, request(), "PACK") end
                 )

        assert response =~ "ng refs/heads/main Git receive-pack unavailable"
      end)

    refute log =~ "PACK"

    assert {:ok, lease} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :ok = GitCore.RepositoryWriteLimiter.release(lease)
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "worker replies are correlated and completed workers leave no mailbox or child residue", %{
    repository: repository
  } do
    decoy = make_ref()
    send(self(), {decoy, :keep})

    assert {:ok, _response, _statuses} =
             ReceivePack.with_test_native(
               fn _path, _pack, _commands ->
                 {:ok, [{"refs/heads/main", "ok", nil}]}
               end,
               fn -> ReceivePack.response(repository, request(), "PACK") end
             )

    assert_receive {^decoy, :keep}
    wait_for_workers(0)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  @tag :tmp_dir
  test "repeated worker start and supervisor crash races leave no monitor or mailbox residue", %{
    repository: repository
  } do
    decoy = make_ref()
    send(self(), {decoy, :keep})

    for _iteration <- 1..3 do
      supervisor = Process.whereis(GitTransport.ReceivePackWorkerSupervisor)
      monitor = Process.monitor(supervisor)

      response =
        response_task(repository, fn _path, _pack, _commands ->
          {:ok, [{"refs/heads/main", "ok", nil}]}
        end)

      Process.exit(supervisor, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, :killed}
      wait_for_worker_supervisor_restart(supervisor)

      assert {:ok, _response, [{"refs/heads/main", status, _message}]} = Task.await(response)
      assert status in ["ok", "ng"]
      wait_for_tracked_workers(0)
      wait_for_workers(0)
    end

    assert_receive {^decoy, :keep}
    assert {:messages, []} = Process.info(self(), :messages)
  end

  @tag :tmp_dir
  test "worker completion during manager downtime removes its persistent registry entry", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "manager-downtime-dirty-nif-entered")
    release_path = Path.join(tmp_dir, "manager-downtime-dirty-nif-release")
    root_supervisor = Process.whereis(GitTransport.Supervisor)

    on_exit(fn ->
      File.write(release_path, "release")
      safe_resume(root_supervisor)
      Application.ensure_all_started(:git_transport)
    end)

    response =
      response_task(repository, fn _path, _pack, _commands ->
        {:ok, {}} = GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_file(entered_path)
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 1
    :ok = :sys.suspend(root_supervisor)
    manager = Process.whereis(GitTransport.ReceivePackWorkerManager)
    monitor = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^manager, :killed}
    assert Process.whereis(GitTransport.ReceivePackWorkerManager) == nil

    File.write!(release_path, "release")
    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(response)
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 0

    :ok = :sys.resume(root_supervisor)
    wait_for_worker_manager_restart(manager)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 0
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 0
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "manager crashes at readiness and activation boundaries never leak or mutate invisibly", %{
    repository: repository
  } do
    on_exit(fn -> GitTransport.ReceivePackWorkerManager.set_test_fault(nil) end)
    parent = self()

    for phase <- [
          :after_ready,
          :after_persist,
          :after_active_persist,
          :after_reply,
          :after_go
        ] do
      manager = Process.whereis(GitTransport.ReceivePackWorkerManager)
      monitor = Process.monitor(manager)
      :ok = GitTransport.ReceivePackWorkerManager.set_test_fault(phase)

      response =
        response_task(repository, fn _path, _pack, _commands ->
          send(parent, {:boundary_native_entered, phase})
          {:ok, [{"refs/heads/main", "ok", nil}]}
        end)

      assert_receive {:DOWN, ^monitor, :process, ^manager, :killed}
      :ok = GitTransport.ReceivePackWorkerManager.set_test_fault(nil)
      wait_for_worker_manager_restart(manager)

      assert {:ok, _response, [{"refs/heads/main", status, _message}]} = Task.await(response)

      if phase == :after_go do
        assert status == "ok"
        assert_receive {:boundary_native_entered, :after_go}
      else
        assert status == "ng"
        refute_receive {:boundary_native_entered, ^phase}
      end

      wait_for_tracked_workers(0)
      wait_for_persisted_workers(0)
      wait_for_workers(0)
    end

    assert {:messages, []} = Process.info(self(), :messages)
  end

  @tag :tmp_dir
  test "receive-pack worker supervision waits indefinitely and precedes SSH admission" do
    [worker_spec, manager_spec | daemon_specs] = GitTransport.Application.child_specs()
    assert worker_spec.id == GitTransport.ReceivePackWorkerSupervisor
    assert worker_spec.shutdown == :infinity
    assert manager_spec.id == GitTransport.ReceivePackWorkerManager
    assert manager_spec.shutdown == :infinity

    assert Enum.all?(daemon_specs, fn spec ->
             Supervisor.child_spec(spec, []).id == GitTransport.Daemon
           end)
  end

  @tag :tmp_dir
  test "application shutdown waits for an admitted dirty NIF without reopening the lease", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "shutdown-dirty-nif-entered")
    release_path = Path.join(tmp_dir, "shutdown-dirty-nif-release")

    on_exit(fn ->
      File.write(release_path, "release")
      Application.ensure_all_started(:git_transport)
    end)

    response =
      response_task(repository, fn _path, _pack, _commands ->
        {:ok, {}} = GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_file(entered_path)
    stopper = Task.async(fn -> Application.stop(:git_transport) end)
    assert Task.yield(stopper, 30) == nil

    assert {:error, :timeout} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 25
             )

    File.write!(release_path, "release")
    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(response)
    assert :ok = Task.await(stopper)
    assert {:ok, _started} = Application.ensure_all_started(:git_transport)
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "application shutdown waits for a dirty NIF orphaned by supervisor restart", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "orphan-shutdown-dirty-nif-entered")
    release_path = Path.join(tmp_dir, "orphan-shutdown-dirty-nif-release")

    on_exit(fn ->
      File.write(release_path, "release")
      Application.ensure_all_started(:git_transport)
    end)

    response =
      response_task(repository, fn _path, _pack, _commands ->
        {:ok, {}} = GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_file(entered_path)
    original_manager = Process.whereis(GitTransport.ReceivePackWorkerManager)
    manager_monitor = Process.monitor(original_manager)
    Process.exit(original_manager, :kill)
    assert_receive {:DOWN, ^manager_monitor, :process, ^original_manager, :killed}
    wait_for_worker_manager_restart(original_manager)
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 1

    original_supervisor = Process.whereis(GitTransport.ReceivePackWorkerSupervisor)
    monitor = Process.monitor(original_supervisor)
    Process.exit(original_supervisor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^original_supervisor, :killed}
    wait_for_worker_supervisor_restart(original_supervisor)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 1

    stopper = Task.async(fn -> Application.stop(:git_transport) end)
    assert Task.yield(stopper, 30) == nil

    assert {:error, :timeout} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 25
             )

    File.write!(release_path, "release")
    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(response)
    assert :ok = Task.await(stopper)
    assert {:ok, _started} = Application.ensure_all_started(:git_transport)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 0
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 0
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "an unavailable writer limiter renders ng without invoking native", %{
    repository: repository
  } do
    parent = self()

    native = fn _path, _pack, _commands ->
      send(parent, :native_invoked)
      {:ok, []}
    end

    try do
      assert :ok = Application.stop(:git_core)

      assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
               ReceivePack.with_test_native(native, fn ->
                 ReceivePack.response(repository, request(), "PACK")
               end)

      assert response =~ "ng refs/heads/main Git receive-pack unavailable"
      refute_receive :native_invoked
    after
      assert {:ok, _started} = Application.ensure_all_started(:git_core)
    end
  end

  @tag :tmp_dir
  test "HTTP and SSH mutation flows share the only native receive-pack callsite" do
    app_libs = Path.expand("../../*/lib/**/*.ex", __DIR__) |> Path.wildcard()

    native_calls =
      for path <- app_libs,
          source = File.read!(path),
          Regex.match?(~r/GitCore\.receive_pack(?:\s*\(|\/3)/, source),
          do: path

    assert native_calls == [Path.expand("../lib/git_transport/receive_pack.ex", __DIR__)]

    ssh_channel = File.read!(Path.expand("../lib/git_transport/channel.ex", __DIR__))

    http_controller =
      File.read!(
        Path.expand(
          "../../fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex",
          __DIR__
        )
      )

    assert ssh_channel =~ "GitTransport.ReceivePack.response(state.repository, request, pack)"
    assert http_controller =~ "GitTransport.ReceivePack.response(repository, request, pack)"
  end

  defp request do
    %{
      commands: [%{old: @zero_oid, new: @one_oid, ref: "refs/heads/main"}],
      capabilities: MapSet.new(["report-status"]),
      phase: :pack
    }
  end

  defp response_task(repository, native, pack \\ "PACK") do
    Task.async(fn ->
      ReceivePack.with_test_native(native, fn ->
        ReceivePack.response(repository, request(), pack)
      end)
    end)
  end

  defp wait_for_waiters(expected, attempts \\ 100)

  defp wait_for_waiters(expected, attempts) when attempts > 0 do
    if map_size(:sys.get_state(GitCore.RepositoryWriteLimiter).waiters) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_waiters(expected, attempts - 1)
    end
  end

  defp wait_for_waiters(expected, 0),
    do: flunk("expected #{expected} repository write waiter(s)")

  defp wait_for_file(path, attempts \\ 200)

  defp wait_for_file(path, attempts) when attempts > 0 do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(5)
      wait_for_file(path, attempts - 1)
    end
  end

  defp wait_for_file(path, 0), do: flunk("expected #{path} to exist")

  defp wait_for_workers(expected, attempts \\ 100)

  defp wait_for_workers(expected, attempts) when attempts > 0 do
    if length(Task.Supervisor.children(GitTransport.ReceivePackWorkerSupervisor)) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_workers(expected, attempts - 1)
    end
  end

  defp wait_for_workers(expected, 0), do: flunk("expected #{expected} receive-pack worker(s)")

  defp wait_for_tracked_workers(expected, attempts \\ 100)

  defp wait_for_tracked_workers(expected, attempts) when attempts > 0 do
    if GitTransport.ReceivePackWorkerManager.tracked_worker_count() == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_tracked_workers(expected, attempts - 1)
    end
  end

  defp wait_for_tracked_workers(expected, 0),
    do: flunk("expected #{expected} manager-tracked receive-pack worker(s)")

  defp wait_for_persisted_workers(expected, attempts \\ 100)

  defp wait_for_persisted_workers(expected, attempts) when attempts > 0 do
    if GitTransport.ReceivePackWorkerManager.persisted_worker_count() == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_persisted_workers(expected, attempts - 1)
    end
  end

  defp wait_for_persisted_workers(expected, 0),
    do: flunk("expected #{expected} persisted receive-pack worker(s)")

  defp wait_for_worker_supervisor_restart(previous, attempts \\ 100)

  defp wait_for_worker_supervisor_restart(previous, attempts) when attempts > 0 do
    case Process.whereis(GitTransport.ReceivePackWorkerSupervisor) do
      pid when is_pid(pid) and pid != previous ->
        :ok

      _other ->
        Process.sleep(5)
        wait_for_worker_supervisor_restart(previous, attempts - 1)
    end
  end

  defp wait_for_worker_supervisor_restart(_previous, 0),
    do: flunk("expected receive-pack worker supervisor to restart")

  defp wait_for_worker_manager_restart(previous, attempts \\ 100)

  defp wait_for_worker_manager_restart(previous, attempts) when attempts > 0 do
    case Process.whereis(GitTransport.ReceivePackWorkerManager) do
      pid when is_pid(pid) and pid != previous ->
        :ok

      _other ->
        Process.sleep(5)
        wait_for_worker_manager_restart(previous, attempts - 1)
    end
  end

  defp wait_for_worker_manager_restart(_previous, 0),
    do: flunk("expected receive-pack worker manager to restart")

  defp safe_resume(supervisor) do
    try do
      :sys.resume(supervisor)
    catch
      :exit, _reason -> :ok
    end
  end

  defp restore_env(application, key, {:ok, value}),
    do: Application.put_env(application, key, value)

  defp restore_env(application, key, :error), do: Application.delete_env(application, key)
end
