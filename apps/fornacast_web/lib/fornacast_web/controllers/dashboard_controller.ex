defmodule FornacastWeb.DashboardController do
  use FornacastWeb, :controller

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    repos = ForgeRepos.list_owner_repositories(user)

    rows =
      repos
      |> Enum.map(fn repo ->
        """
        <tr>
          <td><a href="/#{escape(user.username)}/#{escape(repo.slug)}">#{escape(repo.name)}</a></td>
          <td>#{badge(repo.visibility, to_string(repo.visibility))}</td>
          <td><code>#{escape(repo.default_branch)}</code></td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    body =
      section_header(
        "Repositories",
        "Browse repositories owned by #{user.username}.",
        primary_link("/repos/new", "New repository")
      ) <>
        if rows == "" do
          empty_state(
            "No repositories yet",
            "Create the first repository for this Fornacast instance.",
            primary_link("/repos/new", "Create repository")
          )
        else
          """
          <section class="content-panel">
            <table class="data-table repo-table">
              <thead><tr><th>Repository</th><th>Visibility</th><th>Default branch</th></tr></thead>
              <tbody>#{rows}</tbody>
            </table>
          </section>
          """
        end

    page(conn, "Dashboard", body)
  end
end
