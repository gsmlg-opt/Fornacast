defmodule GitCore.Cache do
  @moduledoc false

  use GenServer

  @max_entries 512
  @max_bytes 67_108_864
  @max_value_bytes 1_048_576
  @idle_expiration_ms 900_000

  defmodule State do
    @moduledoc false
    defstruct table: nil,
              clock: nil,
              max_entries: nil,
              max_bytes: nil,
              max_value_bytes: nil,
              idle_expiration_ms: nil,
              count: 0,
              used_bytes: 0,
              next_sequence: 0
  end

  def start_link(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    start_opts = if is_nil(server), do: [], else: [name: server]
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  def fetch(key, computation, opts \\ []) when is_function(computation, 0) do
    server = Keyword.get(opts, :server, __MODULE__)

    case cache_call(server, {:lookup, key}) do
      {:hit, value} ->
        {:ok, value}

      _miss_or_failure ->
        result = computation.()
        cache_success(server, key, result)
        result
    end
  end

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    max_entries = Keyword.get(opts, :max_entries, @max_entries)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    max_value_bytes = Keyword.get(opts, :max_value_bytes, @max_value_bytes)
    idle_expiration_ms = Keyword.get(opts, :idle_expiration_ms, @idle_expiration_ms)

    validate_options!(
      clock,
      max_entries,
      max_bytes,
      max_value_bytes,
      idle_expiration_ms
    )

    table = :ets.new(__MODULE__, [:set, :private])

    {:ok,
     %State{
       table: table,
       clock: clock,
       max_entries: max_entries,
       max_bytes: max_bytes,
       max_value_bytes: max_value_bytes,
       idle_expiration_ms: idle_expiration_ms
     }}
  end

  @impl true
  def handle_call({:lookup, key}, _from, state) do
    now = state.clock.()
    state = purge_expired(state, now)

    case :ets.lookup(state.table, key) do
      [{^key, value, size, _sequence, _last_access_at}] ->
        sequence = state.next_sequence
        true = :ets.insert(state.table, {key, value, size, sequence, now})
        {:reply, {:hit, value}, %{state | next_sequence: sequence + 1}}

      [] ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:put, key, value}, _from, state) do
    now = state.clock.()
    state = purge_expired(state, now)
    value_size = :erlang.external_size(value)

    state =
      if value_size <= state.max_value_bytes do
        replace_entry(state, key, value, now)
      else
        state
      end

    {:reply, :ok, state}
  end

  defp cache_success(server, key, {:ok, value}) do
    try do
      if :erlang.external_size(value) <= @max_value_bytes do
        GenServer.call(server, {:put, key, value})
      else
        :ok
      end
    catch
      _kind, _reason -> :ok
    end
  end

  defp cache_success(_server, _key, _result), do: :ok

  defp cache_call(server, message) do
    try do
      GenServer.call(server, message)
    catch
      _kind, _reason -> :cache_failure
    end
  end

  defp replace_entry(state, key, value, now) do
    state = remove_existing(state, key)
    size = :erlang.external_size({key, value})

    if size > state.max_bytes do
      state
    else
      sequence = state.next_sequence
      true = :ets.insert(state.table, {key, value, size, sequence, now})

      state
      |> Map.put(:count, state.count + 1)
      |> Map.put(:used_bytes, state.used_bytes + size)
      |> Map.put(:next_sequence, sequence + 1)
      |> evict_until_within_bounds()
    end
  end

  defp remove_existing(state, key) do
    case :ets.take(state.table, key) do
      [{^key, _value, size, _sequence, _last_access_at}] ->
        %{state | count: state.count - 1, used_bytes: state.used_bytes - size}

      [] ->
        state
    end
  end

  defp purge_expired(state, now) do
    Enum.reduce(:ets.tab2list(state.table), state, fn
      {key, _value, _size, _sequence, last_access_at}, state ->
        if now - last_access_at >= state.idle_expiration_ms do
          remove_existing(state, key)
        else
          state
        end
    end)
  end

  defp evict_until_within_bounds(state)
       when state.count <= state.max_entries and state.used_bytes <= state.max_bytes,
       do: state

  defp evict_until_within_bounds(state) do
    {key, _value, _size, _sequence, _last_access_at} =
      state.table
      |> :ets.tab2list()
      |> Enum.min_by(&elem(&1, 3))

    state
    |> remove_existing(key)
    |> evict_until_within_bounds()
  end

  defp validate_options!(
         clock,
         max_entries,
         max_bytes,
         max_value_bytes,
         idle_expiration_ms
       ) do
    if not is_function(clock, 0) do
      raise ArgumentError, "cache clock must be a zero-arity function"
    end

    if not (is_integer(max_entries) and max_entries in 1..@max_entries) do
      raise ArgumentError, "cache entry limit must be between 1 and #{@max_entries}"
    end

    if not (is_integer(max_bytes) and max_bytes in 0..@max_bytes) do
      raise ArgumentError, "cache byte limit must be between 0 and #{@max_bytes}"
    end

    if not (is_integer(max_value_bytes) and max_value_bytes in 0..@max_value_bytes) do
      raise ArgumentError,
            "cache value limit must be between 0 and #{@max_value_bytes}"
    end

    if not (is_integer(idle_expiration_ms) and
              idle_expiration_ms in 0..@idle_expiration_ms) do
      raise ArgumentError,
            "cache idle expiration must be between 0 and #{@idle_expiration_ms} milliseconds"
    end
  end
end
