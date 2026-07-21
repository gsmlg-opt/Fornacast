defmodule FornacastAPI.RateLimit do
  use GenServer

  defmodule Bucket do
    @enforce_keys [:limit, :remaining, :reset, :used, :resource]
    defstruct [:limit, :remaining, :reset, :used, resource: "core"]
  end

  @anonymous_cap 60
  @authenticated_cap 5_000
  @window_seconds 3_600

  @type identity :: {:token, pos_integer()} | {:ip, String.t()}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def consume(identity, now \\ System.system_time(:second), opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:consume, identity, now})
  end

  def peek(identity, now \\ System.system_time(:second), opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:peek, identity, now})
  end

  @impl true
  def init(opts) do
    anonymous_limit = configured_limit(opts, :anonymous_limit, @anonymous_cap)
    authenticated_limit = configured_limit(opts, :authenticated_limit, @authenticated_cap)
    window_seconds = configured_window(opts)
    table = :ets.new(__MODULE__, [:set, :private])

    {:ok,
     %{
       anonymous_limit: anonymous_limit,
       authenticated_limit: authenticated_limit,
       current_window: nil,
       window_seconds: window_seconds,
       table: table
     }}
  end

  @impl true
  def handle_call({operation, identity, now}, _from, state)
      when operation in [:consume, :peek] and is_integer(now) do
    window_start = div(now, state.window_seconds) * state.window_seconds
    reset = window_start + state.window_seconds
    state = expire_stale_windows(state, window_start)

    used =
      case :ets.lookup(state.table, {identity, window_start}) do
        [{{^identity, ^window_start}, count}] -> count
        [] -> 0
      end

    limit = identity_limit(identity, state)
    reply(operation, state.table, identity, window_start, limit, used, reset, state)
  end

  defp reply(:peek, _table, _identity, _window_start, limit, used, reset, state) do
    {:reply, bucket(limit, used, reset), state}
  end

  defp reply(:consume, table, identity, window_start, limit, used, reset, state)
       when used < limit do
    new_used = used + 1
    true = :ets.insert(table, {{identity, window_start}, new_used})
    {:reply, {:ok, bucket(limit, new_used, reset)}, state}
  end

  defp reply(:consume, _table, _identity, _window_start, limit, used, reset, state) do
    {:reply, {:error, bucket(limit, used, reset)}, state}
  end

  defp configured_limit(opts, option, cap) do
    config_key =
      case option do
        :anonymous_limit -> :anonymous_rate_limit
        :authenticated_limit -> :authenticated_rate_limit
      end

    value = Keyword.get(opts, option, Application.get_env(:fornacast_api, config_key, cap))

    if is_integer(value) and value > 0 and value <= cap do
      value
    else
      raise ArgumentError,
            "#{option} must be a positive integer no greater than #{cap}, got: #{inspect(value)}"
    end
  end

  defp configured_window(opts) do
    value =
      Keyword.get(
        opts,
        :window_seconds,
        Application.get_env(:fornacast_api, :rate_window_seconds, @window_seconds)
      )

    if value == @window_seconds do
      value
    else
      raise ArgumentError, "window_seconds must equal #{@window_seconds}, got: #{inspect(value)}"
    end
  end

  defp identity_limit({:token, id}, state) when is_integer(id) and id > 0,
    do: state.authenticated_limit

  defp identity_limit({:ip, ip}, state) when is_binary(ip) and ip != "",
    do: state.anonymous_limit

  defp expire_stale_windows(%{current_window: nil} = state, window_start) do
    %{state | current_window: window_start}
  end

  defp expire_stale_windows(%{current_window: current_window} = state, window_start)
       when window_start > current_window do
    :ets.select_delete(state.table, [
      {{{:"$1", :"$2"}, :"$3"}, [{:<, :"$2", window_start}], [true]}
    ])

    %{state | current_window: window_start}
  end

  defp expire_stale_windows(state, _older_or_current_window), do: state

  defp bucket(limit, used, reset) do
    %Bucket{
      limit: limit,
      remaining: max(limit - used, 0),
      reset: reset,
      used: used,
      resource: "core"
    }
  end
end
