defmodule FornacastWeb.OrganizationGitHubDeviceSession do
  @moduledoc false
  alias FornacastWeb.UserSession
  alias Phoenix.SessionProcess

  def run(conn, organization_id, operation),
    do: transaction(conn, organization_id, fn dispatch -> dispatch.(operation) end)

  def view(conn, organization_id) do
    case run(conn, organization_id, :view) do
      {:ok, view} -> view
      _ -> nil
    end
  end

  def transaction(conn, organization_id, callback) do
    user_id = conn.assigns.current_user.id
    session_id = Plug.Conn.get_session(conn, :session_id)

    UserSession.with_user_lock(user_id, fn ->
      case SessionProcess.call(session_id, {:owner, user_id}) do
        {:ok, _} ->
          callback.(fn operation ->
            SessionProcess.call(
              session_id,
              {:organization_github_device, user_id, organization_id, operation}
            )
          end)

        _ ->
          {:error, :authorization_unavailable}
      end
    end)
  end
end
