defmodule GitCore.Remote.ControlTest do
  use ExUnit.Case, async: false

  alias GitCore.Remote.Control

  setup do
    original = Application.get_env(:git_core, :limits)
    Application.delete_env(:git_core, :limits)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:git_core, :limits),
        else: Application.put_env(:git_core, :limits, original)
    end)
  end

  for {kind, value} <- [cancel?: false, heartbeat: :ok], delay <- [150, 300] do
    test "healthy #{kind} callback may take #{delay}ms beyond the polling interval" do
      callback = fn ->
        Process.sleep(unquote(delay))
        unquote(value)
      end

      assert :ok = Control.check(options([{unquote(kind), callback}]))
    end
  end

  for {kind, expected} <- [cancel?: :cancelled, heartbeat: :heartbeat_failed] do
    test "#{kind} callback budget exhaustion fails closed and terminates the callback" do
      test_pid = self()

      callback = fn ->
        send(test_pid, {:callback_started, self()})

        receive do
        after
          2_000 -> flunk("callback exceeded its bounded budget")
        end
      end

      started_at = System.monotonic_time(:millisecond)

      assert {:error, unquote(expected)} =
               Control.check(options([{unquote(kind), callback}]))

      assert System.monotonic_time(:millisecond) - started_at < 750
      assert_receive {:callback_started, callback_worker}, 2_000
      refute Process.alive?(callback_worker)
    end
  end

  test "a lower configured callback budget remains enforced" do
    Application.put_env(:git_core, :limits, remote_control_callback_ms: 50)
    test_pid = self()

    callback = fn ->
      send(test_pid, {:callback_started, self()})
      Process.sleep(300)
      false
    end

    assert {:error, :cancelled} = Control.check(options(cancel?: callback))
    assert_receive {:callback_started, callback_worker}, 2_000
    refute Process.alive?(callback_worker)
  end

  test "the overall deadline takes precedence over the callback budget" do
    test_pid = self()

    callback = fn ->
      send(test_pid, {:callback_started, self()})
      Process.sleep(2_000)
      false
    end

    assert {:error, :timeout} =
             Control.check(
               options(
                 cancel?: callback,
                 absolute_deadline: System.monotonic_time(:millisecond) + 150
               )
             )

    assert_receive {:callback_started, callback_worker}, 2_000
    refute Process.alive?(callback_worker)
  end

  test "owner death interrupts a running callback and terminates its worker" do
    test_pid = self()
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    {checker, checker_monitor} =
      spawn_monitor(fn ->
        callback = fn ->
          send(test_pid, {:callback_started, self()})
          receive do: (:continue -> false)
        end

        result =
          Control.check(
            options(
              cancel?: callback,
              parent_monitor: Process.monitor(owner),
              owner_exit_pid: owner
            )
          )

        send(test_pid, {:control_result, result})
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      if Process.alive?(checker), do: Process.exit(checker, :kill)
    end)

    assert_receive {:callback_started, callback_worker}, 2_000
    callback_monitor = Process.monitor(callback_worker)
    Process.exit(owner, :kill)

    assert_receive {:control_result, {:error, :owner_down}}, 2_000
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback_worker, _reason}, 2_000
    assert_receive {:DOWN, ^checker_monitor, :process, ^checker, :normal}, 2_000
  end

  defp options(overrides) do
    Keyword.merge(
      [
        cancel?: fn -> false end,
        heartbeat: fn -> :ok end,
        absolute_deadline: System.monotonic_time(:millisecond) + 5_000,
        parent_monitor: Process.monitor(self()),
        owner_exit_pid: self()
      ],
      overrides
    )
  end
end
