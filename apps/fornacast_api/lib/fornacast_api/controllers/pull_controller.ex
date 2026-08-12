defmodule FornacastAPI.PullController do
  use FornacastAPI, :controller

  alias ForgeAccounts.APIScope
  alias ForgePulls
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

  @index_url "https://docs.github.com/en/enterprise-server@3.21/rest/pulls/pulls#list-pull-requests"
  @create_url "https://docs.github.com/en/enterprise-server@3.21/rest/pulls/pulls#create-a-pull-request"
  @show_url "https://docs.github.com/en/enterprise-server@3.21/rest/pulls/pulls#get-a-pull-request"
  @update_url "https://docs.github.com/en/enterprise-server@3.21/rest/pulls/pulls#update-a-pull-request"

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    conn = fetch_query_params(conn)
    actor = optional_actor(conn.assigns[:api_auth])

    with {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(conn.assigns[:api_auth], :repository_read, repository.visibility),
         conn <- Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes),
         {:ok, view} <- ForgeRepos.repository_view(actor, repository),
         {:ok, filters} <- list_filters(conn.query_params),
         {:ok, page} <- ForgePulls.list_pull_requests(repository, actor, filters) do
      body = Enum.map(page.entries, &render_pull(conn, &1, owner, repo, actor, view))

      Response.paginated(conn, 200, body, page,
        url: request_path_with_query(conn),
        accepted_scopes: accepted_scopes
      )
    else
      {:error, reason} -> render_error(conn, reason, @index_url)
    end
  end

  def show(conn, %{"owner" => owner, "repo" => repo, "pull_number" => pull_number}) do
    actor = optional_actor(conn.assigns[:api_auth])

    with {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(conn.assigns[:api_auth], :repository_read, repository.visibility),
         conn <- Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes),
         {:ok, number} <- positive_integer(pull_number),
         {:ok, pull} <- ForgePulls.get_pull_request(repository, number, actor),
         {:ok, view} <- ForgeRepos.repository_view(actor, repository) do
      Response.json(conn, 200, render_pull(conn, pull, owner, repo, actor, view),
        accepted_scopes: accepted_scopes
      )
    else
      {:error, reason} -> render_error(conn, reason, @show_url)
    end
  end

  def create(conn, %{"owner" => owner, "repo" => repo}) do
    version = conn.assigns.api_version

    with {:ok, %{actor: actor} = authentication} <- require_auth(conn),
         {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(authentication, :repository_mutation, repository.visibility),
         conn <- Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes),
         {:ok, view} <- ForgeRepos.repository_view(actor, repository) do
      case read_authorized_body(conn, accepted_scopes) do
        {:ok, body, body_conn} ->
          with {:ok, attrs} <- RequestValidator.validate(version, :pull_create, body),
               {:ok, pull} <-
                 ForgePulls.create_pull_request(
                   repository,
                   actor,
                   attrs,
                   RequestContext.metadata(body_conn)
                 ) do
            Response.json(body_conn, 201, render_pull(body_conn, pull, owner, repo, actor, view),
              accepted_scopes: accepted_scopes
            )
          else
            {:error, reason} -> render_error(body_conn, reason, @create_url)
          end

        {:error, %Error{} = error, _reason, body_conn} ->
          Response.error(body_conn, error)
      end
    else
      {:error, reason} -> render_error(conn, reason, @create_url)
    end
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "pull_number" => pull_number}) do
    version = conn.assigns.api_version

    with {:ok, %{actor: actor} = authentication} <- require_auth(conn),
         {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(authentication, :repository_mutation, repository.visibility),
         conn <- Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes),
         {:ok, number} <- positive_integer(pull_number),
         {:ok, pull} <- ForgePulls.get_pull_request(repository, number, actor),
         {:ok, view} <- ForgeRepos.repository_view(actor, repository) do
      case read_authorized_body(conn, accepted_scopes) do
        {:ok, body, body_conn} ->
          with {:ok, attrs} <- RequestValidator.validate(version, :pull_update, body),
               {:ok, updated} <-
                 ForgePulls.update_pull_request(
                   repository,
                   pull,
                   actor,
                   attrs,
                   RequestContext.metadata(body_conn)
                 ) do
            Response.json(
              body_conn,
              200,
              render_pull(body_conn, updated, owner, repo, actor, view),
              accepted_scopes: accepted_scopes
            )
          else
            {:error, reason} -> render_error(body_conn, reason, @update_url)
          end

        {:error, %Error{} = error, _reason, body_conn} ->
          Response.error(body_conn, error)
      end
    else
      {:error, reason} -> render_error(conn, reason, @update_url)
    end
  end

  defp list_filters(params) do
    with {:ok, pagination} <- Pagination.parse(params),
         {:ok, state} <- enum(params, "state", :open, ~w(open closed all)),
         {:ok, head} <- optional_string(params, "head"),
         {:ok, base} <- optional_string(params, "base"),
         {:ok, sort} <-
           enum(params, "sort", :created, ~w(created updated popularity long-running)),
         {:ok, direction} <- enum(params, "direction", nil, ~w(asc desc)) do
      filters = pagination ++ [state: state, head: head, base: base, sort: sort]
      {:ok, if(is_nil(direction), do: filters, else: filters ++ [direction: direction])}
    end
  end

  defp enum(params, field, default, values) do
    case Map.get(params, field) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if value in values,
          do: {:ok, String.replace(value, "-", "_") |> String.to_existing_atom()},
          else: validation(field)

      _ ->
        validation(field)
    end
  end

  defp optional_string(params, field) do
    case Map.get(params, field) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> validation(field)
    end
  end

  defp validation(field),
    do: {:error, {:validation, [%{resource: "PullRequest", field: field, code: :invalid}]}}

  defp authorized_repository(actor, owner, repo),
    do: ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read)

  defp render_pull(conn, pull, owner, repo, actor, view) do
    Serializer.render(conn.assigns.api_version, :pull, pull,
      owner: owner,
      repo: repo,
      actor: actor,
      repository_view: view
    )
  end

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
