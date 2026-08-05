defmodule FornacastAPI.IssueController do
  use FornacastAPI, :controller

  alias ForgeAccounts.APIScope
  alias ForgeIssues
  alias ForgeRepos

  alias FornacastAPI.{
    Authentication,
    Error,
    IssueContract,
    RequestBody,
    RequestValidator,
    Response,
    Serializer,
    URL
  }

  alias FornacastAPI.Plugs.RequestContext

  @index_url "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#list-repository-issues"
  @create_url "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#create-an-issue"
  @show_url "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#get-an-issue"
  @update_url "https://docs.github.com/en/enterprise-server@3.21/rest/issues/issues#update-an-issue"

  def index(conn, %{"owner" => owner, "repo" => repo}) do
    conn = fetch_query_params(conn)
    actor = optional_actor(conn.assigns[:api_auth])

    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read),
         {:ok, accepted_scopes} <-
           authorize_scope(conn.assigns[:api_auth], :repository_read, repository.visibility) do
      conn = Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes)

      with {:ok, filters} <- IssueContract.list_filters(conn.query_params),
           {:ok, page} <- ForgeIssues.list(actor, owner, repo, Map.new(filters)) do
        body =
          Enum.map(
            page.entries,
            &Serializer.render(conn.assigns.api_version, :issue, &1, owner: owner, repo: repo)
          )

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

  def show(conn, %{"owner" => owner, "repo" => repo, "issue_number" => issue_number}) do
    actor = optional_actor(conn.assigns[:api_auth])

    with {:ok, number} <- positive_integer(issue_number),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read),
         {:ok, accepted_scopes} <-
           authorize_scope(conn.assigns[:api_auth], :repository_read, repository.visibility) do
      conn = Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes)

      case ForgeIssues.get(actor, owner, repo, number) do
        {:ok, issue} ->
          Response.json(
            conn,
            200,
            Serializer.render(conn.assigns.api_version, :issue, issue, owner: owner, repo: repo),
            accepted_scopes: accepted_scopes
          )

        {:error, reason} ->
          render_error(conn, reason, @show_url)
      end
    else
      {:error, reason} -> render_error(conn, reason, @show_url)
    end
  end

  def create(conn, %{"owner" => owner, "repo" => repo}) do
    mutate(
      conn,
      owner,
      repo,
      :issue_create,
      @create_url,
      fn actor, attrs, metadata ->
        ForgeIssues.create(actor, owner, repo, attrs, metadata)
      end,
      201
    )
  end

  def update(conn, %{"owner" => owner, "repo" => repo, "issue_number" => issue_number}) do
    with {:ok, number} <- positive_integer(issue_number) do
      mutate(
        conn,
        owner,
        repo,
        :issue_update,
        @update_url,
        fn actor, attrs, metadata ->
          ForgeIssues.update(actor, owner, repo, number, attrs, metadata)
        end,
        200
      )
    else
      {:error, reason} -> render_error(conn, reason, @update_url)
    end
  end

  defp mutate(conn, owner, repo, operation, documentation_url, operation_fun, status) do
    version = conn.assigns.api_version

    with {:ok, %{actor: actor} = authentication} <- require_auth(conn),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read),
         {:ok, accepted_scopes} <-
           authorize_scope(authentication, :repository_mutation, repository.visibility) do
      conn = Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes)

      with {:ok, body, conn} <- read_authorized_body(conn, accepted_scopes),
           {:ok, attrs} <- RequestValidator.validate(version, operation, body),
           {:ok, issue} <- operation_fun.(actor, attrs, RequestContext.metadata(conn)) do
        Response.json(
          conn,
          status,
          Serializer.render(version, :issue, issue, owner: owner, repo: repo),
          accepted_scopes: accepted_scopes
        )
      else
        {:error, %Error{} = error, _reason, body_conn} -> Response.error(body_conn, error)
        {:error, reason} -> render_error(conn, reason, documentation_url)
      end
    else
      {:error, reason} -> render_error(conn, reason, documentation_url)
    end
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
