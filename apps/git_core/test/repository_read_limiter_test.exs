defmodule GitCore.RepositoryReadLimiterTest do
  use ExUnit.Case, async: false

  alias GitCore.RepositoryReadLimiter

  @production_registry_key {RepositoryReadLimiter, :production_grants}
  @fault_config_key :repository_read_limiter_fault

  setup do
    original_fault = Application.fetch_env(:git_core, @fault_config_key)

    on_exit(fn ->
      restore_fault(original_fault)

      if Process.whereis(RepositoryReadLimiter) == nil do
        Application.stop(:git_core)
        Application.ensure_all_started(:git_core)
      end
    end)
  end

  test "readers share a repository while cleanup remains exclusive" do
    assert {:ok, first} = RepositoryReadLimiter.acquire_read(:same, deadline())
    assert {:ok, second} = RepositoryReadLimiter.acquire_read(:same, deadline())
    cleanup = start_waiter(:cleanup, :same)
    refute_receive {:acquired, ^cleanup, _lease}, 30

    assert :ok = RepositoryReadLimiter.release(first)
    refute_receive {:acquired, ^cleanup, _lease}, 30
    assert :ok = RepositoryReadLimiter.release(second)
    assert_receive {:acquired, ^cleanup, cleanup_lease}, 500

    reader = start_waiter(:read, :same)
    refute_receive {:acquired, ^reader, _lease}, 30
    send(cleanup, {:release, cleanup_lease})
    assert_receive {:released, ^cleanup}
    assert_receive {:acquired, ^reader, reader_lease}, 500
    send(reader, {:release, reader_lease})
    assert_receive {:released, ^reader}
  end

  test "queued cleanup has priority over later readers and readers resume as a batch" do
    assert {:ok, holder} = RepositoryReadLimiter.acquire_read(:same, deadline())
    cleanup = start_waiter(:cleanup, :same)
    wait_for_waiters(1)
    first = start_waiter(:read, :same)
    second = start_waiter(:read, :same)
    wait_for_waiters(3)

    assert :ok = RepositoryReadLimiter.release(holder)
    assert_receive {:acquired, ^cleanup, cleanup_lease}, 500
    refute_receive {:acquired, ^first, _lease}, 30

    send(cleanup, {:release, cleanup_lease})
    assert_receive {:released, ^cleanup}
    assert_receive {:acquired, ^first, first_lease}, 500
    assert_receive {:acquired, ^second, second_lease}, 500
    send(first, {:release, first_lease})
    send(second, {:release, second_lease})
    assert_receive {:released, ^first}
    assert_receive {:released, ^second}
  end

  test "a queued cleanup does not block another repository" do
    assert {:ok, reader} = RepositoryReadLimiter.acquire_read(:first, deadline())
    cleanup = start_waiter(:cleanup, :first)
    wait_for_waiters(1)

    assert {:ok, other_cleanup} = RepositoryReadLimiter.acquire_cleanup(:second, deadline())
    assert :ok = RepositoryReadLimiter.release(other_cleanup)
    assert :ok = RepositoryReadLimiter.release(reader)
    assert_receive {:acquired, ^cleanup, cleanup_lease}, 500
    send(cleanup, {:release, cleanup_lease})
    assert_receive {:released, ^cleanup}
  end

  test "expired acquisition returns deadline_exceeded and removes the waiter" do
    assert {:ok, cleanup} = RepositoryReadLimiter.acquire_cleanup(:deadline, deadline())

    assert {:error, :deadline_exceeded} =
             RepositoryReadLimiter.acquire_read(
               :deadline,
               System.monotonic_time(:millisecond) + 20
             )

    assert map_size(:sys.get_state(RepositoryReadLimiter).waiters) == 0
    assert :ok = RepositoryReadLimiter.release(cleanup)
  end

  test "owner death releases grants and release is idempotent" do
    owner = start_waiter(:cleanup, :owner_death)
    assert_receive {:acquired, ^owner, lease}, 500
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert {:ok, replacement} = RepositoryReadLimiter.acquire_cleanup(:owner_death, deadline())
    assert :ok = RepositoryReadLimiter.release(lease)
    assert :ok = RepositoryReadLimiter.release(replacement)
    assert :ok = RepositoryReadLimiter.release(replacement)
  end

  test "public acquire returns only confirmed production leases" do
    assert {:ok, {{RepositoryReadLimiter, :read_lease}, RepositoryReadLimiter, lease_ref} = lease} =
             RepositoryReadLimiter.acquire_read(:confirmed, deadline())

    assert %{status: :confirmed, type: :read} =
             @production_registry_key |> :persistent_term.get() |> Map.fetch!(lease_ref)

    assert :ok = RepositoryReadLimiter.release(lease)
  end

  test "application restart recovers confirmed live grants and owner monitoring" do
    {holder, _lease} = start_holder(:read, :recover)
    crash_limiter()
    assert {:error, :unavailable} = RepositoryReadLimiter.acquire_cleanup(:recover, deadline())
    restart_git_core()
    assert map_size(:sys.get_state(RepositoryReadLimiter).grants) == 1

    assert {:error, :deadline_exceeded} =
             RepositoryReadLimiter.acquire_cleanup(:recover, short_deadline())

    release_holder(holder)
    assert {:ok, cleanup} = RepositoryReadLimiter.acquire_cleanup(:recover, deadline())
    assert :ok = RepositoryReadLimiter.release(cleanup)
  end

  test "restart discards pending grants after a crash window" do
    set_fault(:after_pending_persist)
    assert {:error, :unavailable} = RepositoryReadLimiter.acquire_read(:pending, deadline())
    assert Process.whereis(RepositoryReadLimiter) == nil

    assert [%{status: :pending}] =
             @production_registry_key |> :persistent_term.get() |> Map.values()

    clear_fault()
    restart_git_core()
    assert :persistent_term.get(@production_registry_key, %{}) == %{}
    assert {:ok, cleanup} = RepositoryReadLimiter.acquire_cleanup(:pending, deadline())
    assert :ok = RepositoryReadLimiter.release(cleanup)
  end

  test "crashes after internal and confirmed persistence never publish a lease" do
    for phase <- [:after_internal_reply, :after_confirmed_persist] do
      set_fault(phase)
      assert {:error, :unavailable} = RepositoryReadLimiter.acquire_read(phase, deadline())
      assert Process.whereis(RepositoryReadLimiter) == nil
      assert :persistent_term.get(@production_registry_key, %{}) == %{}
      clear_fault()
      restart_git_core()
    end
  end

  test "production and isolated child specs are temporary and registries stay separate" do
    assert RepositoryReadLimiter.child_spec([]).restart == :temporary
    assert RepositoryReadLimiter.child_spec(server: nil).restart == :temporary
    assert {:ok, lease} = RepositoryReadLimiter.acquire_read(:production_only, deadline())
    isolated = start_supervised!({RepositoryReadLimiter, server: nil}, id: make_ref())
    assert :sys.get_state(isolated).grants == %{}
    assert :ok = RepositoryReadLimiter.release(lease)
  end

  defp start_holder(type, key) do
    parent = self()

    holder =
      spawn(fn ->
        {:ok, lease} = acquire(type, key, deadline())
        send(parent, {:holder_acquired, self(), lease})

        receive do
          :release ->
            :ok = RepositoryReadLimiter.release(lease)
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

  defp start_waiter(type, key) do
    parent = self()

    spawn(fn ->
      case acquire(type, key, deadline()) do
        {:ok, lease} ->
          send(parent, {:acquired, self(), lease})

          receive do
            {:release, ^lease} ->
              :ok = RepositoryReadLimiter.release(lease)
              send(parent, {:released, self()})
          end

        error ->
          send(parent, {:acquire_error, self(), error})
      end
    end)
  end

  defp acquire(:read, key, deadline), do: RepositoryReadLimiter.acquire_read(key, deadline)
  defp acquire(:cleanup, key, deadline), do: RepositoryReadLimiter.acquire_cleanup(key, deadline)

  defp crash_limiter do
    limiter = Process.whereis(RepositoryReadLimiter)
    monitor = Process.monitor(limiter)
    Process.exit(limiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^limiter, :killed}
  end

  defp restart_git_core do
    assert :ok = Application.stop(:git_core)
    assert {:ok, _started} = Application.ensure_all_started(:git_core)
    assert is_pid(Process.whereis(RepositoryReadLimiter))
  end

  defp wait_for_waiters(expected, attempts \\ 100)

  defp wait_for_waiters(expected, attempts) when attempts > 0 do
    if map_size(:sys.get_state(RepositoryReadLimiter).waiters) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_waiters(expected, attempts - 1)
    end
  end

  defp wait_for_waiters(_expected, 0), do: flunk("read limiter waiter count did not converge")

  defp deadline, do: System.monotonic_time(:millisecond) + 2_000
  defp short_deadline, do: System.monotonic_time(:millisecond) + 20
  defp set_fault(phase), do: Application.put_env(:git_core, @fault_config_key, phase)
  defp clear_fault, do: Application.delete_env(:git_core, @fault_config_key)
  defp restore_fault({:ok, phase}), do: set_fault(phase)
  defp restore_fault(:error), do: clear_fault()
end
