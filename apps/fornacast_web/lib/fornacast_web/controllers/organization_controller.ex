defmodule FornacastWeb.OrganizationController do
  use FornacastWeb, :controller

  def new(conn, _params) do
    page(conn, "New organization", """
    <form action="/organizations" method="post">
      #{csrf_input()}
      <label>Slug <input name="organization[username]"></label>
      <label>Name <input name="organization[display_name]"></label>
      <label>Description <textarea name="organization[description]" rows="3"></textarea></label>
      <button type="submit">Create organization</button>
    </form>
    """)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"organization" => attrs}) do
    case ForgeAccounts.create_organization(user, attrs) do
      {:ok, organization} ->
        redirect(conn, to: "/#{organization.username}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> page("New organization", ~s(<p class="error">#{escape(inspect(changeset.errors))}</p>))

      {:error, reason} ->
        conn
        |> put_status(:forbidden)
        |> page("New organization", ~s(<p class="error">#{escape(reason)}</p>))
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> page("New organization", ~s(<p class="error">Organization parameters are required.</p>))
  end

  def show(conn, %{"owner" => owner_slug}) do
    case ForgeAccounts.get_account_by_username(owner_slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> page("Not found", ~s(<p class="error">Namespace not found.</p>))

      owner ->
        repos = ForgeRepos.list_owner_repositories(owner)

        rows =
          repos
          |> Enum.map(fn repo ->
            ~s(<tr><td><a href="/#{escape(owner.username)}/#{escape(repo.slug)}">#{escape(repo.name)}</a></td><td>#{escape(repo.visibility)}</td><td>#{escape(repo.default_branch)}</td></tr>)
          end)
          |> Enum.join("\n")

        body = """
        <p class="muted">#{escape(namespace_description(owner))}</p>
        <table>
          <thead><tr><th>Repository</th><th>Visibility</th><th>Default branch</th></tr></thead>
          <tbody>#{rows}</tbody>
        </table>
        """

        page(conn, namespace_title(owner), body)
    end
  end

  defp namespace_title(%{kind: :organization, display_name: display_name, username: username}) do
    display_name || username
  end

  defp namespace_title(%{username: username}), do: username

  defp namespace_description(%{description: description}) when is_binary(description),
    do: description

  defp namespace_description(%{kind: :organization}), do: "Organization"
  defp namespace_description(_owner), do: "User"
end
