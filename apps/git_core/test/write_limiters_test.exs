defmodule GitCore.RepositoryWriteLimiterTest do
  use ExUnit.Case, async: false

  alias GitCore.RepositoryWriteLimiter
  @production_registry_key {RepositoryWriteLimiter, :production_grants}
  @production_registry_lock {RepositoryWriteLimiter, :production_registry_lock}

  test "two repository keys run concurrently while a third waits" do
    assert {:ok, first} = RepositoryWriteLimiter.acquire(:first, deadline())
    assert {:ok, second} = RepositoryWriteLimiter.acquire(:second, deadline())

    waiter = start_waiter(:third)
    refute_receive {:acquired, ^waiter, _lease}, 30

    assert :ok = RepositoryWriteLimiter.release(first)
    assert_receive {:acquired, ^waiter, third}, 500

    assert :ok = RepositoryWriteLimiter.release(second)
    send(waiter, {:release, third})
    assert_receive {:released, ^waiter}
  end

  test "a repository key stays exclusive even when a node slot is available" do
    assert {:ok, lease} = RepositoryWriteLimiter.acquire(:same, deadline())
    waiter = start_waiter(:same)
    refute_receive {:acquired, ^waiter, _lease}, 30

    assert :ok = RepositoryWriteLimiter.release(lease)
    assert_receive {:acquired, ^waiter, waiter_lease}, 500
    send(waiter, {:release, waiter_lease})
    assert_receive {:released, ^waiter}
  end

  test "waiters resume in FIFO order" do
    assert {:ok, holder} = RepositoryWriteLimiter.acquire(:same, deadline())
    first = start_waiter(:same)
    wait_for_waiters(1)
    second = start_waiter(:same)
    wait_for_waiters(2)

    assert :ok = RepositoryWriteLimiter.release(holder)
    assert_receive {:acquired, ^first, first_lease}, 500
    refute_receive {:acquired, ^second, _lease}, 30

    send(first, {:release, first_lease})
    assert_receive {:released, ^first}
    assert_receive {:acquired, ^second, second_lease}, 500
    send(second, {:release, second_lease})
    assert_receive {:released, ^second}
  end

  test "owner death releases repository and node permits" do
    owner = start_waiter(:dead_owner)
    assert_receive {:acquired, ^owner, _lease}, 500
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert {:ok, replacement} = RepositoryWriteLimiter.acquire(:dead_owner, deadline())
    assert :ok = RepositoryWriteLimiter.release(replacement)
  end

  test "an expired absolute deadline times out and removes the waiter" do
    assert {:ok, holder} = RepositoryWriteLimiter.acquire(:deadline, deadline())

    assert {:error, :timeout} =
             RepositoryWriteLimiter.acquire(:deadline, System.monotonic_time(:millisecond) + 20)

    assert map_size(:sys.get_state(RepositoryWriteLimiter).waiters) == 0
    assert :ok = RepositoryWriteLimiter.release(holder)
  end

  test "release is idempotent" do
    assert {:ok, lease} = RepositoryWriteLimiter.acquire(:idempotent, deadline())
    assert :ok = RepositoryWriteLimiter.release(lease)
    assert :ok = RepositoryWriteLimiter.release(lease)
    assert {:ok, replacement} = RepositoryWriteLimiter.acquire(:idempotent, deadline())
    assert :ok = RepositoryWriteLimiter.release(replacement)
  end

  test "a huge future deadline stays queued without crashing the limiter" do
    limiter = Process.whereis(RepositoryWriteLimiter)
    monitor = Process.monitor(limiter)
    assert {:ok, holder} = RepositoryWriteLimiter.acquire(:huge_deadline, deadline())

    huge_deadline = System.monotonic_time(:millisecond) + Bitwise.bsl(1, 70)
    waiter = start_waiter(:huge_deadline, huge_deadline)
    wait_for_waiters(1)
    refute_receive {:DOWN, ^monitor, :process, ^limiter, _reason}, 30

    [waiter_id] = Map.keys(:sys.get_state(RepositoryWriteLimiter).waiters)
    send(RepositoryWriteLimiter, {:deadline, waiter_id})
    Process.sleep(10)
    assert map_size(:sys.get_state(RepositoryWriteLimiter).waiters) == 1
    refute_receive {:acquire_error, ^waiter, {:error, :timeout}}, 10

    assert :ok = RepositoryWriteLimiter.release(holder)
    assert_receive {:acquired, ^waiter, waiter_lease}, 500
    send(waiter, {:release, waiter_lease})
    assert_receive {:released, ^waiter}
  end

  test "application restart recovers live grants and stale leases release them" do
    {holder, _lease} = start_holder(:surviving_owner)
    crash_and_restart_limiter()
    assert Process.alive?(holder)
    assert_grant_count(1)

    assert {:error, :timeout} =
             RepositoryWriteLimiter.acquire(:surviving_owner, short_deadline())

    assert {:ok, other} = RepositoryWriteLimiter.acquire(:other_repository, deadline())

    assert {:error, :timeout} =
             RepositoryWriteLimiter.acquire(:third_repository, short_deadline())

    assert :ok = RepositoryWriteLimiter.release(other)

    release_holder(holder)
    assert_grant_count(0)
    restart_git_core()
    assert_grant_count(0)

    assert {:ok, replacement} = RepositoryWriteLimiter.acquire(:surviving_owner, deadline())
    assert :ok = RepositoryWriteLimiter.release(replacement)
  end

  test "a recovered grant is removed when its owner dies" do
    {holder, _lease} = start_holder(:owner_death_after_restart)
    crash_and_restart_limiter()
    assert_grant_count(1)

    monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}
    wait_for_grant_count(0)

    assert {:ok, replacement} =
             RepositoryWriteLimiter.acquire(:owner_death_after_restart, deadline())

    assert :ok = RepositoryWriteLimiter.release(replacement)
  end

  test "live grants survive repeated application restarts" do
    {holder, _lease} = start_holder(:repeated_restart)
    crash_and_restart_limiter()
    assert_grant_count(1)

    assert :ok = Application.stop(:git_core)
    assert {:ok, _started} = Application.ensure_all_started(:git_core)
    assert_grant_count(1)

    assert {:error, :timeout} =
             RepositoryWriteLimiter.acquire(:repeated_restart, short_deadline())

    release_holder(holder)
    assert {:ok, replacement} = RepositoryWriteLimiter.acquire(:repeated_restart, deadline())
    assert :ok = RepositoryWriteLimiter.release(replacement)
  end

  test "isolated limiters do not load the production grant registry" do
    assert {:ok, lease} = RepositoryWriteLimiter.acquire(:production_only, deadline())
    isolated = start_supervised!({RepositoryWriteLimiter, server: nil}, id: make_ref())
    assert :sys.get_state(isolated).grants == %{}
    assert :ok = RepositoryWriteLimiter.release(lease)
  end

  test "production init discards dead-owner and malformed registry entries" do
    dead_owner = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(dead_owner)
    Process.exit(dead_owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^dead_owner, :killed}

    assert :ok = Application.stop(:git_core)

    :persistent_term.put(@production_registry_key, %{
      make_ref() => %{owner: dead_owner, repository_key: :stale_repository},
      :malformed => :entry
    })

    assert {:ok, _started} = Application.ensure_all_started(:git_core)
    assert_grant_count(0)
    assert :persistent_term.get(@production_registry_key) == %{}

    assert {:ok, lease} = RepositoryWriteLimiter.acquire(:stale_repository, deadline())
    assert :ok = RepositoryWriteLimiter.release(lease)
  end

  test "a production crash is unavailable until application restart" do
    {holder, _lease} = start_holder(:unavailable_during_crash)
    limiter = Process.whereis(RepositoryWriteLimiter)
    monitor = Process.monitor(limiter)
    Process.exit(limiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^limiter, :killed}

    assert Process.alive?(holder)
    assert {:error, :unavailable} = RepositoryWriteLimiter.acquire(:other_repository, deadline())

    restart_git_core()
    release_holder(holder)
  end

  test "release during absence prevents grant recovery and stays idempotent" do
    {holder, lease} = start_holder(:released_during_absence)
    crash_limiter()

    assert :ok = RepositoryWriteLimiter.release(lease)
    assert :ok = RepositoryWriteLimiter.release(lease)

    restart_git_core()
    assert Process.alive?(holder)
    assert_grant_count(0)

    assert {:ok, replacement} =
             RepositoryWriteLimiter.acquire(:released_during_absence, deadline())

    assert :ok = RepositoryWriteLimiter.release(replacement)
    Process.exit(holder, :kill)
  end

  test "concurrent releases during absence remove every exact lease" do
    {first_holder, first_lease} = start_holder(:concurrent_release_one)
    {second_holder, second_lease} = start_holder(:concurrent_release_two)
    crash_limiter()

    releases =
      for lease <- [first_lease, second_lease] do
        Task.async(fn -> RepositoryWriteLimiter.release(lease) end)
      end

    assert Enum.map(releases, &Task.await/1) == [:ok, :ok]
    restart_git_core()
    assert_grant_count(0)

    assert {:ok, first} = RepositoryWriteLimiter.acquire(:concurrent_release_one, deadline())
    assert {:ok, second} = RepositoryWriteLimiter.acquire(:concurrent_release_two, deadline())
    assert :ok = RepositoryWriteLimiter.release(first)
    assert :ok = RepositoryWriteLimiter.release(second)
    Process.exit(first_holder, :kill)
    Process.exit(second_holder, :kill)
  end

  test "release racing production init removes persistent and recovered state" do
    {holder, lease} = start_holder(:release_restart_race)
    crash_limiter()

    lock = {@production_registry_lock, self()}
    assert :global.set_lock(lock)

    release = Task.async(fn -> RepositoryWriteLimiter.release(lease) end)
    assert Task.yield(release, 20) == nil

    parent = self()

    restart =
      Task.async(fn ->
        :ok = Application.stop(:git_core)
        send(parent, :git_core_stopped_for_race)
        Application.ensure_all_started(:git_core)
      end)

    assert_receive :git_core_stopped_for_race
    :global.del_lock(lock)

    assert Task.await(release) == :ok
    assert {:ok, _started} = Task.await(restart)
    assert_grant_count(0)
    assert :persistent_term.get(@production_registry_key) == %{}

    assert {:ok, replacement} = RepositoryWriteLimiter.acquire(:release_restart_race, deadline())
    assert :ok = RepositoryWriteLimiter.release(replacement)
    Process.exit(holder, :kill)
  end

  test "production and isolated child specs are temporary" do
    assert RepositoryWriteLimiter.child_spec([]).restart == :temporary
    assert RepositoryWriteLimiter.child_spec(server: nil).restart == :temporary
  end

  defp start_holder(key) do
    parent = self()

    holder =
      spawn(fn ->
        {:ok, lease} = RepositoryWriteLimiter.acquire(key, deadline())
        send(parent, {:holder_acquired, self(), lease})

        receive do
          :release ->
            :ok = RepositoryWriteLimiter.release(lease)
            send(parent, {:holder_released, self()})
        end
      end)

    assert_receive {:holder_acquired, ^holder, lease}
    {holder, lease}
  end

  defp release_holder(holder) do
    send(holder, :release)
    assert_receive {:holder_released, ^holder}
  end

  defp crash_and_restart_limiter do
    crash_limiter()
    assert {:error, :unavailable} = RepositoryWriteLimiter.acquire(:during_crash, deadline())
    restart_git_core()
  end

  defp crash_limiter do
    limiter = Process.whereis(RepositoryWriteLimiter)
    monitor = Process.monitor(limiter)
    Process.exit(limiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^limiter, :killed}
  end

  defp restart_git_core do
    assert :ok = Application.stop(:git_core)
    assert {:ok, _started} = Application.ensure_all_started(:git_core)
    assert is_pid(Process.whereis(RepositoryWriteLimiter))
  end

  defp assert_grant_count(expected) do
    assert map_size(:sys.get_state(RepositoryWriteLimiter).grants) == expected
  end

  defp wait_for_grant_count(expected, attempts \\ 100)

  defp wait_for_grant_count(expected, attempts) when attempts > 0 do
    if map_size(:sys.get_state(RepositoryWriteLimiter).grants) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_grant_count(expected, attempts - 1)
    end
  end

  defp wait_for_grant_count(expected, 0) do
    flunk("repository writer limiter did not reach #{expected} grants")
  end

  defp short_deadline do
    System.monotonic_time(:millisecond) + 20
  end

  defp start_waiter(key, absolute_deadline \\ nil) do
    parent = self()

    spawn(fn ->
      case RepositoryWriteLimiter.acquire(key, absolute_deadline || deadline()) do
        {:ok, lease} ->
          send(parent, {:acquired, self(), lease})

          receive do
            {:release, ^lease} ->
              :ok = RepositoryWriteLimiter.release(lease)
              send(parent, {:released, self()})
          end

        error ->
          send(parent, {:acquire_error, self(), error})
      end
    end)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 2_000

  defp wait_for_waiters(expected, attempts \\ 100)

  defp wait_for_waiters(expected, attempts) when attempts > 0 do
    if map_size(:sys.get_state(RepositoryWriteLimiter).waiters) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_waiters(expected, attempts - 1)
    end
  end

  defp wait_for_waiters(expected, 0) do
    flunk("repository writer limiter did not reach #{expected} waiters")
  end
end
