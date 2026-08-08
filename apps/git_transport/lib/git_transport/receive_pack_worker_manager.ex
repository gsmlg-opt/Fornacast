defmodule GitTransport.ReceivePackWorkerManager do
  @moduledoc false

  use GenServer

  @worker_supervisor GitTransport.ReceivePackWorkerSupervisor
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

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{workers: %{}, monitors: %{}}}
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
        send(tracked.pid, {:go, token})
        GenServer.reply(tracked.from, {:ok, tracked.pid})
        tracked = %{tracked | from: nil, status: :active}
        {:noreply, %{state | workers: Map.put(state.workers, token, tracked)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _worker, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {token, monitors} ->
        {tracked, workers} = Map.pop(state.workers, token)
        maybe_reply_unavailable(tracked)
        {:noreply, %{state | workers: workers, monitors: monitors}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state = abort_unadmitted(state)
    wait_for_tracked(Map.keys(state.monitors))
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
    send(manager, {:worker_ready, token, self()})

    receive do
      {:go, ^token} -> fun.()
      {:abort, ^token} -> :ok
    after
      @start_handshake_timeout_ms -> :ok
    end
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
