defmodule GitCore.RepositoryWriteLimiter do
  @moduledoc """
  Serializes repository writes by repository key and across the node.

  The supervised child is temporary by design. Restarting it automatically
  could admit conflicting writes before lease state is recovered. After a
  crash, admission fails closed until an operator or application restart
  reconstructs live production grants and their owner monitors.

  New grants are persisted as pending and confirmed before the opaque lease is
  returned. Restart recovery discards any pending lease that was never public.
  """

  use GenServer

  @lease_tag {__MODULE__, :lease}
  @production_registry_key {__MODULE__, :production_grants}
  @production_registry_lock {__MODULE__, :production_registry_lock}
  @fault_config_key :repository_write_limiter_fault
  @deadline_timer_chunk_ms 60_000
  @opaque lease :: {{__MODULE__, :lease}, GenServer.server(), reference()}
  @type acquire_error :: :timeout | :unavailable

  defmodule State do
    @moduledoc false
    defstruct capacity: nil,
              production_registry?: false,
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
    case call_server({:acquire, repository_key, absolute_deadline_ms}) do
      {:ok, lease} -> confirm_public_lease(lease)
      {:error, :timeout} = error -> error
      {:error, :unavailable} = error -> error
    end
  end

  @spec release(lease()) :: :ok
  def release({@lease_tag, server, lease}) when is_reference(lease) do
    try do
      GenServer.call(server, {:release, lease}, :infinity)
    catch
      :exit, _reason ->
        if server == __MODULE__ do
          delete_production_grant(lease)
          release_recovered_grant(server, lease)
        end

        :ok
    end
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, GitCore.Limits.get(:repository_writer_concurrency))
    hard_capacity = GitCore.Limits.hard(:repository_writer_concurrency)
    production_registry? = Keyword.get(opts, :server, __MODULE__) == __MODULE__

    if not (is_integer(capacity) and capacity in 1..hard_capacity) do
      raise ArgumentError,
            "repository writer capacity must be between 1 and #{hard_capacity}"
    end

    state = %State{capacity: capacity, production_registry?: production_registry?}

    if production_registry? do
      {:ok, recover_production_grants(state)}
    else
      {:ok, state}
    end
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

  def handle_call({:confirm, lease}, from, state) do
    owner = elem(from, 0)

    case Map.fetch(state.grants, lease) do
      {:ok, %{owner: ^owner, status: :pending} = grant} ->
        case confirm_production_grant(state, lease) do
          :ok ->
            maybe_crash_limiter!(state, :after_confirmed_persist)
            grant = %{grant | status: :confirmed}
            {:reply, :ok, %{state | grants: Map.put(state.grants, lease, grant)}}

          :error ->
            {:reply, {:error, :invalid_lease}, state}
        end

      {:ok, %{owner: ^owner, status: :confirmed}} ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :invalid_lease}, state}
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
        forget_production_grant(state, lease)

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
    grant = %{owner: owner, monitor: monitor, repository_key: repository_key, status: :pending}
    persist_production_grant(state, lease, owner, repository_key, :pending)

    state = %{
      state
      | grants: Map.put(state.grants, lease, grant),
        active_keys: MapSet.put(state.active_keys, repository_key),
        monitors: Map.put(state.monitors, monitor, {:grant, lease})
    }

    maybe_crash_limiter!(state, :after_pending_persist)
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
        forget_production_grant(state, lease)
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
                repository_key: waiter.repository_key,
                status: :pending
              }

              persist_production_grant(
                state,
                lease,
                waiter.owner,
                waiter.repository_key,
                :pending
              )

              state = %{
                state
                | queue: :gb_trees.delete(sequence, state.queue),
                  waiters: Map.delete(state.waiters, waiter_id),
                  grants: Map.put(state.grants, lease, grant),
                  active_keys: MapSet.put(state.active_keys, waiter.repository_key),
                  monitors: Map.put(state.monitors, waiter.monitor, {:grant, lease})
              }

              maybe_crash_limiter!(state, :after_pending_persist)
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

  defp recover_production_grants(state) do
    {grants, active_keys, monitors} =
      registry_transaction(fn registry ->
        {grants, active_keys, monitors, live_registry} =
          Enum.reduce(registry, {%{}, MapSet.new(), %{}, %{}}, fn
            {lease, %{owner: owner, repository_key: repository_key, status: :confirmed}},
            {grants, active_keys, monitors, live_registry}
            when is_reference(lease) and is_pid(owner) ->
              if Process.alive?(owner) do
                monitor = Process.monitor(owner)

                grant = %{
                  owner: owner,
                  monitor: monitor,
                  repository_key: repository_key,
                  status: :confirmed
                }

                {
                  Map.put(grants, lease, grant),
                  MapSet.put(active_keys, repository_key),
                  Map.put(monitors, monitor, {:grant, lease}),
                  Map.put(live_registry, lease, %{
                    owner: owner,
                    repository_key: repository_key,
                    status: :confirmed
                  })
                }
              else
                {grants, active_keys, monitors, live_registry}
              end

            _entry, acc ->
              acc
          end)

        {live_registry, {grants, active_keys, monitors}}
      end)

    %{state | grants: grants, active_keys: active_keys, monitors: monitors}
  end

  defp persist_production_grant(
         %{production_registry?: true},
         lease,
         owner,
         repository_key,
         status
       ) do
    grant = %{owner: owner, repository_key: repository_key, status: status}
    registry_transaction(fn registry -> {Map.put(registry, lease, grant), :ok} end)
  end

  defp persist_production_grant(_state, _lease, _owner, _repository_key, _status), do: :ok

  defp confirm_production_grant(%{production_registry?: true}, lease) do
    registry_transaction(fn registry ->
      case Map.fetch(registry, lease) do
        {:ok, %{status: :pending} = grant} ->
          {Map.put(registry, lease, %{grant | status: :confirmed}), :ok}

        _missing_or_invalid ->
          {registry, :error}
      end
    end)
  end

  defp confirm_production_grant(_state, _lease), do: :ok

  defp forget_production_grant(%{production_registry?: true}, lease) do
    delete_production_grant(lease)
  end

  defp forget_production_grant(_state, _lease), do: :ok

  defp delete_production_grant(lease) do
    registry_transaction(fn registry -> {Map.delete(registry, lease), :ok} end)
  end

  defp registry_transaction(fun) do
    lock = {@production_registry_lock, self()}

    :global.trans(
      lock,
      fn ->
        registry = :persistent_term.get(@production_registry_key, %{})
        {updated_registry, result} = fun.(registry)

        if updated_registry != registry do
          :persistent_term.put(@production_registry_key, updated_registry)
        end

        result
      end,
      [node()]
    )
  end

  defp release_recovered_grant(server, lease) do
    try do
      GenServer.call(server, {:release, lease}, :infinity)
    catch
      :exit, _reason -> :ok
    end
  end

  defp call_server(message) do
    try do
      GenServer.call(__MODULE__, message, :infinity)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  defp confirm_public_lease(lease) do
    maybe_crash_after_internal_reply()

    case call_server({:confirm, lease}) do
      :ok ->
        {:ok, {@lease_tag, __MODULE__, lease}}

      _error ->
        delete_production_grant(lease)
        release_recovered_grant(__MODULE__, lease)
        {:error, :unavailable}
    end
  end

  defp maybe_crash_limiter!(%{production_registry?: true}, phase) do
    if Application.get_env(:git_core, @fault_config_key) == phase do
      Process.exit(self(), :kill)
    end
  end

  defp maybe_crash_limiter!(_state, _phase), do: :ok

  defp maybe_crash_after_internal_reply do
    if Application.get_env(:git_core, @fault_config_key) == :after_internal_reply do
      case Process.whereis(__MODULE__) do
        limiter when is_pid(limiter) ->
          monitor = Process.monitor(limiter)
          Process.exit(limiter, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^limiter, _reason} -> :ok
          end

        nil ->
          :ok
      end
    end
  end
end
