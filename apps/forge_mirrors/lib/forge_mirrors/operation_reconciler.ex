defmodule ForgeMirrors.OperationReconciler do
  @moduledoc false
  use GenServer

  @default_interval_ms 30_000

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc false
  def run_once(now \\ DateTime.utc_now(:second)), do: ForgeMirrors.recover_expired_operations(now)

  @impl true
  def init(:ok) do
    state = %{enabled: config(:operation_reconciler_enabled, true)}
    if state.enabled, do: schedule()
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = run_once()
    schedule()
    {:noreply, state}
  end

  defp schedule do
    Process.send_after(
      self(),
      :tick,
      config(:operation_reconciler_interval_ms, @default_interval_ms)
    )
  end

  defp config(key, default), do: Application.get_env(:forge_mirrors, key, default)
end
