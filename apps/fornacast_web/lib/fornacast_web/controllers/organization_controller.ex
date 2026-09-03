defmodule FornacastWeb.OrganizationController do
  use FornacastWeb, :controller

  alias ForgeAccounts.Organization
  alias FornacastWeb.OrganizationHTML

  plug :put_private_no_store

  def new(conn, _params) do
    render_new(conn, %{}, nil)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"organization" => attrs}) do
    case ForgeAccounts.create_organization(user, attrs) do
      {:ok, organization} ->
        redirect(conn, to: "/#{organization.username}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_new(attrs, inspect(changeset.errors))

      {:error, reason} ->
        conn
        |> put_status(:forbidden)
        |> render_new(attrs, to_string(reason))
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render_new(%{}, "Organization parameters are required.")
  end

  def show(%Plug.Conn{assigns: %{current_user: current_user}} = conn, %{"owner" => owner_slug}) do
    case ForgeAccounts.get_account_by_username(owner_slug) do
      nil ->
        render_namespace_not_found(conn)

      %ForgeAccounts.User{kind: :organization, id: organization_id} = owner ->
        case ForgeAccounts.get_organization(organization_id) do
          %Organization{} = organization ->
            render_namespace_for_account(conn, current_user, organization, owner)

          nil ->
            render_namespace_not_found(conn)
        end

      owner ->
        render_namespace_for_account(conn, current_user, owner, owner)
    end
  end

  defp render_namespace_for_account(conn, current_user, account, owner) do
    case ForgeRepos.list_account_repository_views(current_user, account,
           visibility_ceiling: :all,
           page: 1,
           per_page: 100
         ) do
      {:ok, %Fornacast.Page{entries: repository_views}} ->
        render_namespace(conn, owner, repository_views)

      {:error, _masked} ->
        render_namespace_not_found(conn)
    end
  end

  defp render_new(conn, organization, error) do
    rendered =
      OrganizationHTML.new(%{
        organization: organization,
        error: error,
        __changed__: nil
      })

    page(
      conn,
      "New organization",
      rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    )
  end

  defp render_namespace(conn, owner, repository_views) do
    rendered =
      OrganizationHTML.show(%{
        owner: owner,
        description: namespace_description(owner),
        repository_views: repository_views,
        __changed__: nil
      })

    page(
      conn,
      namespace_title(owner),
      rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    )
  end

  defp render_namespace_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> page("Not found", error_panel("Namespace not found."))
  end

  defp namespace_title(%{kind: :organization, display_name: display_name, username: username}) do
    display_name || username
  end

  defp namespace_title(%{username: username}), do: username

  defp namespace_description(%{description: description}) when is_binary(description),
    do: description

  defp namespace_description(%{kind: :organization}), do: "Organization"
  defp namespace_description(_owner), do: "User"

  defp put_private_no_store(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
