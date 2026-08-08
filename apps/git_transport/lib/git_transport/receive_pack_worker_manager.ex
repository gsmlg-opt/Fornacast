defmodule GitTransport.ReceivePackWorkerManager do
  @moduledoc false

  use GenServer

  @worker_supervisor GitTransport.ReceivePackWorkerSupervisor
  @shutdown_poll_ms 5

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

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_worker, fun}, _from, state) do
    result = Task.Supervisor.start_child(@worker_supervisor, fun, shutdown: :infinity)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, _state) do
    wait_for_workers()
  end

  defp wait_for_workers do
    case Task.Supervisor.children(@worker_supervisor) do
      [] ->
        :ok

      _workers ->
        Process.sleep(@shutdown_poll_ms)
        wait_for_workers()
    end
  catch
    :exit, _reason -> :ok
  end
end
