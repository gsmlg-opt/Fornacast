defmodule ForgeImports.GitHub.RequestGate do
  @moduledoc "Serializes a bounded GitHub request sequence for one credential identity."

  @acquire_timeout 2_000

  @type gate_key ::
          {:saved_credential, pos_integer()}
          | {:one_time_run, pos_integer()}
          | {:account_setup, pos_integer()}

  @spec run(gate_key(), (-> result)) :: result | {:error, :invalid_gate_key | :busy}
        when result: term()
  def run({kind, id} = gate_key, fun)
      when kind in [:saved_credential, :one_time_run, :account_setup] and is_integer(id) and
             id > 0 and
             id <= 9_223_372_036_854_775_807 and
             is_function(fun, 0) do
    parent = self()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          {^reference, :watchdog, watchdog} ->
            acquire(parent, reference, gate_key, watchdog)
        end
      end)

    watchdog = spawn(fn -> watch_caller(parent, worker, reference) end)
    send(worker, {reference, :watchdog, watchdog})

    receive do
      {^reference, :acquired, ^worker} ->
        result = execute(fun)
        send(worker, {reference, :body_finished})
        await_body_ack(reference, worker, monitor)
        send(worker, {reference, :release})
        await_release(reference, worker, monitor)
        return_result(result)
    after
      @acquire_timeout ->
        cancel_watchdog(watchdog, reference, worker)
        await_down(monitor, worker)
        flush(reference)
        {:error, :busy}
    end
  end

  def run(_gate_key, _fun), do: {:error, :invalid_gate_key}

  defp acquire(parent, reference, gate_key, watchdog) do
    parent_monitor = Process.monitor(parent)
    lock = {{__MODULE__, gate_key}, self()}

    result =
      :global.trans(
        lock,
        fn ->
          send(parent, {reference, :acquired, self()})

          receive do
            {^reference, :body_finished} ->
              send(parent, {reference, :body_finished_ack, self()})

              receive do
                {^reference, :release} ->
                  send(watchdog, {reference, :release_authorized, self()})
                  :released

                {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
                  :caller_stopped
              end

            {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
              :caller_stopped
          end
        end,
        Enum.uniq([node() | Node.list()]),
        :infinity
      )

    send(parent, {reference, :finished, result})
  end

  defp execute(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end
  end

  defp await_release(reference, worker, monitor) do
    receive do
      {^reference, :finished, :released} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {^reference, :finished, :aborted} ->
        Process.demonitor(monitor, [:flush])
        {:error, :busy}

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        exit(reason)
    end
  end

  defp return_result({:returned, result}), do: result

  defp return_result({:raised, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp await_body_ack(reference, worker, monitor) do
    receive do
      {^reference, :body_finished_ack, ^worker} -> :ok
      {:DOWN, ^monitor, :process, ^worker, reason} -> exit(reason)
    end
  end

  defp await_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp flush(reference) do
    receive do
      {^reference, _state, _value} -> flush(reference)
    after
      0 -> :ok
    end
  end

  defp cancel_watchdog(watchdog, reference, worker) do
    send(watchdog, {reference, :cancel, self()})

    receive do
      {^reference, :cancelled, ^watchdog, ^worker} -> :ok
    end
  end

  defp watch_caller(parent, worker, reference) do
    parent_monitor = Process.monitor(parent)
    worker_monitor = Process.monitor(worker)

    receive do
      {^reference, :release_authorized, ^worker} ->
        Process.demonitor(parent_monitor, [:flush])
        await_down(worker_monitor, worker)

      {^reference, :cancel, ^parent} ->
        Process.exit(worker, :kill)
        await_down(worker_monitor, worker)
        Process.demonitor(parent_monitor, [:flush])
        send(parent, {reference, :cancelled, self(), worker})

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        Process.exit(worker, :kill)
        await_down(worker_monitor, worker)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        Process.exit(parent, :kill)
    end
  end
end
