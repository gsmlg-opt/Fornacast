defmodule FornacastWeb.GitHTTPController do
  use FornacastWeb, :controller

  alias ForgeRepos.Repository

  @upload_pack_advertisement_type "application/x-git-upload-pack-advertisement"
  @upload_pack_result_type "application/x-git-upload-pack-result"

  def info_refs(conn, %{
        "owner" => owner_slug,
        "repo_dot_git" => repo_dot_git,
        "service" => "git-upload-pack"
      }) do
    with {:ok, repo_slug} <- git_repo_slug(repo_dot_git),
         {:ok, _actor, %Repository{} = repository} <-
           load_readable_repository(conn, owner_slug, repo_slug),
         {:ok, advertisement} <- GitTransport.UploadPack.advertise_refs(repository) do
      conn
      |> send_git_response(@upload_pack_advertisement_type, [
        GitTransport.PktLine.encode("# service=git-upload-pack\n"),
        GitTransport.PktLine.flush(),
        advertisement
      ])
    else
      {:error, reason} -> send_git_error(conn, reason)
    end
  end

  def info_refs(conn, _params), do: send_resp(conn, 400, "Unsupported Git service.\n")

  def upload_pack(conn, %{"owner" => owner_slug, "repo_dot_git" => repo_dot_git}) do
    with {:ok, repo_slug} <- git_repo_slug(repo_dot_git),
         {:ok, _actor, %Repository{} = repository} <-
           load_readable_repository(conn, owner_slug, repo_slug),
         {:ok, body, conn} <- read_full_body(conn),
         {:ok, request} <- parse_upload_pack_request(body),
         {:ok, response} <- GitTransport.UploadPack.response(repository, request) do
      send_git_response(conn, @upload_pack_result_type, response)
    else
      {:error, reason} -> send_git_error(conn, reason)
    end
  end

  defp load_readable_repository(conn, owner_slug, repo_slug) do
    with %Repository{} = repository <- ForgeRepos.get_repository(owner_slug, repo_slug),
         {:ok, actor} <- authenticate_actor(conn),
         :ok <- Fornacast.Access.authorize(actor, :repository_read, repository) do
      {:ok, actor, repository}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_repo_slug(repo_dot_git) do
    if String.ends_with?(repo_dot_git, ".git") do
      {:ok, String.replace_suffix(repo_dot_git, ".git", "")}
    else
      {:error, :not_found}
    end
  end

  defp authenticate_actor(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] -> authenticate_basic(encoded)
      ["basic " <> encoded] -> authenticate_basic(encoded)
      _ -> {:ok, nil}
    end
  end

  defp authenticate_basic(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [username, personal_api_key] <- String.split(decoded, ":", parts: 2),
         {:ok, user, _api_key} <-
           ForgeAccounts.authenticate_api_key(username, personal_api_key, "repo:read") do
      {:ok, user}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  defp read_full_body(conn, acc \\ []) do
    case read_body(conn) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        read_full_body(conn, [chunk | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_upload_pack_request(body) do
    case GitTransport.UploadPack.parse_request_data(body) do
      {:done, _rest, request} -> {:ok, request}
      {:cont, _buffer, _request} -> {:error, :incomplete_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_git_response(conn, content_type, body) do
    conn
    |> put_resp_header("content-type", content_type)
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, IO.iodata_to_binary(body))
  end

  defp send_git_error(conn, :not_found), do: send_resp(conn, 404, "Repository not found.\n")

  defp send_git_error(conn, reason) when reason in [:unauthorized, :invalid_credentials] do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Fornacast Git"))
    |> send_resp(401, "Authentication required.\n")
  end

  defp send_git_error(conn, :incomplete_request),
    do: send_resp(conn, 400, "Incomplete Git request.\n")

  defp send_git_error(conn, reason) when is_binary(reason), do: send_resp(conn, 400, reason)
  defp send_git_error(conn, _reason), do: send_resp(conn, 500, "Git HTTP request failed.\n")
end
