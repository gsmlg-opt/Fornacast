defmodule GitCore.ScanLimiter do
  @moduledoc false

  use GenServer

  @capacity 4
  @wait_timeout 250

  defmodule State do
    @moduledoc false
    defstruct capacity: nil,
              wait_timeout: nil,
              grants: %{},
              waiters: %{},
              queue: :gb_trees.empty(),
              next_sequence: 0,
              monitors: %{}
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

  def with_permit(operation, fun, opts \\ []) when is_function(fun, 0) do
    server = Keyword.get(opts, :server, __MODULE__)

    case call(server, :acquire) do
      {:ok, lease} ->
        try do
          fun.()
        after
          release(server, lease)
        end

      {:error, :busy} ->
        busy_error(operation, "scan capacity is busy")

      {:error, :unavailable} ->
        busy_error(operation, "scan limiter is unavailable")
    end
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @capacity)
    wait_timeout = Keyword.get(opts, :wait_timeout, @wait_timeout)

    if not (is_integer(capacity) and capacity in 1..@capacity) do
      raise ArgumentError, "scan limiter capacity must be between 1 and #{@capacity}"
    end

    if not (is_integer(wait_timeout) and wait_timeout in 0..@wait_timeout) do
      raise ArgumentError,
            "scan limiter wait timeout must be between 0 and #{@wait_timeout} milliseconds"
    end

    {:ok, %State{capacity: capacity, wait_timeout: wait_timeout}}
  end

  @impl true
  def handle_call(:acquire, from, state) do
    owner = elem(from, 0)

    if map_size(state.grants) < state.capacity and map_size(state.waiters) == 0 do
      {lease, state} = grant(owner, state)
      {:reply, {:ok, lease}, state}
    else
      {:noreply, enqueue(from, owner, state)}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    {:reply, :ok, release_grant(lease, state)}
  end

  @impl true
  def handle_info({:wait_timeout, waiter_id}, state) do
    case Map.pop(state.waiters, waiter_id) do
      {nil, _waiters} ->
        {:noreply, state}

      {%{from: from, monitor: monitor, sequence: sequence}, waiters} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(from, {:error, :busy})

        state = %{
          state
          | waiters: waiters,
            queue: :gb_trees.delete_any(sequence, state.queue),
            monitors: Map.delete(state.monitors, monitor)
        }

        {:noreply, drain_waiters(state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:grant, lease}, monitors} ->
        state = %{state | grants: Map.delete(state.grants, lease), monitors: monitors}
        {:noreply, drain_waiters(state)}

      {{:waiter, waiter_id}, monitors} ->
        {waiter, waiters} = Map.pop(state.waiters, waiter_id)

        queue =
          if waiter do
            Process.cancel_timer(waiter.timer)
            :gb_trees.delete_any(waiter.sequence, state.queue)
          else
            state.queue
          end

        state = %{
          state
          | waiters: waiters,
            queue: queue,
            monitors: monitors
        }

        {:noreply, drain_waiters(state)}
    end
  end

  defp call(server, message) do
    try do
      GenServer.call(server, message, :infinity)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  defp release(server, lease) do
    try do
      GenServer.call(server, {:release, lease}, :infinity)
    catch
      :exit, _reason -> :ok
    end
  end

  defp grant(owner, state) do
    lease = make_ref()
    monitor = Process.monitor(owner)

    state = %{
      state
      | grants: Map.put(state.grants, lease, %{owner: owner, monitor: monitor}),
        monitors: Map.put(state.monitors, monitor, {:grant, lease})
    }

    {lease, state}
  end

  defp enqueue(from, owner, state) do
    waiter_id = make_ref()
    monitor = Process.monitor(owner)
    timer = Process.send_after(self(), {:wait_timeout, waiter_id}, state.wait_timeout)
    sequence = state.next_sequence

    waiter = %{
      from: from,
      owner: owner,
      monitor: monitor,
      timer: timer,
      sequence: sequence
    }

    %{
      state
      | waiters: Map.put(state.waiters, waiter_id, waiter),
        queue: :gb_trees.insert(sequence, waiter_id, state.queue),
        next_sequence: sequence + 1,
        monitors: Map.put(state.monitors, monitor, {:waiter, waiter_id})
    }
  end

  defp release_grant(lease, state) do
    case Map.pop(state.grants, lease) do
      {nil, _grants} ->
        state

      {%{monitor: monitor}, grants} ->
        Process.demonitor(monitor, [:flush])

        state = %{
          state
          | grants: grants,
            monitors: Map.delete(state.monitors, monitor)
        }

        drain_waiters(state)
    end
  end

  defp drain_waiters(state) when map_size(state.grants) >= state.capacity, do: state

  defp drain_waiters(state) do
    if :gb_trees.is_empty(state.queue) do
      state
    else
      {_sequence, waiter_id, queue} = :gb_trees.take_smallest(state.queue)

      case Map.pop(state.waiters, waiter_id) do
        {nil, waiters} ->
          drain_waiters(%{state | queue: queue, waiters: waiters})

        {waiter, waiters} ->
          Process.cancel_timer(waiter.timer)
          lease = make_ref()

          grants =
            Map.put(state.grants, lease, %{owner: waiter.owner, monitor: waiter.monitor})

          monitors = Map.put(state.monitors, waiter.monitor, {:grant, lease})
          GenServer.reply(waiter.from, {:ok, lease})

          drain_waiters(%{
            state
            | queue: queue,
              waiters: waiters,
              grants: grants,
              monitors: monitors
          })
      end
    end
  end

  defp busy_error(operation, detail) do
    {:error, %GitCore.Error{kind: :scan_busy, operation: operation, detail: detail}}
  end
end
