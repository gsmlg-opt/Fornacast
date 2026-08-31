defmodule GitCore.Remote.Control do
  @moduledoc false

  @type error_reason :: :cancelled | :heartbeat_failed | :owner_down | :timeout

  @spec check(keyword()) :: :ok | {:error, error_reason()}
  def check(opts) when is_list(opts) do
    with :ok <- owner_status(opts),
         :ok <- evaluate(:cancel, Keyword.fetch!(opts, :cancel?), opts),
         :ok <- evaluate(:heartbeat, Keyword.fetch!(opts, :heartbeat), opts) do
      :ok
    end
  end

  def check(_opts), do: {:error, :heartbeat_failed}

  defp evaluate(kind, callback, opts) when is_function(callback, 0) do
    case run_callback(callback, opts) do
      {:ok, value} -> classify(kind, value)
      {:error, reason} when reason in [:owner_down, :timeout] -> {:error, reason}
      {:error, :callback_failed} -> callback_failure(kind)
    end
  end

  defp evaluate(kind, _callback, _opts), do: callback_failure(kind)

  defp classify(:cancel, false), do: :ok
  defp classify(:cancel, true), do: {:error, :cancelled}
  defp classify(:cancel, _invalid), do: {:error, :cancelled}
  defp classify(:heartbeat, value) when value in [:ok, true], do: :ok
  defp classify(:heartbeat, _invalid), do: {:error, :heartbeat_failed}

  defp callback_failure(:cancel), do: {:error, :cancelled}
  defp callback_failure(:heartbeat), do: {:error, :heartbeat_failed}

  defp run_callback(callback, opts) do
    now = System.monotonic_time(:millisecond)
    absolute_deadline = Keyword.fetch!(opts, :absolute_deadline)
    remaining = absolute_deadline - now

    if remaining <= 0 do
      {:error, :timeout}
    else
      caller = self()
      reply = make_ref()

      {worker, monitor} =
        :erlang.spawn_opt(
          fn -> callback_worker(caller, reply, callback) end,
          [:link, :monitor]
        )

      timeout = min(remaining, GitCore.Limits.get(:remote_poll_interval_ms))
      await_callback(worker, monitor, reply, timeout, opts)
    end
  end

  defp callback_worker(caller, reply, callback) do
    caller_monitor = Process.monitor(caller)

    result =
      try do
        {:ok, callback.()}
      rescue
        _error -> {:error, :callback_failed}
      catch
        _kind, _reason -> {:error, :callback_failed}
      end

    send(caller, {reply, self(), result})

    receive do
      {:control_ack, ^reply} ->
        Process.demonitor(caller_monitor, [:flush])
        :ok

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        :ok
    end
  end

  defp await_callback(worker, monitor, reply, timeout, opts) do
    parent_monitor = Keyword.fetch!(opts, :parent_monitor)
    owner_exit_pid = Keyword.fetch!(opts, :owner_exit_pid)

    receive do
      {^reply, ^worker, result} ->
        Process.unlink(worker)
        pause_test_handoff(opts, worker, reply)
        send(worker, {:control_ack, reply})
        await_worker_exit(worker, monitor)
        result

      {:DOWN, ^parent_monitor, :process, _parent, _reason} ->
        stop_worker(worker, monitor)
        {:error, :owner_down}

      {:EXIT, ^owner_exit_pid, _reason} ->
        stop_worker(worker, monitor)
        {:error, :owner_down}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :callback_failed}
    after
      timeout ->
        result = timeout_reason(opts)
        stop_worker(worker, monitor)
        {:error, result}
    end
  end

  defp timeout_reason(opts) do
    case owner_status(opts) do
      {:error, :owner_down} ->
        :owner_down

      :ok ->
        if System.monotonic_time(:millisecond) >= Keyword.fetch!(opts, :absolute_deadline),
          do: :timeout,
          else: :callback_failed
    end
  end

  defp owner_status(opts) do
    parent_monitor = Keyword.fetch!(opts, :parent_monitor)
    owner_exit_pid = Keyword.fetch!(opts, :owner_exit_pid)

    receive do
      {:DOWN, ^parent_monitor, :process, _parent, _reason} -> {:error, :owner_down}
      {:EXIT, ^owner_exit_pid, _reason} -> {:error, :owner_down}
    after
      0 -> :ok
    end
  end

  defp await_worker_exit(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        :ok
    after
      GitCore.Limits.get(:remote_poll_interval_ms) ->
        stop_worker(worker, monitor)
    end
  end

  defp stop_worker(worker, monitor) do
    Process.unlink(worker)
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp pause_test_handoff(opts, worker, reply) do
    case Keyword.get(opts, :test_handoff_observer) do
      observer when is_pid(observer) ->
        send(observer, {:control_handoff, self(), worker, reply})

        receive do
          {:continue_control_handoff, ^reply} -> :ok
        after
          GitCore.Limits.get(:remote_poll_interval_ms) -> :ok
        end

      _none ->
        :ok
    end
  end
end
