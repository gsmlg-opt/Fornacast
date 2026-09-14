defmodule FornacastAPI.ReleaseController do
  use FornacastAPI, :controller

  alias ForgeAccounts.APIScope
  alias ForgeReleases
  alias ForgeRepos

  alias FornacastAPI.{
    Authentication,
    Error,
    Pagination,
    RequestBody,
    RequestValidator,
    Response,
    Serializer,
    URL
  }

  alias FornacastAPI.Plugs.RequestContext

  @index_url "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#list-releases"
  @create_url "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#create-a-release"
  @show_url "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#get-a-release"
  @tag_url "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#get-a-release-by-tag-name"
  @latest_url "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#get-the-latest-release"
  @update_url "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#update-a-release"
  @delete_url "https://docs.github.com/en/enterprise-server@3.21/rest/releases/releases#delete-a-release"

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    conn = fetch_query_params(conn)
    actor = optional_actor(conn.assigns[:api_auth])

    with {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(conn.assigns[:api_auth], :repository_read, repository.visibility) do
      conn = Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes)

      with {:ok, pagination} <- Pagination.parse(conn.query_params),
           {:ok, page} <- ForgeReleases.list(actor, owner, repo, Map.new(pagination)) do
        body = Enum.map(page.entries, &render_release(conn, &1, owner, repo))

        Response.paginated(conn, 200, body, page,
          url: request_path_with_query(conn),
          accepted_scopes: accepted_scopes
        )
      else
        {:error, reason} -> render_error(conn, reason, @index_url)
      end
    else
      {:error, reason} -> render_error(conn, reason, @index_url)
    end
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "release_id" => release_id}) do
    read_one(conn, owner, repo, @show_url, fn actor ->
      with {:ok, id} <- positive_integer(release_id),
           do: ForgeReleases.get(actor, owner, repo, id)
    end)
  end

  def by_tag(conn, %{"owner" => owner, "repo" => repo, "tag" => tag}) do
    read_one(conn, owner, repo, @tag_url, fn actor ->
      ForgeReleases.get_by_tag(actor, owner, repo, tag)
    end)
  end

  def latest(conn, %{"owner" => owner, "repo" => repo}) do
    read_one(conn, owner, repo, @latest_url, fn actor ->
      ForgeReleases.latest(actor, owner, repo)
    end)
  end

  def create(conn, %{"owner" => owner, "repo" => repo}) do
    mutate(
      conn,
      owner,
      repo,
      :release_create,
      @create_url,
      fn _actor -> {:ok, nil} end,
      fn actor, _target, attrs, metadata ->
        ForgeReleases.create(actor, owner, repo, attrs, metadata)
      end,
      201
    )
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "release_id" => release_id}) do
    mutate(
      conn,
      owner,
      repo,
      :release_update,
      @update_url,
      fn actor ->
        with {:ok, id} <- positive_integer(release_id),
             {:ok, _release} <- ForgeReleases.get(actor, owner, repo, id),
             do: {:ok, id}
      end,
      fn actor, id, attrs, metadata ->
        ForgeReleases.update(actor, owner, repo, id, attrs, metadata)
      end,
      200
    )
  end

  def delete(conn, %{"owner" => owner, "repo" => repo, "release_id" => release_id}) do
    with {:ok, %{actor: actor} = authentication} <- require_auth(conn),
         {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(authentication, :repository_mutation, repository.visibility) do
      conn = Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes)

      with {:ok, id} <- positive_integer(release_id) do
        case ForgeReleases.delete(actor, owner, repo, id, RequestContext.metadata(conn)) do
          :ok -> Response.no_content(conn, accepted_scopes: accepted_scopes)
          {:error, reason} -> render_error(conn, reason, @delete_url)
        end
      else
        {:error, reason} -> render_error(conn, reason, @delete_url)
      end
    else
      {:error, reason} -> render_error(conn, reason, @delete_url)
    end
  end

  defp read_one(conn, owner, repo, documentation_url, read_fun) do
    actor = optional_actor(conn.assigns[:api_auth])

    with {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(conn.assigns[:api_auth], :repository_read, repository.visibility) do
      conn = Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes)

      with {:ok, release} <- read_fun.(actor) do
        Response.json(conn, 200, render_release(conn, release, owner, repo),
          accepted_scopes: accepted_scopes
        )
      else
        {:error, reason} -> render_error(conn, reason, documentation_url)
      end
    else
      {:error, reason} -> render_error(conn, reason, documentation_url)
    end
  end

  defp mutate(
         conn,
         owner,
         repo,
         operation,
         documentation_url,
         target_fun,
         mutation_fun,
         status
       ) do
    version = conn.assigns.api_version

    with {:ok, %{actor: actor} = authentication} <- require_auth(conn),
         {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(authentication, :repository_mutation, repository.visibility) do
      conn = Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes)

      with {:ok, _repository} <-
             ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_write),
           {:ok, target} <- target_fun.(actor) do
        case read_authorized_body(conn, accepted_scopes) do
          {:ok, body, body_conn} ->
            with {:ok, attrs} <- RequestValidator.validate(version, operation, body),
                 {:ok, release} <-
                   mutation_fun.(actor, target, attrs, RequestContext.metadata(body_conn)) do
              Response.json(body_conn, status, render_release(body_conn, release, owner, repo),
                accepted_scopes: accepted_scopes
              )
            else
              {:error, reason} -> render_error(body_conn, reason, documentation_url)
            end

          {:error, %Error{} = error, _reason, body_conn} ->
            Response.error(body_conn, error)
        end
      else
        {:error, reason} -> render_error(conn, reason, documentation_url)
      end
    else
      {:error, reason} -> render_error(conn, reason, documentation_url)
    end
  end

  defp render_release(conn, release, owner, repo) do
    Serializer.render(conn.assigns.api_version, :release, release, owner: owner, repo: repo)
  end

  defp authorized_repository(actor, owner, repo),
    do: ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read)

  defp optional_actor(%Authentication{actor: actor}), do: actor
  defp optional_actor(_authentication), do: nil

  defp authorize_scope(nil, :repository_read, :public), do: {:ok, []}

  defp authorize_scope(%Authentication{api_key: api_key}, action, visibility) do
    accepted_scopes = APIScope.accepted_scopes(action, visibility)

    case APIScope.authorize(api_key, action, visibility) do
      :ok -> {:ok, accepted_scopes}
      {:error, :insufficient_scope} -> {:error, {:insufficient_scope, accepted_scopes}}
    end
  end

  defp authorize_scope(nil, _action, _visibility), do: {:error, :requires_authentication}

  defp require_auth(%Plug.Conn{assigns: %{api_auth: %Authentication{} = authentication}}),
    do: {:ok, authentication}

  defp require_auth(_conn), do: {:error, :requires_authentication}

  defp positive_integer(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :not_found}
    end
  end

  defp read_authorized_body(conn, accepted_scopes) do
    case RequestBody.read_json(conn, :ordinary, []) do
      {:error, %Error{} = error, reason, conn} ->
        {:error, %{error | accepted_scopes: accepted_scopes}, reason, conn}

      result ->
        result
    end
  end

  defp render_error(conn, reason, documentation_url) do
    error = Error.from_domain(reason, documentation_url)
    accepted_scopes = error.accepted_scopes ++ (conn.assigns[:accepted_scopes] || [])
    Response.error(conn, %{error | accepted_scopes: Enum.uniq(accepted_scopes)})
  end

  defp request_path_with_query(conn),
    do:
      URL.api(String.replace_prefix(conn.request_path, "/api/v3", "")) <>
        if(conn.query_string == "", do: "", else: "?" <> conn.query_string)
end
