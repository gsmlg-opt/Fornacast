defmodule ForgeImports.PatSyncScheduler do
  @moduledoc false
  use GenServer

  import Ecto.Query

  alias ForgeAccounts.{User, Organization}
  alias ForgeMirrors.{PatConfiguration, PatSettings}
  alias ForgeImports.OrganizationPatSettings
  alias Fornacast.Repo

  @default_interval_ms 30_000

  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc false
  def run_once(now \\ DateTime.utc_now(:second)) do
    now = DateTime.truncate(now, :second)

    PatConfiguration
    |> where([config], config.enabled == true and config.paused == false)
    |> where([config], config.trigger_mode == "interval")
    |> Repo.all()
    |> Enum.each(&sync_if_due(&1, now))

    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      enabled:
        Keyword.get(
          opts,
          :enabled,
          Application.get_env(:forge_imports, :pat_sync_scheduler_enabled, true)
        ),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      runner: Keyword.get(opts, :runner, &run_once/0)
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = Task.Supervisor.start_child(ForgeImports.TaskSupervisor, state.runner)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp sync_if_due(%PatConfiguration{} = config, now) do
    due? =
      is_nil(config.last_sync_at) or
        DateTime.diff(now, config.last_sync_at, :minute) >= config.interval_minutes

    if due? do
      with %Organization{} = _organization <- Repo.get(Organization, config.organization_id),
           %User{} = owner <- Repo.get(User, config.owner_user_id),
           {:ok, _} <-
             PatSettings.mark_sync(owner, config.organization_id, "running", %{
               "source" => "pat_scheduler"
             }),
           {:ok, _} <-
             OrganizationPatSettings.sync(
               owner,
               config.organization_id,
               to_string(config.lock_version),
               %{"source" => "pat_scheduler"}
             ) do
        :ok
      else
        %User{} = owner ->
          _ =
            PatSettings.mark_sync(owner, config.organization_id, "failed", %{
              "source" => "pat_scheduler"
            })

          :error

        _ ->
          :error
      end
    end
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
