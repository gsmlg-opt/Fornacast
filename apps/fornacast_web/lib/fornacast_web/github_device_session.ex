defmodule FornacastWeb.GitHubDeviceSession do
  @moduledoc false

  alias FornacastWeb.UserSession
  alias Phoenix.SessionProcess

  def run(conn, operation) do
    transaction(conn, fn dispatch -> dispatch.(operation) end)
  end

  def view(conn) do
    case run(conn, :view) do
      {:ok, view} -> view
      {:error, _reason} -> nil
    end
  end

  def transaction(conn, callback) do
    user_id = conn.assigns.current_user.id
    session_id = Plug.Conn.get_session(conn, :session_id)

    UserSession.with_user_lock(user_id, fn ->
      case SessionProcess.call(session_id, {:owner, user_id}) do
        {:ok, _owner} ->
          callback.(fn operation ->
            SessionProcess.call(session_id, {:github_device, user_id, operation})
          end)

        {:error, _reason} ->
          {:error, :authorization_unavailable}
      end
    end)
  end
end
