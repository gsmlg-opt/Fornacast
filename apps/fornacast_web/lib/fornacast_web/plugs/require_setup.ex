defmodule FornacastWeb.Plugs.RequireSetup do
  import Phoenix.Controller
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Fornacast.Setup.initialized?() do
      conn
    else
      conn
      |> redirect(to: "/setup")
      |> halt()
    end
  end
end
