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
        send(parent, {:native_entered, :first})

        receive do
          :release -> {:ok, [{"refs/heads/main", "ok", nil}]}
        end
      end)

    assert_receive {:native_entered, :first}

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :second})
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_waiters(1)
    refute_receive {:native_entered, :second}
    send(first.pid, :release)
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
        send(parent, {:native_entered, :long})

        receive do
          :release -> {:ok, [{"refs/heads/main", "ok", nil}]}
        end
      end)

    assert_receive {:native_entered, :long}
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

    send(first.pid, :release)
    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(first)

    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} =
             response_task(repository, fn _path, _pack, _commands ->
               {:ok, [{"refs/heads/main", "ok", nil}]}
             end)
             |> Task.await()
  end

  @tag :tmp_dir
  test "releases the writer lease after native errors and raises", %{repository: repository} do
    assert {:ok, _response, [{"refs/heads/main", "ng", "Git receive-pack failed"}]} =
             ReceivePack.with_test_native(
               fn _path, _pack, _commands -> {:error, :native_failed} end,
               fn -> ReceivePack.response(repository, request(), "PACK") end
             )

    assert_raise RuntimeError, "native crashed", fn ->
      ReceivePack.with_test_native(
        fn _path, _pack, _commands -> raise "native crashed" end,
        fn -> ReceivePack.response(repository, request(), "PACK") end
      )
    end

    assert {:ok, lease} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :ok = GitCore.RepositoryWriteLimiter.release(lease)
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
          Regex.match?(~r/GitCore\.receive_pack\s*\(/, source),
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

  defp restore_env(application, key, {:ok, value}),
    do: Application.put_env(application, key, value)

  defp restore_env(application, key, :error), do: Application.delete_env(application, key)
end
