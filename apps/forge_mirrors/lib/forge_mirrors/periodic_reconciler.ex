defmodule ForgeMirrors.PeriodicReconciler do
  @moduledoc false
  use GenServer

  @default_poll_interval_ms 30_000
  @default_reconcile_interval_seconds 3_600
  @default_batch_size 25

  def start_link(options) when is_list(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc false
  def run_once(now \\ DateTime.utc_now(:second), options \\ []) do
    ForgeMirrors.schedule_due_reconciliations(
      now,
      Keyword.get(options, :batch_size, @default_batch_size),
      Keyword.get(options, :reconcile_interval_seconds, @default_reconcile_interval_seconds)
    )
  end

  @impl true
  def init(options) do
    state = %{
      enabled: Keyword.get(options, :enabled, config(:periodic_reconciler_enabled, true)),
      interval_ms:
        Keyword.get(
          options,
          :interval_ms,
          config(:periodic_reconciler_interval_ms, @default_poll_interval_ms)
        ),
      runner: Keyword.get(options, :runner, fn -> run_once() end)
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

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)

  defp config(key, default), do: Application.get_env(:forge_mirrors, key, default)
end
