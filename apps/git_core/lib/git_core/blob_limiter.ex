defmodule GitCore.BlobLimiter do
  @moduledoc false

  use GenServer

  @capacity 8
  @byte_capacity 128 * 1024 * 1024
  @wait_timeout 250
  @lease_tag {__MODULE__, :lease}

  @opaque lease :: {{__MODULE__, :lease}, GenServer.server(), reference()}

  defmodule State do
    @moduledoc false
    defstruct capacity: nil,
              byte_capacity: nil,
              wait_timeout: nil,
              used_bytes: 0,
              grants: %{},
              waiters: %{},
              queue: :queue.new(),
              monitors: %{}
  end

  def start_link(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    start_opts = if is_nil(server), do: [], else: [name: server]
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @spec acquire(non_neg_integer(), keyword()) :: {:ok, lease()} | {:error, %GitCore.Error{}}
  def acquire(weight, opts \\ []) when is_integer(weight) and weight >= 0 do
    server = Keyword.get(opts, :server, __MODULE__)
    operation = Keyword.get(opts, :operation, :read_blob)

    if weight > @byte_capacity do
      error(:blob_too_large, operation, "blob exceeds the 128 MiB declared-byte limit")
    else
      case call(server, {:acquire, weight}) do
        {:ok, lease} ->
          {:ok, {@lease_tag, server, lease}}

        {:error, :too_large} ->
          error(:blob_too_large, operation, "blob exceeds the declared-byte limit")

        {:error, :busy} ->
          error(:blob_busy, operation, "blob capacity is busy")

        {:error, :unavailable} ->
          error(:blob_busy, operation, "blob limiter is unavailable")
      end
    end
  end

  @spec release(lease()) :: :ok
  def release({@lease_tag, server, lease}) when is_reference(lease) do
    try do
      GenServer.call(server, {:release, lease}, :infinity)
    catch
      :exit, _reason -> :ok
    end
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @capacity)
    byte_capacity = Keyword.get(opts, :byte_capacity, @byte_capacity)
    wait_timeout = Keyword.get(opts, :wait_timeout, @wait_timeout)

    if not (is_integer(capacity) and capacity in 1..@capacity) do
      raise ArgumentError, "blob limiter capacity must be between 1 and #{@capacity}"
    end

    if not (is_integer(byte_capacity) and byte_capacity in 0..@byte_capacity) do
      raise ArgumentError,
            "blob limiter byte capacity must be between 0 and #{@byte_capacity}"
    end

    if not (is_integer(wait_timeout) and wait_timeout in 0..@wait_timeout) do
      raise ArgumentError,
            "blob limiter wait timeout must be between 0 and #{@wait_timeout} milliseconds"
    end

    {:ok,
     %State{
       capacity: capacity,
       byte_capacity: byte_capacity,
       wait_timeout: wait_timeout
     }}
  end

  @impl true
  def handle_call({:acquire, weight}, from, state) do
    cond do
      weight > state.byte_capacity ->
        {:reply, {:error, :too_large}, state}

      map_size(state.waiters) == 0 and available?(state, weight) ->
        {lease, state} = grant(elem(from, 0), weight, state)
        {:reply, {:ok, lease}, state}

      true ->
        {:noreply, enqueue(from, elem(from, 0), weight, state)}
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

      {%{from: from, monitor: monitor}, waiters} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(from, {:error, :busy})

        state = %{
          state
          | waiters: waiters,
            queue: remove_from_queue(state.queue, waiter_id),
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
        {grant, grants} = Map.pop!(state.grants, lease)

        state = %{
          state
          | grants: grants,
            monitors: monitors,
            used_bytes: state.used_bytes - grant.weight
        }

        {:noreply, drain_waiters(state)}

      {{:waiter, waiter_id}, monitors} ->
        {waiter, waiters} = Map.pop(state.waiters, waiter_id)

        if waiter do
          Process.cancel_timer(waiter.timer)
        end

        state = %{
          state
          | waiters: waiters,
            queue: remove_from_queue(state.queue, waiter_id),
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

  defp available?(state, weight) do
    map_size(state.grants) < state.capacity and
      state.used_bytes + weight <= state.byte_capacity
  end

  defp grant(owner, weight, state) do
    lease = make_ref()
    monitor = Process.monitor(owner)

    grant = %{owner: owner, monitor: monitor, weight: weight}

    state = %{
      state
      | grants: Map.put(state.grants, lease, grant),
        monitors: Map.put(state.monitors, monitor, {:grant, lease}),
        used_bytes: state.used_bytes + weight
    }

    {lease, state}
  end

  defp enqueue(from, owner, weight, state) do
    waiter_id = make_ref()
    monitor = Process.monitor(owner)
    timer = Process.send_after(self(), {:wait_timeout, waiter_id}, state.wait_timeout)
    waiter = %{from: from, owner: owner, monitor: monitor, timer: timer, weight: weight}

    %{
      state
      | waiters: Map.put(state.waiters, waiter_id, waiter),
        queue: :queue.in(waiter_id, state.queue),
        monitors: Map.put(state.monitors, monitor, {:waiter, waiter_id})
    }
  end

  defp release_grant(lease, state) do
    case Map.pop(state.grants, lease) do
      {nil, _grants} ->
        state

      {%{monitor: monitor, weight: weight}, grants} ->
        Process.demonitor(monitor, [:flush])

        state = %{
          state
          | grants: grants,
            monitors: Map.delete(state.monitors, monitor),
            used_bytes: state.used_bytes - weight
        }

        drain_waiters(state)
    end
  end

  defp drain_waiters(state) do
    case :queue.peek(state.queue) do
      :empty ->
        state

      {:value, waiter_id} ->
        case Map.fetch(state.waiters, waiter_id) do
          :error ->
            {{:value, ^waiter_id}, queue} = :queue.out(state.queue)
            drain_waiters(%{state | queue: queue})

          {:ok, waiter} ->
            if available?(state, waiter.weight) do
              {{:value, ^waiter_id}, queue} = :queue.out(state.queue)
              Process.cancel_timer(waiter.timer)
              lease = make_ref()

              grant = %{owner: waiter.owner, monitor: waiter.monitor, weight: waiter.weight}

              state = %{
                state
                | queue: queue,
                  waiters: Map.delete(state.waiters, waiter_id),
                  grants: Map.put(state.grants, lease, grant),
                  monitors: Map.put(state.monitors, waiter.monitor, {:grant, lease}),
                  used_bytes: state.used_bytes + waiter.weight
              }

              GenServer.reply(waiter.from, {:ok, lease})
              drain_waiters(state)
            else
              state
            end
        end
    end
  end

  defp remove_from_queue(queue, waiter_id) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == waiter_id))
    |> :queue.from_list()
  end

  defp error(kind, operation, detail) do
    {:error, %GitCore.Error{kind: kind, operation: operation, detail: detail}}
  end
end
