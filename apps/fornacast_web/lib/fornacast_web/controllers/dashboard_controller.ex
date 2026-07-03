defmodule FornacastWeb.DashboardController do
  use FornacastWeb, :controller

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    repos = ForgeRepos.list_owner_repositories(user)

    rows =
      repos
      |> Enum.map(fn repo ->
        ~s(<tr><td><a href="/#{escape(user.username)}/#{escape(repo.slug)}">#{escape(repo.name)}</a></td><td>#{escape(repo.visibility)}</td><td>#{escape(repo.default_branch)}</td></tr>)
      end)
      |> Enum.join("\n")

    body =
      """
      <p><a href="/repos/new">Create a repository</a></p>
      <table>
        <thead><tr><th>Repository</th><th>Visibility</th><th>Default branch</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
      """

    page(conn, "Dashboard", body)
  end
end
