defmodule GitTransport.ReceivePackWorkerManager do
  @moduledoc false

  use GenServer

  @worker_supervisor GitTransport.ReceivePackWorkerSupervisor
  @registry_key {__MODULE__, :workers}
  @registry_lock {__MODULE__, :registry_lock}
  @shutdown_poll_ms 5
  @start_handshake_timeout_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  @doc false
  def start_worker(fun, opts \\ []) when is_function(fun, 0) do
    server = Keyword.get(opts, :server, __MODULE__)

    try do
      GenServer.call(server, {:start_worker, fun}, :infinity)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  @doc false
  def tracked_worker_count(server \\ __MODULE__) do
    GenServer.call(server, :tracked_worker_count)
  end

  @doc false
  def persisted_worker_count do
    registry_transaction(fn registry -> {registry, map_size(registry)} end)
  end

  @doc false
  def forget_worker(token, worker) when is_reference(token) and is_pid(worker) do
    registry_transaction(fn registry ->
      updated =
        case Map.fetch(registry, token) do
          {:ok, %{pid: ^worker}} -> Map.delete(registry, token)
          _other -> registry
        end

      {updated, :ok}
    end)
  end

  if Mix.env() == :test do
    @fault_key {__MODULE__, :test_fault}

    @doc false
    def set_test_fault(fault) do
      if is_nil(fault),
        do: :persistent_term.erase(@fault_key),
        else: :persistent_term.put(@fault_key, fault)

      :ok
    end

    defp maybe_test_crash!(phase) do
      if :persistent_term.get(@fault_key, nil) == phase do
        Process.exit(self(), :kill)
      end
    end
  else
    defp maybe_test_crash!(_phase), do: :ok
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, recover_workers()}
  end

  @impl true
  def handle_call({:start_worker, fun}, from, state) do
    manager = self()
    token = make_ref()

    case safe_start_child(fn -> await_admission(manager, token, fun) end) do
      {:ok, worker} ->
        monitor = Process.monitor(worker)

        tracked = %{
          pid: worker,
          monitor: monitor,
          from: from,
          status: :pending
        }

        {:noreply, put_tracked(state, token, tracked)}

      {:error, _reason} ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call(:tracked_worker_count, _from, state) do
    {:reply, map_size(state.workers), state}
  end

  @impl true
  def handle_info({:worker_ready, token, worker}, state) do
    case Map.fetch(state.workers, token) do
      {:ok, %{pid: ^worker, status: :pending} = tracked} ->
        maybe_test_crash!(:after_ready)
        :ok = persist_worker(token, worker, :pending)
        maybe_test_crash!(:after_persist)
        send(self(), {:activate_worker, token})
        tracked = %{tracked | status: :ready}
        {:noreply, %{state | workers: Map.put(state.workers, token, tracked)}}

      _other ->
        monitor = Process.monitor(worker)
        send(worker, {:abort, token})

        tracked = %{pid: worker, monitor: monitor, from: nil, status: :aborting}
        {:noreply, put_tracked(state, token, tracked)}
    end
  end

  def handle_info({:activate_worker, token}, state) do
    case Map.fetch(state.workers, token) do
      {:ok, %{status: :ready} = tracked} ->
        :ok = persist_worker(token, tracked.pid, :active)
        maybe_test_crash!(:after_active_persist)
        GenServer.reply(tracked.from, {:ok, tracked.pid})
        maybe_test_crash!(:after_reply)
        send(tracked.pid, {:go, token})
        maybe_test_crash!(:after_go)
        tracked = %{tracked | from: nil, status: :active}
        {:noreply, %{state | workers: Map.put(state.workers, token, tracked)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, worker, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {token, monitors} ->
        {tracked, workers} = Map.pop(state.workers, token)
        :ok = forget_worker(token, worker)
        maybe_reply_unavailable(tracked)
        {:noreply, %{state | workers: workers, monitors: monitors}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state = abort_unadmitted(state)
    monitors = monitor_registry_union(state)
    wait_for_tracked(monitors)
    wait_for_current_supervisor_workers()
  end

  defp safe_start_child(fun) do
    try do
      Task.Supervisor.start_child(@worker_supervisor, fun, shutdown: :infinity)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  defp await_admission(manager, token, fun) do
    Process.flag(:trap_exit, true)
    manager_monitor = Process.monitor(manager)
    send(manager, {:worker_ready, token, self()})

    receive do
      {:go, ^token} ->
        Process.demonitor(manager_monitor, [:flush])

        try do
          fun.()
        after
          forget_worker(token, self())
        end

      {:abort, ^token} ->
        forget_worker(token, self())

      {:DOWN, ^manager_monitor, :process, ^manager, _reason} ->
        forget_worker(token, self())
    after
      @start_handshake_timeout_ms -> forget_worker(token, self())
    end
  end

  defp recover_workers do
    entries =
      registry_transaction(fn registry ->
        live =
          Map.filter(registry, fn
            {_token, %{pid: pid, status: status}}
            when is_pid(pid) and status in [:pending, :active] ->
              Process.alive?(pid)

            _entry ->
              false
          end)

        {live, live}
      end)

    Enum.reduce(entries, %{workers: %{}, monitors: %{}}, fn {token, entry}, state ->
      monitor = Process.monitor(entry.pid)
      status = if entry.status == :pending, do: :aborting, else: :active

      if status == :aborting do
        send(entry.pid, {:abort, token})
      end

      tracked = %{pid: entry.pid, monitor: monitor, from: nil, status: status}
      put_tracked(state, token, tracked)
    end)
  end

  defp persist_worker(token, worker, status) when status in [:pending, :active] do
    registry_transaction(fn registry ->
      entry = %{pid: worker, status: status}
      {Map.put(registry, token, entry), :ok}
    end)
  end

  defp registry_transaction(fun) do
    lock = {@registry_lock, self()}

    :global.trans(
      lock,
      fn ->
        registry = :persistent_term.get(@registry_key, %{})
        {updated, result} = fun.(registry)

        if updated != registry do
          :persistent_term.put(@registry_key, updated)
        end

        result
      end,
      [node()]
    )
  end

  defp put_tracked(state, token, tracked) do
    %{
      state
      | workers: Map.put(state.workers, token, tracked),
        monitors: Map.put(state.monitors, tracked.monitor, token)
    }
  end

  defp maybe_reply_unavailable(%{from: nil}), do: :ok
  defp maybe_reply_unavailable(%{from: from}), do: GenServer.reply(from, {:error, :unavailable})
  defp maybe_reply_unavailable(nil), do: :ok

  defp abort_unadmitted(state) do
    Enum.each(state.workers, fn {token, tracked} ->
      if tracked.status in [:pending, :ready, :aborting] do
        send(tracked.pid, {:abort, token})
        maybe_reply_unavailable(tracked)
      end
    end)

    state
  end

  defp monitor_registry_union(state) do
    registry_transaction(fn registry ->
      live = Map.filter(registry, fn {_token, entry} -> Process.alive?(entry.pid) end)
      {live, live}
    end)
    |> Enum.reduce(Map.keys(state.monitors), fn {token, entry}, monitors ->
      if entry.status == :pending, do: send(entry.pid, {:abort, token})

      if Enum.any?(state.workers, fn {_token, tracked} -> tracked.pid == entry.pid end) do
        monitors
      else
        [Process.monitor(entry.pid) | monitors]
      end
    end)
    |> Enum.uniq()
  end

  defp wait_for_tracked([]), do: :ok

  defp wait_for_tracked(monitors) do
    receive do
      {:DOWN, monitor, :process, _worker, _reason} ->
        wait_for_tracked(List.delete(monitors, monitor))
    end
  end

  defp wait_for_current_supervisor_workers do
    case Task.Supervisor.children(@worker_supervisor) do
      [] ->
        :ok

      _workers ->
        Process.sleep(@shutdown_poll_ms)
        wait_for_current_supervisor_workers()
    end
  catch
    :exit, _reason -> :ok
  end
end
