defmodule FornacastWeb.DashboardController do
  use FornacastWeb, :controller

  alias FornacastWeb.DashboardHTML

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    repos = ForgeRepos.list_accessible_repositories(user)

    rendered =
      DashboardHTML.index(%{
        user: user,
        repos: repos,
        __changed__: nil
      })

    body = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    page(conn, "Dashboard", body)
  end
end
