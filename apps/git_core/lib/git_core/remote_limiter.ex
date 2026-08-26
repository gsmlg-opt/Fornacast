defmodule GitCore.RemoteLimiter do
  @moduledoc false

  use GenServer

  defmodule State do
    @moduledoc false
    defstruct capacity: nil, grants: %{}, monitors: %{}
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker,
      modules: [__MODULE__]
    }
  end

  def start_link(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    start_opts = if is_nil(server), do: [], else: [name: server]
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  def with_permit(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    case call(server, :acquire) do
      {:ok, lease} ->
        try do
          fun.()
        after
          release(server, lease)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, GitCore.Limits.get(:remote_concurrency))
    hard_capacity = GitCore.Limits.hard(:remote_concurrency)

    if is_integer(capacity) and capacity in 1..hard_capacity do
      {:ok, %State{capacity: capacity}}
    else
      raise ArgumentError, "remote limiter capacity must be between 1 and #{hard_capacity}"
    end
  end

  @impl true
  def handle_call(:acquire, from, state) do
    if map_size(state.grants) < state.capacity do
      owner = elem(from, 0)
      lease = make_ref()
      monitor = Process.monitor(owner)

      {:reply, {:ok, lease},
       %{
         state
         | grants: Map.put(state.grants, lease, monitor),
           monitors: Map.put(state.monitors, monitor, lease)
       }}
    else
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    {:reply, :ok, release_grant(lease, state)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {lease, monitors} ->
        {:noreply, %{state | grants: Map.delete(state.grants, lease), monitors: monitors}}
    end
  end

  defp call(server, message) do
    try do
      GenServer.call(server, message, 250)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  defp release(server, lease) do
    try do
      GenServer.call(server, {:release, lease}, 250)
    catch
      :exit, _reason -> :ok
    end
  end

  defp release_grant(lease, state) do
    case Map.pop(state.grants, lease) do
      {nil, grants} ->
        %{state | grants: grants}

      {monitor, grants} ->
        Process.demonitor(monitor, [:flush])
        %{state | grants: grants, monitors: Map.delete(state.monitors, monitor)}
    end
  end
end
