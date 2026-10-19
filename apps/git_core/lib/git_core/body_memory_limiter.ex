defmodule GitCore.BodyMemoryLimiter do
  @moduledoc "Monitored, node-wide weighted FIFO admission for Git request memory."
  use GenServer

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def acquire(bytes, timeout_ms \\ 250)
      when is_integer(bytes) and bytes >= 0 and is_integer(timeout_ms) and timeout_ms in 0..250 do
    lease = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      GenServer.call(__MODULE__, {:acquire, lease, bytes, deadline}, max(timeout_ms, 1))
    catch
      :exit, {:timeout, _} ->
        # Same-sender ordering makes this cancel a queued request or a late grant.
        GenServer.cast(__MODULE__, {:release, lease})
        {:error, :busy}

      :exit, _ ->
        {:error, :unavailable}
    end
  end

  def release(lease) do
    GenServer.cast(__MODULE__, {:release, lease})
    :ok
  end

  @impl true
  def init(_), do: {:ok, %{requests: %{}, queue: :queue.new(), used: 0}}

  @impl true
  def handle_call({:acquire, lease, bytes, deadline}, from, state) do
    state = prune_dead(state)

    cond do
      bytes > GitCore.Limits.get(:body_memory_bytes) ->
        {:reply, {:error, :too_large}, state}

      :queue.is_empty(state.queue) and fits?(state, bytes) ->
        request = %{
          owner: elem(from, 0),
          monitor: Process.monitor(elem(from, 0)),
          bytes: bytes,
          status: :granted
        }

        {:reply, {:ok, lease},
         %{state | requests: Map.put(state.requests, lease, request), used: state.used + bytes}}

      deadline <= System.monotonic_time(:millisecond) ->
        {:reply, {:error, :busy}, state}

      true ->
        timer =
          Process.send_after(
            self(),
            {:expired, lease},
            max(deadline - System.monotonic_time(:millisecond), 0)
          )

        request = %{
          owner: elem(from, 0),
          monitor: Process.monitor(elem(from, 0)),
          bytes: bytes,
          status: :waiting,
          from: from,
          deadline: deadline,
          timer: timer
        }

        {:noreply,
         %{
           state
           | requests: Map.put(state.requests, lease, request),
             queue: :queue.in(lease, state.queue)
         }}
    end
  end

  @impl true
  def handle_cast({:release, lease}, state), do: {:noreply, state |> remove(lease) |> drain()}

  @impl true
  def handle_info({:expired, lease}, state) do
    case state.requests[lease] do
      %{status: :waiting, from: from} ->
        GenServer.reply(from, {:error, :busy})
        {:noreply, state |> remove(lease) |> drain()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    state =
      Enum.reduce(state.requests, state, fn {lease, request}, acc ->
        if request.monitor == monitor, do: remove(acc, lease), else: acc
      end)

    {:noreply, drain(state)}
  end

  defp fits?(state, bytes), do: bytes + state.used <= GitCore.Limits.get(:body_memory_bytes)

  defp prune_dead(state) do
    Enum.reduce(state.requests, state, fn {lease, request}, acc ->
      if Process.alive?(request.owner), do: acc, else: remove(acc, lease)
    end)
    |> drain()
  end

  defp remove(state, lease) do
    case Map.pop(state.requests, lease) do
      {nil, _} ->
        state

      {%{status: :granted} = request, requests} ->
        Process.demonitor(request.monitor, [:flush])
        %{state | requests: requests, used: state.used - request.bytes}

      {request, requests} ->
        Process.demonitor(request.monitor, [:flush])
        Process.cancel_timer(request.timer)
        %{state | requests: requests, queue: :queue.filter(&(&1 != lease), state.queue)}
    end
  end

  defp drain(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, lease}, queue} ->
        case state.requests[lease] do
          nil ->
            drain(%{state | queue: queue})

          request ->
            cond do
              not Process.alive?(request.owner) ->
                state |> remove(lease) |> drain()

              request.deadline <= System.monotonic_time(:millisecond) ->
                GenServer.reply(request.from, {:error, :busy})
                state |> remove(lease) |> drain()

              fits?(state, request.bytes) ->
                Process.cancel_timer(request.timer)
                GenServer.reply(request.from, {:ok, lease})

                request =
                  request |> Map.drop([:from, :deadline, :timer]) |> Map.put(:status, :granted)

                drain(%{
                  state
                  | queue: queue,
                    requests: Map.put(state.requests, lease, request),
                    used: state.used + request.bytes
                })

              true ->
                state
            end
        end
    end
  end
end
