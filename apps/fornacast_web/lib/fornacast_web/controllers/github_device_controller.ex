defmodule FornacastWeb.GitHubDeviceController do
  use FornacastWeb, :controller

  alias ForgeAccounts.User
  alias ForgeGitHub.DeviceFlow
  alias FornacastWeb.{GitHubDeviceSession, GitHubSettingsHTML, RequestMetadata}

  plug :require_active_user

  def create(conn, _params) do
    with {:ok, id} <- GitHubDeviceSession.run(conn, :begin) do
      client_id = provider(conn).client_id()

      result =
        with {:ok, checked} <-
               ForgeAccounts.validate_github_link_request(
                 conn.assigns.current_user,
                 RequestMetadata.from_conn(conn)
               ),
             {:ok, grant} <- provider(conn).start(client_id: client_id) do
          GitHubDeviceSession.run(conn, {:authorize, id, grant, client_id, checked.references})
        end

      case result do
        :ok -> :ok
        {:error, reason} -> GitHubDeviceSession.run(conn, {:fail, id, safe_reason(reason)})
      end

      conn |> put_status(:see_other) |> redirect(to: "/settings/github/device/legacy")
    else
      {:error, _reason} ->
        send_resp(conn, 503, "GitHub authorization is temporarily unavailable.")
    end
  end

  def poll(conn, %{"attempt_id" => id}) do
    result =
      case GitHubDeviceSession.run(conn, {:claim, id}) do
        {:ok, claim} -> exchange(conn, id, claim)
        {:wait, interval} -> {:ok, %{status: "pending", interval: interval}}
        {:done, :complete} -> {:ok, complete()}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{
          status: "failed",
          message: GitHubSettingsHTML.device_message(safe_reason(reason))
        })
    end
  end

  def cancel(conn, %{"attempt_id" => id}) do
    GitHubDeviceSession.run(conn, {:cancel, id})
    conn |> put_status(:see_other) |> redirect(to: "/settings/github")
  end

  defp exchange(conn, id, claim) do
    case provider(conn).poll(claim.device_code, client_id: claim.client_id) do
      {:ok, token} ->
        finish(conn, id, claim.id, token)

      {:error, :authorization_pending} ->
        pending(conn, id, claim.id, 0)

      {:error, {:slow_down, interval}} ->
        pending(conn, id, claim.id, interval)

      {:error, reason} ->
        GitHubDeviceSession.run(conn, {:fail, id, safe_reason(reason)})
        {:error, reason}
    end
  end

  defp pending(conn, id, claim_id, requested_interval) do
    interval =
      case GitHubDeviceSession.view(conn) do
        %{interval: interval} -> interval
        _ -> 5
      end

    interval =
      if requested_interval > 0, do: max(requested_interval, interval + 5), else: interval

    with :ok <- GitHubDeviceSession.run(conn, {:pending, id, claim_id, interval}) do
      {:ok, %{status: "pending", interval: interval}}
    end
  end

  defp finish(conn, id, claim, token) do
    GitHubDeviceSession.transaction(conn, fn dispatch ->
      before_save = fn ->
        dispatch.({:prepare_save, id, claim})
      end

      with {:ok, references} <- dispatch.({:check, id, claim}),
           {:ok, _view} <-
             imports(conn).link_github_device_account(
               conn.assigns.current_user,
               token,
               RequestMetadata.from_conn(conn),
               references,
               before_save: before_save
             ),
           :ok <- dispatch.({:complete, id, claim}) do
        {:ok, complete()}
      else
        {:error, reason} ->
          dispatch.({:fail, id, safe_reason(reason)})
          {:error, reason}
      end
    end)
  end

  defp complete, do: %{status: "complete", redirect: "/settings/github"}
  defp provider(conn), do: conn.private[:github_device_provider] || DeviceFlow
  defp imports(conn), do: conn.private[:forge_imports] || ForgeImports

  defp error_status(:expired_token), do: :gone
  defp error_status(reason) when reason in [:stale, :not_found, :forbidden], do: :not_found
  defp error_status(:access_denied), do: :forbidden
  defp error_status(_), do: :unprocessable_entity

  defp safe_reason(reason)
       when reason in [
              :device_flow_disabled,
              :access_denied,
              :expired_token,
              :incorrect_client_credentials,
              :stale,
              :already_linked,
              :credential_service_unavailable,
              :authorization_unavailable,
              :primary_rate_limit,
              :secondary_rate_limit
            ],
       do: reason

  defp safe_reason(_), do: :authorization_unavailable

  defp require_active_user(
         %{assigns: %{current_user: %User{kind: :user, state: :active}}} = conn,
         _
       ),
       do: conn

  defp require_active_user(conn, _), do: conn |> redirect(to: "/login") |> halt()
end
