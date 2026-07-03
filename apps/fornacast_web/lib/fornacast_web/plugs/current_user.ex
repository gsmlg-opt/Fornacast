defmodule FornacastWeb.Plugs.CurrentUser do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    user =
      conn
      |> get_session(:user_id)
      |> case do
        nil -> nil
        user_id -> ForgeAccounts.get_user(user_id)
      end

    assign(conn, :current_user, user)
  end
end
