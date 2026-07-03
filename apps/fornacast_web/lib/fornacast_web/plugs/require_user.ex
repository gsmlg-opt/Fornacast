defmodule FornacastWeb.Plugs.RequireUser do
  import Phoenix.Controller
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: nil}} = conn, _opts) do
    conn
    |> redirect(to: "/login")
    |> halt()
  end

  def call(conn, _opts), do: conn
end
