defmodule GitCore.RepositoryWriteLimiterTest do
  use ExUnit.Case, async: false

  alias GitCore.RepositoryWriteLimiter

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

  test "a production crash stays unavailable while existing owners survive" do
    parent = self()

    holder =
      spawn(fn ->
        {:ok, lease} = RepositoryWriteLimiter.acquire(:surviving_owner, deadline())
        send(parent, {:holder_acquired, self(), lease})

        receive do
          :release ->
            :ok = RepositoryWriteLimiter.release(lease)
            send(parent, {:holder_released, self()})
        end
      end)

    assert_receive {:holder_acquired, ^holder, _lease}
    limiter = Process.whereis(RepositoryWriteLimiter)
    monitor = Process.monitor(limiter)
    Process.exit(limiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^limiter, :killed}

    assert Process.alive?(holder)
    assert Process.whereis(RepositoryWriteLimiter) == nil
    assert {:error, :unavailable} = RepositoryWriteLimiter.acquire(:surviving_owner, deadline())
    assert {:error, :unavailable} = RepositoryWriteLimiter.acquire(:other_repository, deadline())

    assert :ok = Application.stop(:git_core)
    assert {:ok, _started} = Application.ensure_all_started(:git_core)
    replacement = Process.whereis(RepositoryWriteLimiter)
    assert is_pid(replacement)
    assert {:ok, lease} = RepositoryWriteLimiter.acquire(:after_operator_restart, deadline())
    assert :ok = RepositoryWriteLimiter.release(lease)

    send(holder, :release)
    assert_receive {:holder_released, ^holder}
  end

  test "production and isolated child specs are temporary to fail closed" do
    assert RepositoryWriteLimiter.child_spec([]).restart == :temporary
    assert RepositoryWriteLimiter.child_spec(server: nil).restart == :temporary
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
