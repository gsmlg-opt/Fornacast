defmodule GitCore.RepositoryWriteLimiter do
  @moduledoc """
  Serializes repository writes by repository key and across the node.

  The supervised child is temporary by design. Restarting it automatically
  would forget leases whose owners survived the crash and could admit
  conflicting writes. After a crash, admission fails closed until an operator
  or application restart deliberately restores the limiter.
  """

  use GenServer

  @lease_tag {__MODULE__, :lease}
  @deadline_timer_chunk_ms 60_000
  @opaque lease :: {{__MODULE__, :lease}, GenServer.server(), reference()}
  @type acquire_error :: :timeout | :unavailable

  defmodule State do
    @moduledoc false
    defstruct capacity: nil,
              grants: %{},
              active_keys: MapSet.new(),
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

  @spec acquire(term(), integer()) ::
          {:ok, lease()} | {:error, acquire_error()}
  def acquire(repository_key, absolute_deadline_ms) when is_integer(absolute_deadline_ms) do
    try do
      case GenServer.call(__MODULE__, {:acquire, repository_key, absolute_deadline_ms}, :infinity) do
        {:ok, lease} -> {:ok, {@lease_tag, __MODULE__, lease}}
        {:error, :timeout} = error -> error
      end
    catch
      :exit, _reason -> {:error, :unavailable}
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
    capacity = Keyword.get(opts, :capacity, GitCore.Limits.get(:repository_writer_concurrency))
    hard_capacity = GitCore.Limits.hard(:repository_writer_concurrency)

    if not (is_integer(capacity) and capacity in 1..hard_capacity) do
      raise ArgumentError,
            "repository writer capacity must be between 1 and #{hard_capacity}"
    end

    {:ok, %State{capacity: capacity}}
  end

  @impl true
  def handle_call({:acquire, repository_key, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      deadline <= now ->
        {:reply, {:error, :timeout}, state}

      :gb_trees.is_empty(state.queue) and available?(state, repository_key) ->
        {lease, state} = grant(elem(from, 0), repository_key, state)
        {:reply, {:ok, lease}, state}

      true ->
        {:noreply, enqueue(from, elem(from, 0), repository_key, deadline, now, state)}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    {:reply, :ok, release_grant(lease, state)}
  end

  @impl true
  def handle_info({:deadline, waiter_id}, state) do
    case Map.fetch(state.waiters, waiter_id) do
      :error ->
        {:noreply, state}

      {:ok, waiter} ->
        now = System.monotonic_time(:millisecond)

        if waiter.deadline <= now do
          GenServer.reply(waiter.from, {:error, :timeout})
          state = remove_waiter(waiter_id, waiter, state)
          {:noreply, drain_waiters(state)}
        else
          timer = schedule_deadline(waiter_id, waiter.deadline, now)
          waiter = %{waiter | timer: timer}
          {:noreply, put_in(state.waiters[waiter_id], waiter)}
        end
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
            active_keys: MapSet.delete(state.active_keys, grant.repository_key),
            monitors: monitors
        }

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

        state = %{state | waiters: waiters, queue: queue, monitors: monitors}
        {:noreply, drain_waiters(state)}
    end
  end

  defp available?(state, repository_key) do
    map_size(state.grants) < state.capacity and
      not MapSet.member?(state.active_keys, repository_key)
  end

  defp grant(owner, repository_key, state) do
    lease = make_ref()
    monitor = Process.monitor(owner)
    grant = %{owner: owner, monitor: monitor, repository_key: repository_key}

    state = %{
      state
      | grants: Map.put(state.grants, lease, grant),
        active_keys: MapSet.put(state.active_keys, repository_key),
        monitors: Map.put(state.monitors, monitor, {:grant, lease})
    }

    {lease, state}
  end

  defp enqueue(from, owner, repository_key, deadline, now, state) do
    waiter_id = make_ref()
    monitor = Process.monitor(owner)
    timer = schedule_deadline(waiter_id, deadline, now)
    sequence = state.next_sequence

    waiter = %{
      from: from,
      owner: owner,
      repository_key: repository_key,
      deadline: deadline,
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

      {%{monitor: monitor, repository_key: repository_key}, grants} ->
        Process.demonitor(monitor, [:flush])

        state = %{
          state
          | grants: grants,
            active_keys: MapSet.delete(state.active_keys, repository_key),
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
      {sequence, waiter_id} = :gb_trees.smallest(state.queue)

      case Map.fetch(state.waiters, waiter_id) do
        :error ->
          drain_waiters(%{state | queue: :gb_trees.delete(sequence, state.queue)})

        {:ok, waiter} ->
          cond do
            waiter.deadline <= System.monotonic_time(:millisecond) ->
              GenServer.reply(waiter.from, {:error, :timeout})
              state = remove_waiter(waiter_id, waiter, state)
              drain_waiters(state)

            available?(state, waiter.repository_key) ->
              Process.cancel_timer(waiter.timer)
              lease = make_ref()

              grant = %{
                owner: waiter.owner,
                monitor: waiter.monitor,
                repository_key: waiter.repository_key
              }

              state = %{
                state
                | queue: :gb_trees.delete(sequence, state.queue),
                  waiters: Map.delete(state.waiters, waiter_id),
                  grants: Map.put(state.grants, lease, grant),
                  active_keys: MapSet.put(state.active_keys, waiter.repository_key),
                  monitors: Map.put(state.monitors, waiter.monitor, {:grant, lease})
              }

              GenServer.reply(waiter.from, {:ok, lease})
              drain_waiters(state)

            true ->
              state
          end
      end
    end
  end

  defp remove_waiter(waiter_id, waiter, state) do
    Process.cancel_timer(waiter.timer)
    Process.demonitor(waiter.monitor, [:flush])

    %{
      state
      | queue: :gb_trees.delete_any(waiter.sequence, state.queue),
        waiters: Map.delete(state.waiters, waiter_id),
        monitors: Map.delete(state.monitors, waiter.monitor)
    }
  end

  defp schedule_deadline(waiter_id, deadline, now) do
    delay = min(deadline - now, @deadline_timer_chunk_ms)
    Process.send_after(self(), {:deadline, waiter_id}, delay)
  end
end
