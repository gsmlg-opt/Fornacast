defmodule FornacastAPI.PullMergeController do
  use FornacastAPI, :controller

  alias ForgeAccounts.APIScope
  alias ForgePulls
  alias ForgeRepos

  alias FornacastAPI.{Authentication, Error, RequestBody, RequestValidator, Response, Serializer}
  alias FornacastAPI.Plugs.RequestContext

  @check_url "https://docs.github.com/en/enterprise-server@3.21/rest/pulls/pulls#check-if-a-pull-request-has-been-merged"
  @merge_url "https://docs.github.com/en/enterprise-server@3.21/rest/pulls/pulls#merge-a-pull-request"

  def check(conn, %{"owner" => owner, "repo" => repo, "pull_number" => pull_number}) do
    actor = optional_actor(conn.assigns[:api_auth])

    with {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(conn.assigns[:api_auth], :repository_read, repository.visibility),
         conn <- Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes),
         {:ok, number} <- positive_integer(pull_number),
         {:ok, pull} <- ForgePulls.get_pull_request(repository, number, actor) do
      case ForgePulls.merged?(repository, pull, actor) do
        {:ok, true} -> Response.no_content(conn, accepted_scopes: accepted_scopes)
        {:ok, false} -> render_error(conn, :not_found, @check_url)
        {:error, reason} -> render_error(conn, reason, @check_url)
      end
    else
      {:error, reason} -> render_error(conn, reason, @check_url)
    end
  end

  def merge(conn, %{"owner" => owner, "repo" => repo, "pull_number" => pull_number}) do
    version = conn.assigns.api_version

    with {:ok, %{actor: actor} = authentication} <- require_auth(conn),
         {:ok, repository} <- authorized_repository(actor, owner, repo),
         {:ok, accepted_scopes} <-
           authorize_scope(authentication, :repository_mutation, repository.visibility),
         conn <- Plug.Conn.assign(conn, :accepted_scopes, accepted_scopes),
         {:ok, number} <- positive_integer(pull_number),
         {:ok, pull} <- ForgePulls.get_pull_request(repository, number, actor) do
      case read_authorized_body(conn, accepted_scopes) do
        {:ok, body, body_conn} ->
          with {:ok, attrs} <- RequestValidator.validate(version, :pull_merge, body),
               {:ok, result} <-
                 ForgePulls.merge(
                   repository,
                   pull,
                   actor,
                   attrs,
                   request_metadata(body_conn)
                 ) do
            Response.json(body_conn, 200, Serializer.render(version, :pull_merge, result),
              accepted_scopes: accepted_scopes
            )
          else
            {:error, reason} -> render_error(body_conn, reason, @merge_url)
          end

        {:error, %Error{} = error, _reason, body_conn} ->
          Response.error(body_conn, error)
      end
    else
      {:error, reason} -> render_error(conn, reason, @merge_url)
    end
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

  defp request_metadata(conn) do
    case RequestContext.metadata(conn) do
      %{token_id: token_id} = metadata when is_integer(token_id) ->
        %{metadata | token_id: Integer.to_string(token_id)}

      metadata ->
        metadata
    end
  end
end
