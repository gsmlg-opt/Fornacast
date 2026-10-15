defmodule FornacastWeb.Plugs.RequireAdmin do
  import Plug.Conn

  alias ForgeAccounts.User

  def init(opts), do: opts

  def call(
        %Plug.Conn{assigns: %{current_user: %User{kind: :user, role: :admin, state: :active}}} =
          conn,
        _opts
      ),
      do: conn

  def call(conn, _opts) do
    conn
    |> send_resp(403, "Site administrator access required.")
    |> halt()
  end
end
