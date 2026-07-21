defmodule FornacastAPI.OrganizationController do
  use FornacastAPI, :controller

  alias ForgeAccounts.Organization
  alias FornacastAPI.{Authentication, Error, Pagination, RequestBody, RequestValidator}
  alias FornacastAPI.{Response, Serializer, URL}
  alias FornacastAPI.Plugs.RequestContext

  @read_scopes ["read:org"]
  @mutation_scopes ["write:org"]
  @list_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/orgs/orgs#list-organizations-for-the-authenticated-user"
  @show_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/orgs/orgs#get-an-organization"
  @create_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/enterprise-admin/orgs#create-an-organization"
  @update_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/orgs/orgs#update-an-organization"

  def for_authenticated_user(conn, _params) do
    conn = fetch_query_params(conn)

    with {:ok, %Authentication{actor: actor, api_key: api_key}} <- authenticate(conn),
         :ok <- ForgeAccounts.APIScope.authorize(api_key, :organization_read, nil),
         {:ok, pagination} <- Pagination.parse(conn.query_params),
         {:ok, page} <- ForgeAccounts.list_user_organizations(actor, pagination) do
      body =
        Enum.map(page.entries, fn organization ->
          Serializer.render(conn.assigns.api_version, :organization_simple, organization)
        end)

      Response.paginated(conn, 200, body, page,
        url: URL.api("/user/orgs"),
        accepted_scopes: @read_scopes
      )
    else
      {:error, reason} -> render_error(conn, reason, @list_documentation_url, @read_scopes)
    end
  end

  def show(conn, %{"org" => slug}) do
    with {:ok, organization} <- ForgeAccounts.get_public_organization(slug) do
      actor = optional_actor(conn.assigns[:api_auth])
      view = ForgeRepos.account_view(actor, organization)
      body = Serializer.render(conn.assigns.api_version, :organization_full, view)
      Response.json(conn, 200, body, accepted_scopes: [])
    else
      {:error, reason} -> render_error(conn, reason, @show_documentation_url, [])
    end
  end

  def create(conn, _params) do
    with {:ok, %Authentication{actor: actor, api_key: api_key}} <- authenticate(conn),
         :ok <- ForgeAccounts.APIScope.authorize(api_key, :organization_mutation, nil) do
      case RequestBody.read_json(conn, :ordinary, []) do
        {:ok, body, conn} -> create_from_body(conn, actor, body)
        {:error, %Error{} = error, _reason, conn} -> render_error(conn, error, @mutation_scopes)
      end
    else
      {:error, reason} -> render_error(conn, reason, @create_documentation_url, @mutation_scopes)
    end
  end

  def update(conn, %{"org" => slug}) do
    with {:ok, %Authentication{actor: actor, api_key: api_key}} <- authenticate(conn),
         {:ok, organization} <- ForgeAccounts.get_public_organization(slug),
         :ok <- preauthorize_update(actor, organization),
         :ok <- ForgeAccounts.APIScope.authorize(api_key, :organization_mutation, nil) do
      case RequestBody.read_json(conn, :ordinary, []) do
        {:ok, body, conn} -> update_from_body(conn, actor, organization, body)
        {:error, %Error{} = error, _reason, conn} -> render_error(conn, error, @mutation_scopes)
      end
    else
      {:error, reason} -> render_error(conn, reason, @update_documentation_url, @mutation_scopes)
    end
  end

  defp create_from_body(conn, actor, body) do
    with {:ok, attrs} <-
           RequestValidator.validate(conn.assigns.api_version, :create_organization, body),
         {:ok, organization} <-
           ForgeAccounts.create_api_organization(actor, attrs, RequestContext.metadata(conn)) do
      response = Serializer.render(conn.assigns.api_version, :organization_simple, organization)
      Response.json(conn, 201, response, accepted_scopes: @mutation_scopes)
    else
      {:error, reason} -> render_error(conn, reason, @create_documentation_url, @mutation_scopes)
    end
  end

  defp update_from_body(conn, actor, organization, body) do
    with {:ok, attrs} <-
           RequestValidator.validate(conn.assigns.api_version, :update_organization, body),
         {:ok, updated} <-
           ForgeAccounts.update_organization(
             actor,
             organization,
             attrs,
             RequestContext.metadata(conn)
           ) do
      view = ForgeRepos.account_view(actor, updated)
      response = Serializer.render(conn.assigns.api_version, :organization_full, view)
      Response.json(conn, 200, response, accepted_scopes: @mutation_scopes)
    else
      {:error, reason} -> render_error(conn, reason, @update_documentation_url, @mutation_scopes)
    end
  end

  defp authenticate(%Plug.Conn{assigns: %{api_auth: %Authentication{} = authentication}}),
    do: {:ok, authentication}

  defp authenticate(_conn), do: {:error, :invalid_credentials}

  defp optional_actor(%Authentication{actor: actor}), do: actor
  defp optional_actor(_api_auth), do: nil

  defp preauthorize_update(actor, %Organization{id: organization_id} = organization) do
    case ForgeAccounts.repository_owner_by_slug_for(actor, organization.username) do
      {:ok, %Organization{id: ^organization_id, kind: :organization}} -> :ok
      {:error, :unauthorized} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :forbidden}
    end
  end

  defp render_error(conn, %Error{} = error, accepted_scopes) do
    Response.error(conn, %{error | accepted_scopes: accepted_scopes})
  end

  defp render_error(conn, reason, documentation_url, accepted_scopes) do
    error = %{Error.from_domain(reason, documentation_url) | accepted_scopes: accepted_scopes}
    Response.error(conn, error)
  end
end
