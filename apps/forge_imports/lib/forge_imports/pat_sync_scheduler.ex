defmodule ForgeImports.PatSyncScheduler do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{User, Organization}
  alias ForgeMirrors.PatConfiguration
  alias ForgeImports.OrganizationPatSettings
  alias Fornacast.Repo

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

  defp sync_if_due(%PatConfiguration{} = config, now) do
    due? =
      is_nil(config.last_sync_at) or
        DateTime.diff(now, config.last_sync_at, :minute) >= config.interval_minutes

    if due? do
      metadata = %{"operation_id" => "pat-scheduler-#{config.id}"}

      result =
        if config.credential_source in [:organization_device, :public] do
          OrganizationPatSettings.sync_organization_configuration(config, metadata)
        else
          with %Organization{} <- Repo.get(Organization, config.organization_id),
               %User{} = owner <- Repo.get(User, config.owner_user_id) do
            OrganizationPatSettings.sync(
              owner,
              config.organization_id,
              to_string(config.lock_version),
              metadata
            )
          end
        end

      case result do
        {:ok, _} -> :ok
        _ -> :error
      end
    end
  end
end
