defmodule FornacastAPI.ContentsAdmissionTest do
  use ExUnit.Case, async: false

  test "weighted FIFO waiters cannot be overtaken, and timed out requests release capacity" do
    {:ok, full} = GitCore.BodyMemoryLimiter.acquire(536_870_912)
    parent = self()

    first =
      spawn(fn ->
        send(parent, :first_waiting)
        result = GitCore.BodyMemoryLimiter.acquire(536_870_912)
        send(parent, {:first_result, result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :first_waiting
    # Synchronize on actual queue state without timing assumptions.
    wait_for_waiters(1)

    second =
      spawn(fn ->
        send(parent, {:second_result, GitCore.BodyMemoryLimiter.acquire(1)})

        receive do
          :stop -> :ok
        end
      end)

    wait_for_waiters(2)
    :ok = GitCore.BodyMemoryLimiter.release(full)
    assert_receive {:first_result, {:ok, first_lease}}
    refute_receive {:second_result, {:ok, _}}, 20
    :ok = GitCore.BodyMemoryLimiter.release(first_lease)
    assert_receive {:second_result, {:ok, second_lease}}
    :ok = GitCore.BodyMemoryLimiter.release(second_lease)
    send(first, :stop)
    send(second, :stop)
    assert {:error, :too_large} = GitCore.BodyMemoryLimiter.acquire(536_870_913)
    {:ok, full} = GitCore.BodyMemoryLimiter.acquire(536_870_912)
    assert {:error, :busy} = GitCore.BodyMemoryLimiter.acquire(1, 10)
    :ok = GitCore.BodyMemoryLimiter.release(full)
    assert {:ok, full} = GitCore.BodyMemoryLimiter.acquire(536_870_912)
    :ok = GitCore.BodyMemoryLimiter.release(full)
  end

  defp wait_for_waiters(expected, remaining \\ 100)
  defp wait_for_waiters(_, 0), do: flunk("body waiters were not queued")

  defp wait_for_waiters(expected, remaining) do
    if :queue.len(:sys.get_state(GitCore.BodyMemoryLimiter).queue) == expected do
      :ok
    else
      Process.sleep(1)
      wait_for_waiters(expected, remaining - 1)
    end
  end

  test "maximum requests reserve encoded and decoded memory and owner exit releases it" do
    maximum = 251_658_240
    assert FornacastAPI.ContentsAdmission.reservation_bytes("PUT", nil) == maximum
    assert FornacastAPI.ContentsAdmission.reservation_bytes("DELETE", nil) == 146_800_640
    assert FornacastAPI.ContentsAdmission.reservation_bytes("PUT", 100) == 175
    assert {:ok, first} = GitCore.BodyMemoryLimiter.acquire(maximum)
    assert {:ok, second} = GitCore.BodyMemoryLimiter.acquire(maximum)
    assert {:error, _} = GitCore.BodyMemoryLimiter.acquire(maximum)
    assert :ok = GitCore.BodyMemoryLimiter.release(first)
    assert :ok = GitCore.BodyMemoryLimiter.release(first)
    assert :ok = GitCore.BodyMemoryLimiter.release(second)

    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, lease} = GitCore.BodyMemoryLimiter.acquire(maximum)
        send(parent, {:reserved, lease})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:reserved, _}
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert {:ok, lease} = GitCore.BodyMemoryLimiter.acquire(536_870_912)
    assert :ok = GitCore.BodyMemoryLimiter.release(lease)
  end
end
