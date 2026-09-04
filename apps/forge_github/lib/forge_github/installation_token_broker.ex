defmodule ForgeGitHub.InstallationTokenBroker do
  @moduledoc "A bounded in-memory, single-flight cache for GitHub installation tokens."

  use GenServer

  alias ForgeGitHub.{AppAuthentication, AppConfig, InstallationToken, InstallationTokenScope}

  @default_refresh_before_seconds 300
  @default_max_entries 256
  @default_max_inflight 16
  @default_max_waiters_per_key 100
  @default_max_waiters 500
  @default_waiter_timeout_ms 24_000
  @call_timeout 25_000

  @type fetch_error :: :busy | :invalid_scope | :invalidated | :revoked | :timeout | :unavailable

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec fetch(pos_integer(), map()) :: InstallationToken.t() | {:error, fetch_error() | term()}
  def fetch(installation_id, scope \\ %{})

  def fetch(installation_id, scope) when is_integer(installation_id),
    do: fetch(__MODULE__, installation_id, scope)

  @spec fetch(GenServer.server(), pos_integer(), map()) ::
          InstallationToken.t() | {:error, fetch_error() | term()}
  def fetch(server, installation_id), do: fetch(server, installation_id, %{})

  def fetch(server, installation_id, scope) do
    with true <- valid_installation_id?(installation_id),
         {:ok, canonical_scope, scope_key} <- InstallationTokenScope.canonical(scope) do
      GenServer.call(server, {:fetch, installation_id, canonical_scope, scope_key}, @call_timeout)
    else
      _invalid -> {:error, :invalid_scope}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec invalidate(pos_integer()) :: :ok | {:error, :invalid_installation}
  def invalidate(installation_id) when is_integer(installation_id),
    do: invalidate(__MODULE__, installation_id)

  @spec invalidate(GenServer.server(), pos_integer()) :: :ok | {:error, :invalid_installation}
  def invalidate(server, installation_id) do
    if valid_installation_id?(installation_id),
      do: GenServer.call(server, {:invalidate, installation_id}),
      else: {:error, :invalid_installation}
  end

  @spec invalidate_unauthorized(GenServer.server(), pos_integer()) ::
          :ok | {:error, :invalid_installation}
  def invalidate_unauthorized(installation_id) when is_integer(installation_id),
    do: invalidate(__MODULE__, installation_id)

  def invalidate_unauthorized(server, installation_id),
    do: invalidate(server, installation_id)

  @spec revoke(pos_integer()) :: :ok | {:error, :invalid_installation}
  def revoke(installation_id) when is_integer(installation_id),
    do: revoke(__MODULE__, installation_id)

  @spec revoke(GenServer.server(), pos_integer()) :: :ok | {:error, :invalid_installation}
  def revoke(server, installation_id) do
    if valid_installation_id?(installation_id),
      do: GenServer.call(server, {:revoke, installation_id}),
      else: {:error, :invalid_installation}
  end

  @impl true
  def init(opts) do
    max_entries = positive_option!(opts, :max_entries, @default_max_entries, 4_096)
    max_inflight = positive_option!(opts, :max_inflight, @default_max_inflight, 128)

    max_waiters_per_key =
      positive_option!(opts, :max_waiters_per_key, @default_max_waiters_per_key, 1_024)

    max_waiters = positive_option!(opts, :max_waiters, @default_max_waiters, 4_096)

    waiter_timeout_ms =
      positive_option!(
        opts,
        :waiter_timeout_ms,
        @default_waiter_timeout_ms,
        @call_timeout - 1_000
      )

    if max_waiters_per_key > max_waiters do
      raise ArgumentError, "invalid installation token broker configuration"
    end

    refresh_before_seconds =
      positive_option!(opts, :refresh_before_seconds, @default_refresh_before_seconds, 3_600)

    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    fetcher = Keyword.get(opts, :fetcher, &default_fetch/2)

    unless (is_atom(task_supervisor) or is_pid(task_supervisor)) and is_function(now, 0) and
             is_function(fetcher, 2) do
      raise ArgumentError, "invalid installation token broker configuration"
    end

    {:ok,
     %{
       cache: %{},
       inflight: %{},
       waiter_index: %{},
       generations: %{},
       revoked: MapSet.new(),
       sequence: 0,
       task_supervisor: task_supervisor,
       now: now,
       fetcher: fetcher,
       refresh_before_seconds: refresh_before_seconds,
       max_entries: max_entries,
       max_inflight: max_inflight,
       max_waiters_per_key: max_waiters_per_key,
       max_waiters: max_waiters,
       waiter_timeout_ms: waiter_timeout_ms
     }}
  end

  @impl true
  def handle_call({:fetch, installation_id, scope, scope_key}, from, state) do
    key = {installation_id, scope_key}

    cond do
      MapSet.member?(state.revoked, installation_id) ->
        {:reply, {:error, :revoked}, state}

      cached = fresh_cached_token(state, key) ->
        {:reply, cached.token, state}

      inflight = Map.get(state.inflight, key) ->
        if waiter_capacity?(state, inflight) do
          {:noreply, add_waiter(state, key, from)}
        else
          {:reply, {:error, :busy}, state}
        end

      map_size(state.inflight) >= state.max_inflight or not waiter_capacity?(state, nil) ->
        {:reply, {:error, :busy}, drop_cache_key(state, key)}

      true ->
        state = drop_cache_key(state, key)
        generation = Map.get(state.generations, installation_id, 0)

        case start_fetch_task(state, installation_id, scope) do
          {:ok, task} ->
            inflight = %{
              task: task,
              waiters: %{},
              generation: generation,
              installation_id: installation_id
            }

            state = put_in(state.inflight[key], inflight)
            {:noreply, add_waiter(state, key, from)}

          {:error, :busy} ->
            {:reply, {:error, :busy}, state}
        end
    end
  end

  def handle_call({:invalidate, installation_id}, _from, state) do
    state = invalidate_state(state, installation_id, false)
    state = retire_installation(state, installation_id, :invalidated)
    {:reply, :ok, state}
  end

  def handle_call({:revoke, installation_id}, _from, state) do
    state = invalidate_state(state, installation_id, true)
    state = retire_installation(state, installation_id, :revoked)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({reference, result}, state) when is_reference(reference) do
    case pop_inflight_by_reference(state, reference) do
      {:error, :unknown, state} ->
        {:noreply, remove_waiter(state, reference, nil)}

      {:ok, key, inflight, state} ->
        Process.demonitor(reference, [:flush])
        {waiters, state} = take_waiters(state, inflight)
        now = current_time(state)

        case accepted_result(result, inflight, state, now) do
          {:ok, token} ->
            state = cache_token(state, key, token)
            reply_waiters(waiters, token)
            {:noreply, state}

          {:error, reason} ->
            reply_waiters(waiters, {:error, reason})
            {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case pop_inflight_by_reference(state, reference) do
      {:error, :unknown, state} ->
        {:noreply, remove_waiter(state, reference, nil)}

      {:ok, _key, inflight, state} ->
        {waiters, state} = take_waiters(state, inflight)
        reply_waiters(waiters, {:error, :unavailable})
        {:noreply, state}
    end
  end

  def handle_info({:waiter_expired, monitor}, state) when is_reference(monitor) do
    {:noreply, remove_waiter(state, monitor, {:error, :timeout})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(_reason, [_process_dictionary, state]) do
    [
      data: [
        {~c"State",
         %{
           cache_entries: map_size(state.cache),
           cache_keys: Map.keys(state.cache),
           inflight_entries: map_size(state.inflight),
           inflight_keys: Map.keys(state.inflight),
           waiter_count: map_size(state.waiter_index),
           max_waiters: state.max_waiters,
           max_waiters_per_key: state.max_waiters_per_key,
           revoked_installations: MapSet.to_list(state.revoked)
         }}
      ]
    ]
  end

  defp default_fetch(installation_id, scope) do
    with {:ok, config} <- AppConfig.fetch(),
         {:ok, token} <-
           AppAuthentication.create_installation_token(config, installation_id, scope) do
      token
    else
      {:error, :disabled} -> {:error, :not_configured}
      {:error, :invalid_configuration} -> {:error, :not_configured}
      {:error, error} -> {:error, error}
    end
  end

  defp start_fetch_task(state, installation_id, scope) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        state.fetcher.(installation_id, scope)
      end)

    {:ok, task}
  rescue
    _exception -> {:error, :busy}
  catch
    :exit, _reason -> {:error, :busy}
  end

  defp accepted_result(result, inflight, state, now) do
    current_generation = Map.get(state.generations, inflight.installation_id, 0)

    cond do
      MapSet.member?(state.revoked, inflight.installation_id) ->
        {:error, :revoked}

      current_generation != inflight.generation ->
        {:error, :invalidated}

      true ->
        validate_fetch_result(result, now)
    end
  end

  defp validate_fetch_result({:ok, %InstallationToken{} = token}, now),
    do: validate_fetch_result(token, now)

  defp validate_fetch_result(%InstallationToken{} = token, now) do
    if DateTime.after?(token.expires_at, now), do: {:ok, token}, else: {:error, :unavailable}
  end

  defp validate_fetch_result({:error, reason}, _now), do: {:error, reason}
  defp validate_fetch_result(_result, _now), do: {:error, :unavailable}

  defp fresh_cached_token(state, key) do
    with %{token: %InstallationToken{} = token} = cached <- Map.get(state.cache, key),
         refresh_at <- DateTime.add(token.expires_at, -state.refresh_before_seconds),
         true <- DateTime.after?(refresh_at, current_time(state)) do
      cached
    else
      _missing_or_stale -> nil
    end
  end

  defp cache_token(state, key, token) do
    sequence = state.sequence + 1
    state = %{state | sequence: sequence}

    cache =
      if map_size(state.cache) >= state.max_entries and not Map.has_key?(state.cache, key) do
        {oldest_key, _value} = Enum.min_by(state.cache, fn {_key, value} -> value.sequence end)
        Map.delete(state.cache, oldest_key)
      else
        state.cache
      end

    %{state | cache: Map.put(cache, key, %{token: token, sequence: sequence})}
  end

  defp drop_cache_key(state, key), do: %{state | cache: Map.delete(state.cache, key)}

  defp invalidate_state(state, installation_id, revoked?) do
    cache =
      Map.reject(state.cache, fn {{cached_installation_id, _scope}, _value} ->
        cached_installation_id == installation_id
      end)

    generations = Map.update(state.generations, installation_id, 1, &(&1 + 1))

    revoked =
      if revoked?,
        do: MapSet.put(state.revoked, installation_id),
        else: state.revoked

    %{state | cache: cache, generations: generations, revoked: revoked}
  end

  defp pop_inflight_by_reference(state, reference) do
    case Enum.find(state.inflight, fn {_key, inflight} -> inflight.task.ref == reference end) do
      nil ->
        {:error, :unknown, state}

      {key, inflight} ->
        {:ok, key, inflight, %{state | inflight: Map.delete(state.inflight, key)}}
    end
  end

  defp waiter_capacity?(state, nil), do: map_size(state.waiter_index) < state.max_waiters

  defp waiter_capacity?(state, inflight) do
    map_size(state.waiter_index) < state.max_waiters and
      map_size(inflight.waiters) < state.max_waiters_per_key
  end

  defp add_waiter(state, key, from) do
    {pid, _tag} = from
    monitor = Process.monitor(pid)
    timer = Process.send_after(self(), {:waiter_expired, monitor}, state.waiter_timeout_ms)
    waiter = %{from: from, monitor: monitor, timer: timer}

    state
    |> put_in([:inflight, key, :waiters, monitor], waiter)
    |> put_in([:waiter_index, monitor], key)
  end

  defp remove_waiter(state, monitor, reply) do
    case Map.pop(state.waiter_index, monitor) do
      {nil, _index} ->
        state

      {key, waiter_index} ->
        inflight = Map.fetch!(state.inflight, key)
        {waiter, waiters} = Map.pop(inflight.waiters, monitor)
        cleanup_waiter(waiter)
        if reply, do: GenServer.reply(waiter.from, reply)

        state = %{state | waiter_index: waiter_index}

        if map_size(waiters) == 0 do
          retire_task(inflight.task)
          %{state | inflight: Map.delete(state.inflight, key)}
        else
          put_in(state.inflight[key].waiters, waiters)
        end
    end
  end

  defp take_waiters(state, inflight) do
    waiters = Map.values(inflight.waiters)

    waiter_index =
      Enum.reduce(waiters, state.waiter_index, fn waiter, index ->
        cleanup_waiter(waiter)
        Map.delete(index, waiter.monitor)
      end)

    {waiters, %{state | waiter_index: waiter_index}}
  end

  defp retire_installation(state, installation_id, reason) do
    state =
      state.inflight
      |> Enum.filter(fn {_key, inflight} -> inflight.installation_id == installation_id end)
      |> Enum.reduce(state, fn {key, inflight}, acc ->
        {waiters, acc} = take_waiters(acc, inflight)
        reply_waiters(waiters, {:error, reason})
        retire_task(inflight.task)
        %{acc | inflight: Map.delete(acc.inflight, key)}
      end)

    %{state | generations: Map.delete(state.generations, installation_id)}
  end

  defp cleanup_waiter(waiter) do
    Process.cancel_timer(waiter.timer, async: false, info: false)
    Process.demonitor(waiter.monitor, [:flush])
  end

  defp retire_task(task), do: Task.shutdown(task, :brutal_kill)

  defp reply_waiters(waiters, result),
    do: Enum.each(waiters, &GenServer.reply(&1.from, result))

  defp current_time(state) do
    case state.now.() do
      %DateTime{time_zone: "Etc/UTC"} = datetime -> DateTime.truncate(datetime, :second)
      _invalid -> DateTime.utc_now(:second)
    end
  rescue
    _exception -> DateTime.utc_now(:second)
  catch
    _kind, _reason -> DateTime.utc_now(:second)
  end

  defp positive_option!(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 1 and value <= maximum -> value
      _invalid -> raise ArgumentError, "invalid installation token broker configuration"
    end
  end

  defp valid_installation_id?(id),
    do: is_integer(id) and id in 1..9_223_372_036_854_775_807
end
