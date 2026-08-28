defmodule GitCore.RepositoryReadLimiter do
  @moduledoc """
  Coordinates repository readers with exclusive cleanup leases.

  Reads share a repository. Cleanup is exclusive, and once cleanup is queued,
  later readers wait behind it. Grants are owned by the acquiring process and
  are released automatically when that process exits.

  The production process is temporary and fails closed after a crash. Confirmed
  live grants are recovered from a registry when the application restarts;
  pending grants and queues are deliberately discarded.
  """

  use GenServer

  @read_lease_tag {__MODULE__, :read_lease}
  @cleanup_lease_tag {__MODULE__, :cleanup_lease}
  @production_registry_key {__MODULE__, :production_grants}
  @production_registry_lock {__MODULE__, :production_registry_lock}
  @fault_config_key :repository_read_limiter_fault
  @deadline_timer_chunk_ms 60_000

  @opaque lease ::
            {{__MODULE__, :read_lease} | {__MODULE__, :cleanup_lease}, GenServer.server(),
             reference()}
  @type acquire_error :: :deadline_exceeded | :unavailable
  @type lease_type :: :read | :cleanup

  defmodule State do
    @moduledoc false
    defstruct production_registry?: false,
              grants: %{},
              keys: %{},
              waiters: %{},
              queues: %{},
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

  @spec acquire_read(term(), integer()) :: {:ok, lease()} | {:error, acquire_error()}
  def acquire_read(repository_id, absolute_deadline_ms)
      when is_integer(repository_id) and repository_id > 0 and is_integer(absolute_deadline_ms) do
    acquire(:read, repository_id, absolute_deadline_ms)
  end

  def acquire_read(_repository_id, _absolute_deadline_ms), do: {:error, :unavailable}

  @spec acquire_cleanup(term(), integer()) :: {:ok, lease()} | {:error, acquire_error()}
  def acquire_cleanup(repository_id, absolute_deadline_ms)
      when is_integer(repository_id) and repository_id > 0 and is_integer(absolute_deadline_ms) do
    acquire(:cleanup, repository_id, absolute_deadline_ms)
  end

  def acquire_cleanup(_repository_id, _absolute_deadline_ms), do: {:error, :unavailable}

  @spec release(lease()) :: :ok
  def release({tag, server, lease})
      when tag in [@read_lease_tag, @cleanup_lease_tag] and is_reference(lease) do
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
    production_registry? = Keyword.get(opts, :server, __MODULE__) == __MODULE__
    state = %State{production_registry?: production_registry?}
    {:ok, if(production_registry?, do: recover_production_grants(state), else: state)}
  end

  @impl true
  def handle_call({:acquire, type, repository_id, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      deadline <= now ->
        {:reply, {:error, :deadline_exceeded}, state}

      queue_empty?(state, repository_id) and available?(state, type, repository_id) ->
        {lease, state} = grant(elem(from, 0), type, repository_id, state)
        {:reply, {:ok, lease}, state}

      true ->
        {:noreply, enqueue(from, elem(from, 0), type, repository_id, deadline, now, state)}
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
          GenServer.reply(waiter.from, {:error, :deadline_exceeded})
          state = remove_waiter(waiter_id, waiter, state)
          {:noreply, drain_key(waiter.repository_id, state)}
        else
          timer = schedule_deadline(waiter_id, waiter.deadline, now)
          {:noreply, put_in(state.waiters[waiter_id].timer, timer)}
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

        state =
          %{state | grants: grants, monitors: monitors}
          |> remove_active_grant(lease, grant)
          |> then(&drain_key(grant.repository_id, &1))

        {:noreply, state}

      {{:waiter, waiter_id}, monitors} ->
        case Map.pop(state.waiters, waiter_id) do
          {nil, waiters} ->
            {:noreply, %{state | waiters: waiters, monitors: monitors}}

          {waiter, waiters} ->
            Process.cancel_timer(waiter.timer)

            state =
              %{state | waiters: waiters, monitors: monitors}
              |> delete_from_queue(waiter.repository_id, waiter_id)
              |> then(&drain_key(waiter.repository_id, &1))

            {:noreply, state}
        end
    end
  end

  defp acquire(type, repository_id, deadline) do
    case call_server({:acquire, type, repository_id, deadline}) do
      {:ok, lease} -> confirm_public_lease(type, lease)
      {:error, :deadline_exceeded} = error -> error
      {:error, :unavailable} = error -> error
    end
  end

  defp available?(state, :read, repository_id) do
    state.keys |> Map.get(repository_id, empty_key_state()) |> Map.fetch!(:cleanup) |> is_nil()
  end

  defp available?(state, :cleanup, repository_id) do
    case Map.get(state.keys, repository_id, empty_key_state()) do
      %{cleanup: nil, reads: reads} -> MapSet.size(reads) == 0
      _active -> false
    end
  end

  defp queue_empty?(state, repository_id) do
    state.queues |> Map.get(repository_id, :queue.new()) |> :queue.is_empty()
  end

  defp grant(owner, type, repository_id, state, monitor \\ nil) do
    lease = make_ref()
    monitor = monitor || Process.monitor(owner)

    grant = %{
      owner: owner,
      monitor: monitor,
      repository_id: repository_id,
      type: type,
      status: :pending
    }

    persist_production_grant(state, lease, grant)

    state =
      state
      |> Map.update!(:grants, &Map.put(&1, lease, grant))
      |> Map.update!(:monitors, &Map.put(&1, monitor, {:grant, lease}))
      |> add_active_grant(lease, grant)

    maybe_crash_limiter!(state, :after_pending_persist)
    {lease, state}
  end

  defp enqueue(from, owner, type, repository_id, deadline, now, state) do
    waiter_id = make_ref()
    monitor = Process.monitor(owner)
    timer = schedule_deadline(waiter_id, deadline, now)

    waiter = %{
      from: from,
      owner: owner,
      type: type,
      repository_id: repository_id,
      deadline: deadline,
      monitor: monitor,
      timer: timer
    }

    queue = :queue.in(waiter_id, Map.get(state.queues, repository_id, :queue.new()))

    %{
      state
      | waiters: Map.put(state.waiters, waiter_id, waiter),
        queues: Map.put(state.queues, repository_id, queue),
        monitors: Map.put(state.monitors, monitor, {:waiter, waiter_id})
    }
  end

  defp release_grant(lease, state) do
    case Map.pop(state.grants, lease) do
      {nil, _grants} ->
        state

      {%{monitor: monitor} = grant, grants} ->
        forget_production_grant(state, lease)
        Process.demonitor(monitor, [:flush])

        %{state | grants: grants, monitors: Map.delete(state.monitors, monitor)}
        |> remove_active_grant(lease, grant)
        |> then(&drain_key(grant.repository_id, &1))
    end
  end

  defp drain_key(repository_id, state) do
    queue = Map.get(state.queues, repository_id, :queue.new())

    case :queue.peek(queue) do
      :empty ->
        %{state | queues: Map.delete(state.queues, repository_id)}

      {:value, waiter_id} ->
        case Map.fetch(state.waiters, waiter_id) do
          :error ->
            state
            |> put_queue(repository_id, :queue.drop(queue))
            |> then(&drain_key(repository_id, &1))

          {:ok, waiter} ->
            cond do
              waiter.deadline <= System.monotonic_time(:millisecond) ->
                GenServer.reply(waiter.from, {:error, :deadline_exceeded})

                state
                |> then(&remove_waiter(waiter_id, waiter, &1))
                |> then(&drain_key(repository_id, &1))

              available?(state, waiter.type, repository_id) ->
                Process.cancel_timer(waiter.timer)

                {lease, state} =
                  grant(waiter.owner, waiter.type, repository_id, state, waiter.monitor)

                state = %{
                  state
                  | queues: put_or_delete_queue(state.queues, repository_id, :queue.drop(queue)),
                    waiters: Map.delete(state.waiters, waiter_id)
                }

                GenServer.reply(waiter.from, {:ok, lease})

                if waiter.type == :read do
                  drain_key(repository_id, state)
                else
                  state
                end

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
      | waiters: Map.delete(state.waiters, waiter_id),
        monitors: Map.delete(state.monitors, waiter.monitor)
    }
    |> delete_from_queue(waiter.repository_id, waiter_id)
  end

  defp delete_from_queue(state, repository_id, waiter_id) do
    queue =
      state.queues
      |> Map.get(repository_id, :queue.new())
      |> :queue.to_list()
      |> Enum.reject(&(&1 == waiter_id))
      |> :queue.from_list()

    %{state | queues: put_or_delete_queue(state.queues, repository_id, queue)}
  end

  defp put_queue(state, repository_id, queue) do
    %{state | queues: put_or_delete_queue(state.queues, repository_id, queue)}
  end

  defp put_or_delete_queue(queues, repository_id, queue) do
    if :queue.is_empty(queue),
      do: Map.delete(queues, repository_id),
      else: Map.put(queues, repository_id, queue)
  end

  defp add_active_grant(state, lease, %{type: :read, repository_id: repository_id}) do
    key_state = Map.get(state.keys, repository_id, empty_key_state())
    key_state = %{key_state | reads: MapSet.put(key_state.reads, lease)}
    %{state | keys: Map.put(state.keys, repository_id, key_state)}
  end

  defp add_active_grant(state, lease, %{type: :cleanup, repository_id: repository_id}) do
    key_state = Map.get(state.keys, repository_id, empty_key_state())
    %{state | keys: Map.put(state.keys, repository_id, %{key_state | cleanup: lease})}
  end

  defp remove_active_grant(state, lease, %{type: :read, repository_id: repository_id}) do
    update_key_state(state, repository_id, fn key_state ->
      %{key_state | reads: MapSet.delete(key_state.reads, lease)}
    end)
  end

  defp remove_active_grant(state, lease, %{type: :cleanup, repository_id: repository_id}) do
    update_key_state(state, repository_id, fn key_state ->
      if key_state.cleanup == lease, do: %{key_state | cleanup: nil}, else: key_state
    end)
  end

  defp update_key_state(state, repository_id, fun) do
    key_state = fun.(Map.get(state.keys, repository_id, empty_key_state()))

    keys =
      if is_nil(key_state.cleanup) and MapSet.size(key_state.reads) == 0,
        do: Map.delete(state.keys, repository_id),
        else: Map.put(state.keys, repository_id, key_state)

    %{state | keys: keys}
  end

  defp empty_key_state, do: %{reads: MapSet.new(), cleanup: nil}

  defp schedule_deadline(waiter_id, deadline, now) do
    Process.send_after(
      self(),
      {:deadline, waiter_id},
      min(deadline - now, @deadline_timer_chunk_ms)
    )
  end

  defp recover_production_grants(state) do
    {grants, keys, monitors} =
      registry_transaction(fn registry ->
        {grants, keys, monitors, live_registry} =
          Enum.reduce(registry, {%{}, %{}, %{}, %{}}, fn
            {lease,
             %{owner: owner, repository_id: repository_id, type: type, status: :confirmed} = entry},
            {grants, keys, monitors, live_registry}
            when is_reference(lease) and is_pid(owner) and type in [:read, :cleanup] ->
              key_state = Map.get(keys, repository_id, empty_key_state())

              if Process.alive?(owner) and recoverable?(key_state, type) do
                monitor = Process.monitor(owner)
                grant = Map.put(entry, :monitor, monitor)

                temp_state = %State{keys: keys}
                keys = add_active_grant(temp_state, lease, grant).keys

                {
                  Map.put(grants, lease, grant),
                  keys,
                  Map.put(monitors, monitor, {:grant, lease}),
                  Map.put(live_registry, lease, entry)
                }
              else
                {grants, keys, monitors, live_registry}
              end

            _entry, acc ->
              acc
          end)

        {live_registry, {grants, keys, monitors}}
      end)

    %{state | grants: grants, keys: keys, monitors: monitors}
  end

  defp recoverable?(%{cleanup: nil}, :read), do: true
  defp recoverable?(%{cleanup: nil, reads: reads}, :cleanup), do: MapSet.size(reads) == 0
  defp recoverable?(_key_state, _type), do: false

  defp persist_production_grant(%{production_registry?: true}, lease, grant) do
    entry = Map.take(grant, [:owner, :repository_id, :type, :status])
    registry_transaction(fn registry -> {Map.put(registry, lease, entry), :ok} end)
  end

  defp persist_production_grant(_state, _lease, _grant), do: :ok

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

  defp forget_production_grant(%{production_registry?: true}, lease),
    do: delete_production_grant(lease)

  defp forget_production_grant(_state, _lease), do: :ok

  defp delete_production_grant(lease) do
    registry_transaction(fn registry -> {Map.delete(registry, lease), :ok} end)
  end

  defp registry_transaction(fun) do
    :global.trans(
      {@production_registry_lock, self()},
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

  defp confirm_public_lease(type, lease) do
    maybe_crash_after_internal_reply()

    case call_server({:confirm, lease}) do
      :ok ->
        {:ok, {lease_tag(type), __MODULE__, lease}}

      _error ->
        delete_production_grant(lease)
        release_recovered_grant(__MODULE__, lease)
        {:error, :unavailable}
    end
  end

  defp lease_tag(:read), do: @read_lease_tag
  defp lease_tag(:cleanup), do: @cleanup_lease_tag

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
