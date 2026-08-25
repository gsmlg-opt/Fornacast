defmodule ForgeImports.GitHub.RequestGate do
  @moduledoc "Serializes a bounded GitHub request sequence for one credential identity."

  @acquire_timeout 2_000

  @type gate_key :: {:saved_credential, pos_integer()} | {:one_time_run, pos_integer()}

  @spec run(gate_key(), (-> result)) :: result | {:error, :invalid_gate_key | :busy}
        when result: term()
  def run({kind, id} = gate_key, fun)
      when kind in [:saved_credential, :one_time_run] and is_integer(id) and id > 0 and
             id <= 9_223_372_036_854_775_807 and
             is_function(fun, 0) do
    parent = self()
    reference = make_ref()
    callers = Process.get(:"$callers", [])

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", [parent | callers])
        acquire_and_run(parent, reference, gate_key, fun)
      end)

    _watchdog = spawn(fn -> watch_caller(parent, worker) end)

    receive do
      {^reference, :acquired, ^worker} ->
        send(worker, {reference, :proceed})
        await_result(reference, worker, monitor)
    after
      @acquire_timeout ->
        Process.exit(worker, :kill)
        await_down(monitor, worker)
        flush(reference)
        {:error, :busy}
    end
  end

  def run(_gate_key, _fun), do: {:error, :invalid_gate_key}

  defp acquire_and_run(parent, reference, gate_key, fun) do
    parent_monitor = Process.monitor(parent)
    lock = {{__MODULE__, gate_key}, self()}

    result =
      :global.trans(
        lock,
        fn ->
          send(parent, {reference, :acquired, self()})

          receive do
            {^reference, :proceed} -> execute(fun)
            {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :caller_stopped
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

  defp await_result(reference, worker, monitor) do
    receive do
      {^reference, :finished, {:returned, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      {^reference, :finished, {:raised, kind, reason, stacktrace}} ->
        Process.demonitor(monitor, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {^reference, :finished, :aborted} ->
        Process.demonitor(monitor, [:flush])
        {:error, :busy}

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        exit(reason)
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

  defp watch_caller(parent, worker) do
    parent_monitor = Process.monitor(parent)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        Process.exit(worker, :kill)
        await_down(worker_monitor, worker)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        Process.demonitor(parent_monitor, [:flush])
        :ok
    end
  end
end
