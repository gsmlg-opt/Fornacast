defmodule FornacastAPI.RepositoryController do
  use FornacastAPI, :controller

  alias ForgeAccounts.{Organization, User}
  alias ForgeRepos.Repository
  alias FornacastAPI.{Authentication, Error, Pagination, RequestBody, RequestValidator}
  alias FornacastAPI.{Response, Serializer, URL}
  alias FornacastAPI.Plugs.RequestContext

  @public_mutation_scopes ["public_repo"]
  @private_repository_scopes ["repo", "repo:read", "repo:write"]
  @private_mutation_scopes ["repo"]

  @authenticated_query_fields [
    {"visibility", :visibility},
    {"affiliation", :affiliation},
    {"type", :type},
    {"sort", :sort},
    {"direction", :direction},
    {"since", :since},
    {"before", :before}
  ]
  @account_query_fields [
    {"type", :type},
    {"sort", :sort},
    {"direction", :direction}
  ]

  @authenticated_list_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#list-repositories-for-the-authenticated-user"
  @user_list_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#list-repositories-for-a-user"
  @organization_list_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#list-organization-repositories"
  @personal_create_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#create-a-repository-for-the-authenticated-user"
  @organization_create_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#create-an-organization-repository"
  @show_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#get-a-repository"
  @update_documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/repos/repos#update-a-repository"

  def for_authenticated_user(conn, _params) do
    conn = fetch_query_params(conn)

    with {:ok, %Authentication{actor: actor, api_key: api_key}} <- authenticate(conn),
         {:ok, visibility_ceiling, accepted_scopes} <- authenticated_list_access(api_key) do
      list_for_authenticated_actor(
        conn,
        actor,
        visibility_ceiling,
        accepted_scopes
      )
    else
      {:error, reason, accepted_scopes} ->
        render_error(
          conn,
          reason,
          @authenticated_list_documentation_url,
          accepted_scopes
        )

      {:error, reason} ->
        render_error(conn, reason, @authenticated_list_documentation_url, @public_mutation_scopes)
    end
  end

  def for_user(conn, %{"username" => username}) do
    list_for_account(
      conn,
      &ForgeAccounts.get_public_user/1,
      username,
      :minimal_repository,
      @user_list_documentation_url
    )
  end

  def for_organization(conn, %{"org" => slug}) do
    list_for_account(
      conn,
      &ForgeAccounts.get_public_organization/1,
      slug,
      :minimal_repository,
      @organization_list_documentation_url
    )
  end

  def show(conn, %{"owner" => owner, "repo" => repository_slug}) do
    actor = optional_actor(conn.assigns[:api_auth])

    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner,
             repository_slug,
             :repository_read
           ) do
      show_authorized(conn, actor, repository)
    else
      {:error, reason} -> render_error(conn, reason, @show_documentation_url, [])
    end
  end

  def create_for_authenticated_user(conn, _params) do
    with {:ok, %Authentication{actor: actor, api_key: api_key}} <- authenticate(conn),
         {:ok, %User{id: actor_id, kind: :user, state: :active} = owner} <-
           resolve_personal_owner(actor),
         true <- actor.id == actor_id,
         :ok <-
           ForgeAccounts.APIScope.authorize(api_key, :repository_mutation, :public) do
      create_after_preauthorization(
        conn,
        actor,
        api_key,
        owner,
        @personal_create_documentation_url
      )
    else
      false ->
        render_error(
          conn,
          :forbidden,
          @personal_create_documentation_url,
          @public_mutation_scopes
        )

      {:error, reason} ->
        render_error(
          conn,
          reason,
          @personal_create_documentation_url,
          @public_mutation_scopes
        )
    end
  end

  def create_for_organization(conn, %{"org" => slug}) do
    with {:ok, %Authentication{actor: actor, api_key: api_key}} <- authenticate(conn),
         {:ok, %Organization{kind: :organization, state: :active} = owner} <-
           resolve_organization_owner(actor, slug),
         :ok <-
           ForgeAccounts.APIScope.authorize(api_key, :repository_mutation, :public) do
      create_after_preauthorization(
        conn,
        actor,
        api_key,
        owner,
        @organization_create_documentation_url
      )
    else
      {:error, reason} ->
        render_error(
          conn,
          reason,
          @organization_create_documentation_url,
          @public_mutation_scopes
        )
    end
  end

  def update(conn, %{"owner" => owner, "repo" => repository_slug}) do
    with {:ok, %Authentication{actor: actor, api_key: api_key}} <- authenticate(conn),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner,
             repository_slug,
             :repository_read
           ) do
      update_visible(conn, actor, api_key, repository, owner, repository_slug)
    else
      {:error, reason} ->
        render_error(conn, reason, @update_documentation_url, @public_mutation_scopes)
    end
  end

  defp list_for_account(conn, resolver, slug, resource, documentation_url) do
    conn = fetch_query_params(conn)
    authentication = conn.assigns[:api_auth]
    actor = optional_actor(authentication)
    {visibility_ceiling, accepted_scopes} = account_list_access(authentication)

    with {:ok, account} <- resolver.(slug),
         {:ok, pagination} <- Pagination.parse(conn.query_params),
         options <-
           query_options(
             conn.query_params,
             pagination,
             @account_query_fields,
             visibility_ceiling
           ),
         {:ok, page} <- ForgeRepos.list_account_repository_views(actor, account, options) do
      render_page(
        conn,
        page,
        resource,
        actor,
        account_list_url(account) |> retain_query(conn.query_params, @account_query_fields),
        accepted_scopes
      )
    else
      {:error, reason} -> render_error(conn, reason, documentation_url, accepted_scopes)
    end
  end

  defp list_for_authenticated_actor(conn, actor, visibility_ceiling, accepted_scopes) do
    with {:ok, pagination} <- Pagination.parse(conn.query_params),
         options <-
           query_options(
             conn.query_params,
             pagination,
             @authenticated_query_fields,
             visibility_ceiling
           ),
         {:ok, page} <- ForgeRepos.list_accessible_repository_views(actor, options) do
      render_page(
        conn,
        page,
        :repository,
        actor,
        URL.api("/user/repos")
        |> retain_query(conn.query_params, @authenticated_query_fields),
        accepted_scopes
      )
    else
      {:error, reason} ->
        render_error(conn, reason, @authenticated_list_documentation_url, accepted_scopes)
    end
  end

  defp render_page(conn, page, resource, actor, url, accepted_scopes) do
    body =
      Enum.map(page.entries, fn view ->
        Serializer.render(conn.assigns.api_version, resource, view, actor: actor)
      end)

    Response.paginated(conn, 200, body, page, url: url, accepted_scopes: accepted_scopes)
  end

  defp show_authorized(conn, actor, %Repository{visibility: :public} = repository) do
    render_repository(conn, actor, repository, 200, [], @show_documentation_url)
  end

  defp show_authorized(
         conn,
         actor,
         %Repository{visibility: :private} = repository
       ) do
    with {:ok, %Authentication{api_key: api_key}} <- authenticate(conn),
         :ok <- ForgeAccounts.APIScope.authorize(api_key, :repository_read, :private) do
      render_repository(
        conn,
        actor,
        repository,
        200,
        @private_repository_scopes,
        @show_documentation_url
      )
    else
      {:error, reason} ->
        render_error(conn, reason, @show_documentation_url, @private_repository_scopes)
    end
  end

  defp create_after_preauthorization(conn, actor, api_key, owner, documentation_url) do
    case RequestBody.read_json(conn, :ordinary, []) do
      {:ok, body, conn} ->
        create_from_body(conn, actor, api_key, owner, body, documentation_url)

      {:error, %Error{} = error, _reason, conn} ->
        render_error(conn, error, @public_mutation_scopes)
    end
  end

  defp create_from_body(conn, actor, api_key, owner, body, documentation_url) do
    with {:ok, attrs} <-
           RequestValidator.validate(conn.assigns.api_version, :create_repository, body),
         visibility <- create_visibility(attrs),
         :ok <-
           ForgeAccounts.APIScope.authorize(api_key, :repository_mutation, visibility),
         {:ok, repository} <-
           ForgeRepos.create_api_repository(
             actor,
             owner,
             attrs,
             RequestContext.metadata(conn)
           ) do
      render_repository(
        conn,
        actor,
        repository,
        201,
        mutation_scopes(visibility),
        documentation_url
      )
    else
      {:error, :insufficient_scope} ->
        visibility = create_visibility(body)
        render_error(conn, :insufficient_scope, documentation_url, mutation_scopes(visibility))

      {:error, reason} ->
        render_error(conn, reason, documentation_url, create_error_scopes(body))
    end
  end

  defp update_visible(conn, actor, api_key, repository, owner, repository_slug) do
    accepted_scopes = mutation_scopes(repository.visibility)

    case refetch_same_repository(actor, owner, repository_slug, repository.id) do
      {:ok, writable_repository} ->
        update_authorized(
          conn,
          actor,
          api_key,
          writable_repository,
          owner,
          repository_slug
        )

      {:error, reason} ->
        render_error(conn, reason, @update_documentation_url, accepted_scopes)
    end
  end

  defp update_authorized(conn, actor, api_key, repository, owner, repository_slug) do
    stored_scopes = mutation_scopes(repository.visibility)

    case ForgeAccounts.APIScope.authorize(
           api_key,
           :repository_mutation,
           repository.visibility
         ) do
      :ok ->
        read_update_body(
          conn,
          actor,
          api_key,
          repository,
          owner,
          repository_slug,
          stored_scopes
        )

      {:error, reason} ->
        render_error(conn, reason, @update_documentation_url, stored_scopes)
    end
  end

  defp read_update_body(
         conn,
         actor,
         api_key,
         repository,
         owner,
         repository_slug,
         stored_scopes
       ) do
    case RequestBody.read_json(conn, :ordinary, []) do
      {:ok, body, conn} ->
        update_from_body(conn, actor, api_key, repository, owner, repository_slug, body)

      {:error, %Error{} = error, _reason, conn} ->
        render_error(conn, error, stored_scopes)
    end
  end

  defp update_from_body(conn, actor, api_key, repository, owner, repository_slug, body) do
    case RequestValidator.validate(conn.assigns.api_version, :update_repository, body) do
      {:ok, attrs} ->
        refetch_after_body(
          conn,
          actor,
          api_key,
          repository,
          owner,
          repository_slug,
          attrs
        )

      {:error, reason} ->
        render_error(
          conn,
          reason,
          @update_documentation_url,
          update_error_scopes(repository.visibility, body)
        )
    end
  end

  defp refetch_after_body(
         conn,
         actor,
         api_key,
         original_repository,
         owner,
         repository_slug,
         attrs
       ) do
    case refetch_same_repository(
           actor,
           owner,
           repository_slug,
           original_repository.id
         ) do
      {:ok, repository} ->
        authorize_refetched_update(conn, actor, api_key, repository, attrs)

      {:error, reason} ->
        render_error(
          conn,
          reason,
          @update_documentation_url,
          update_error_scopes(original_repository.visibility, attrs)
        )
    end
  end

  defp authorize_refetched_update(conn, actor, api_key, repository, attrs) do
    resulting_visibility = update_visibility(repository.visibility, attrs)
    accepted_scopes = transition_scopes(repository.visibility, resulting_visibility)

    with :ok <-
           ForgeAccounts.APIScope.authorize(
             api_key,
             :repository_mutation,
             repository.visibility
           ),
         :ok <-
           ForgeAccounts.APIScope.authorize(
             api_key,
             :repository_mutation,
             resulting_visibility
           ),
         {:ok, updated} <-
           ForgeRepos.update_api_repository(
             actor,
             repository,
             attrs,
             RequestContext.metadata(conn),
             expected_visibility: repository.visibility
           ) do
      render_repository(
        conn,
        actor,
        updated,
        200,
        accepted_scopes,
        @update_documentation_url
      )
    else
      {:error, reason} ->
        render_error(conn, reason, @update_documentation_url, accepted_scopes)
    end
  end

  defp refetch_same_repository(actor, owner, repository_slug, expected_id) do
    case ForgeRepos.fetch_authorized_repository(
           actor,
           owner,
           repository_slug,
           :repository_write
         ) do
      {:ok, %Repository{id: ^expected_id} = repository} -> {:ok, repository}
      {:ok, %Repository{}} -> {:error, {:conflict, "repository changed"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_repository(
         conn,
         actor,
         repository,
         status,
         accepted_scopes,
         documentation_url
       ) do
    case ForgeRepos.repository_view(actor, repository) do
      {:ok, view} ->
        body =
          Serializer.render(conn.assigns.api_version, :full_repository, view, actor: actor)

        Response.json(conn, status, body, accepted_scopes: accepted_scopes)

      {:error, reason} ->
        render_error(conn, reason, documentation_url, accepted_scopes)
    end
  end

  defp authenticated_list_access(api_key) do
    case ForgeAccounts.APIScope.authorize(api_key, :repository_read, :private) do
      :ok ->
        {:ok, :all, @private_repository_scopes}

      {:error, :insufficient_scope} ->
        case ForgeAccounts.APIScope.authorize(api_key, :repository_read, :public) do
          :ok -> {:ok, :public, @public_mutation_scopes}
          {:error, reason} -> {:error, reason, @public_mutation_scopes}
        end
    end
  end

  defp account_list_access(%Authentication{api_key: api_key}) do
    case ForgeAccounts.APIScope.authorize(api_key, :repository_read, :private) do
      :ok -> {:all, @private_repository_scopes}
      {:error, _reason} -> {:public, []}
    end
  end

  defp account_list_access(_authentication), do: {:public, []}

  defp query_options(params, pagination, fields, visibility_ceiling) do
    Enum.reduce(fields, [{:visibility_ceiling, visibility_ceiling} | pagination], fn
      {external, internal}, options ->
        case Map.fetch(params, external) do
          {:ok, value} -> Keyword.put(options, internal, value)
          :error -> options
        end
    end)
  end

  defp retain_query(url, params, fields) do
    supported = ["page", "per_page" | Enum.map(fields, &elem(&1, 0))]

    query =
      supported
      |> Enum.flat_map(fn key ->
        case Map.fetch(params, key) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)
      |> Enum.sort()

    case query do
      [] -> url
      pairs -> url <> "?" <> URI.encode_query(pairs, :rfc3986)
    end
  end

  defp create_visibility(%{"visibility" => "private"}), do: :private
  defp create_visibility(%{"visibility" => "public"}), do: :public
  defp create_visibility(%{"private" => true}), do: :private
  defp create_visibility(%{"private" => false}), do: :public
  defp create_visibility(_attrs), do: :public

  defp update_visibility(_stored_visibility, %{"visibility" => "private"}), do: :private
  defp update_visibility(_stored_visibility, %{"visibility" => "public"}), do: :public
  defp update_visibility(_stored_visibility, %{"private" => true}), do: :private
  defp update_visibility(_stored_visibility, %{"private" => false}), do: :public
  defp update_visibility(stored_visibility, _attrs), do: stored_visibility

  defp mutation_scopes(:public), do: @public_mutation_scopes
  defp mutation_scopes(:private), do: @private_mutation_scopes

  defp transition_scopes(:private, _resulting_visibility), do: @private_mutation_scopes
  defp transition_scopes(_stored_visibility, :private), do: @private_mutation_scopes
  defp transition_scopes(:public, :public), do: @public_mutation_scopes

  defp create_error_scopes(body), do: body |> create_visibility() |> mutation_scopes()

  defp update_error_scopes(stored_visibility, body) do
    resulting_visibility = update_visibility(stored_visibility, body)
    transition_scopes(stored_visibility, resulting_visibility)
  end

  defp resolve_personal_owner(actor) do
    case ForgeAccounts.repository_owner_by_slug_for(actor, actor.username) do
      {:ok, %User{kind: :user, state: :active} = owner} -> {:ok, owner}
      {:error, :unauthorized} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :not_found}
    end
  end

  defp resolve_organization_owner(actor, slug) do
    case ForgeAccounts.repository_owner_by_slug_for(actor, slug) do
      {:ok, %Organization{kind: :organization, state: :active} = owner} -> {:ok, owner}
      {:ok, _wrong_kind} -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authenticate(%Plug.Conn{assigns: %{api_auth: %Authentication{} = authentication}}),
    do: {:ok, authentication}

  defp authenticate(_conn), do: {:error, :invalid_credentials}

  defp optional_actor(%Authentication{actor: actor}), do: actor
  defp optional_actor(_authentication), do: nil

  defp account_list_url(%User{username: username}),
    do: URL.api("/users/#{path_segment(username)}/repos")

  defp account_list_url(%Organization{username: username}),
    do: URL.api("/orgs/#{path_segment(username)}/repos")

  defp path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp render_error(conn, %Error{} = error, accepted_scopes) do
    Response.error(conn, %{error | accepted_scopes: accepted_scopes})
  end

  defp render_error(conn, reason, documentation_url, accepted_scopes) do
    error = %{Error.from_domain(reason, documentation_url) | accepted_scopes: accepted_scopes}
    Response.error(conn, error)
  end
end
