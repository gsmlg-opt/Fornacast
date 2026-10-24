defmodule ForgeGitHub.OrganizationCredential do
  @moduledoc "Renews organization-owned GitHub App user grants before trusted checkout."
  alias ForgeAccounts.OrganizationGitHubCredentials

  def with_credential(scope, callback, opts \\ []) when is_function(callback, 2) do
    with :ok <- ensure_fresh(scope, opts),
         do: OrganizationGitHubCredentials.with_credential(scope, callback)
  end

  def ensure_fresh(scope, opts \\ []) do
    device_opts = Keyword.get(opts, :device_flow_options, [])

    exchange = fn refresh, client_id ->
      ForgeGitHub.DeviceFlow.refresh(refresh, Keyword.put(device_opts, :client_id, client_id))
    end

    await_refresh(scope, exchange, opts, 20)
  end

  defp await_refresh(scope, exchange, opts, remaining) do
    case OrganizationGitHubCredentials.refresh_credential(scope, exchange, opts) do
      {:error, :refresh_in_progress} when remaining > 0 ->
        Process.sleep(100)
        await_refresh(scope, exchange, opts, remaining - 1)

      result ->
        result
    end
  end
end
