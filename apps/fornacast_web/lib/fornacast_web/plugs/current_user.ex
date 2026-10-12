defmodule FornacastWeb.Plugs.CurrentUser do
  import Plug.Conn

  alias ForgeAccounts.User
  alias FornacastWeb.UserSession

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      conn
      |> get_session(:user_id)
      |> case do
        nil -> nil
        user_id -> ForgeAccounts.get_session_user(user_id)
      end

    case user do
      %User{state: :active} ->
        case UserSession.hydrate(conn, user) do
          {:ok, conn, hydrated_user} ->
            assign(conn, :current_user, hydrated_user)

          {:error, :user_not_found} ->
            clear_identity(conn)

          {:error, _reason} ->
            conn |> send_resp(503, "Session temporarily unavailable.") |> halt()
        end

      _ ->
        clear_identity(conn)
    end
  end

  defp clear_identity(conn) do
    case UserSession.log_out(conn) do
      {:ok, conn} ->
        conn |> delete_session(:user_id) |> assign(:current_user, nil)

      {:error, _reason} ->
        conn
        |> delete_session(:user_id)
        |> send_resp(503, "Session temporarily unavailable.")
        |> halt()
    end
  end
end
