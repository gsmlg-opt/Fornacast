defmodule ForgeMirrors.OutboxDispatcher do
  @moduledoc false
  use GenServer

  alias Fornacast.DomainOutbox

  @default_interval_ms 1_000
  @default_lease_seconds 30
  @default_batch_size 25

  def start_link(options) when is_list(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc false
  def dispatch_once(owner, now \\ DateTime.utc_now(:second), options \\ [])
      when is_binary(owner) and is_list(options) do
    lease_seconds = Keyword.get(options, :lease_seconds, @default_lease_seconds)
    batch_size = Keyword.get(options, :batch_size, @default_batch_size)

    with {:ok, events} <- DomainOutbox.claim_batch(owner, now, lease_seconds, batch_size) do
      results = Enum.map(events, &dispatch_event(&1, now))
      {:ok, results}
    end
  end

  @impl true
  def init(options) do
    owner = "outbox-#{node()}-#{System.unique_integer([:positive])}"

    state = %{
      enabled: Keyword.get(options, :enabled, config(:outbox_dispatcher_enabled, true)),
      interval_ms:
        Keyword.get(
          options,
          :interval_ms,
          config(:outbox_dispatcher_interval_ms, @default_interval_ms)
        ),
      runner: Keyword.get(options, :runner, fn -> dispatch_once(owner) end)
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {:ok, pid} =
      Task.Supervisor.start_child(ForgeMirrors.TaskSupervisor, fn ->
        _ = state.runner.()
      end)

    {:noreply, Map.put(state, :task_ref, Process.monitor(pid))}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref} = state) do
    schedule(state.interval_ms)
    {:noreply, Map.delete(state, :task_ref)}
  end

  defp dispatch_event(event, now) do
    case ForgeMirrors.materialize_outbox_event(event) do
      {:ok, operations} ->
        case DomainOutbox.ack(event, now) do
          {:ok, _acked} -> {:ok, event.event_id, Enum.map(operations, & &1.id)}
          error -> error
        end

      _error ->
        DomainOutbox.release(event, now, DateTime.add(now, 5, :second))
    end
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  defp config(key, default), do: Application.get_env(:forge_mirrors, key, default)
end
