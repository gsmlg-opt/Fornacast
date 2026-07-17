defmodule FornacastWeb.GitHTTPController do
  use FornacastWeb, :controller

  alias ForgeRepos.Repository

  @upload_pack_advertisement_type "application/x-git-upload-pack-advertisement"
  @upload_pack_result_type "application/x-git-upload-pack-result"
  @receive_pack_advertisement_type "application/x-git-receive-pack-advertisement"
  @receive_pack_request_type "application/x-git-receive-pack-request"
  @receive_pack_result_type "application/x-git-receive-pack-result"
  @default_receive_pack_max_bytes 100 * 1024 * 1024

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

  def info_refs(conn, %{
        "owner" => owner_slug,
        "repo_dot_git" => repo_dot_git,
        "service" => "git-receive-pack"
      }) do
    with {:ok, repo_slug} <- git_repo_slug(repo_dot_git),
         {:ok, _actor, %Repository{} = repository} <-
           load_writable_repository(conn, owner_slug, repo_slug),
         {:ok, advertisement} <- GitTransport.ReceivePack.advertise_refs(repository) do
      conn
      |> send_git_response(@receive_pack_advertisement_type, [
        GitTransport.PktLine.encode("# service=git-receive-pack\n"),
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
         {:ok, body, conn} <- read_full_body_unlimited(conn),
         {:ok, request} <- parse_upload_pack_request(body),
         {:ok, response} <- GitTransport.UploadPack.response(repository, request) do
      send_git_response(conn, @upload_pack_result_type, response)
    else
      {:error, reason} -> send_git_error(conn, reason)
    end
  end

  def receive_pack(conn, %{"owner" => owner_slug, "repo_dot_git" => repo_dot_git}) do
    with {:ok, repo_slug} <- git_repo_slug(repo_dot_git),
         {:ok, actor, %Repository{} = repository} <-
           load_writable_repository(conn, owner_slug, repo_slug),
         :ok <- validate_receive_pack_content_type(conn),
         {:ok, body, conn} <- read_full_body(conn, receive_pack_max_bytes()),
         {:ok, request, pack} <- parse_receive_pack_request(body),
         {:ok, response, statuses} <-
           GitTransport.ReceivePack.response(repository, request, pack),
         :ok <- GitTransport.ReceivePack.record_push(actor, repository, statuses) do
      send_git_response(conn, @receive_pack_result_type, response)
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

  defp load_writable_repository(conn, owner_slug, repo_slug) do
    with {:ok, actor} <- authenticate_actor(conn, "repo:write"),
         %Repository{} = repository <- ForgeRepos.get_repository(owner_slug, repo_slug),
         :ok <- authorize_repository_write(actor, repository) do
      {:ok, actor, repository}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_repository_write(actor, repository) do
    case Fornacast.Access.authorize(actor, :repository_write, repository) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, :not_found}
    end
  end

  defp git_repo_slug(repo_dot_git) do
    if String.ends_with?(repo_dot_git, ".git") do
      {:ok, String.replace_suffix(repo_dot_git, ".git", "")}
    else
      {:error, :not_found}
    end
  end

  defp authenticate_actor(conn), do: authenticate_actor(conn, "repo:read")

  defp authenticate_actor(conn, scope) do
    case get_req_header(conn, "authorization") do
      [] when scope == "repo:read" -> {:ok, nil}
      [] -> {:error, :invalid_credentials}
      [authorization] -> authenticate_authorization(authorization, scope)
      _ -> {:error, :invalid_credentials}
    end
  end

  defp authenticate_authorization(authorization, scope) do
    case Regex.run(~r/^[ \t]*basic[ \t]+(\S+)[ \t]*$/i, authorization, capture: :all_but_first) do
      [encoded] -> authenticate_basic(encoded, scope)
      _ -> {:error, :invalid_credentials}
    end
  end

  defp authenticate_basic(encoded, scope) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [username, personal_api_key] <- String.split(decoded, ":", parts: 2),
         {:ok, user, _api_key} <-
           ForgeAccounts.authenticate_api_key(username, personal_api_key, scope) do
      {:ok, user}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  defp read_full_body_unlimited(conn, acc \\ []) do
    case read_body(conn) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        read_full_body_unlimited(conn, [chunk | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_full_body(conn, max_bytes), do: read_full_body(conn, max_bytes, 0, [])

  defp read_full_body(conn, max_bytes, bytes_read, acc) do
    case read_body(conn) do
      {:ok, chunk, conn} -> finish_body(chunk, conn, max_bytes, bytes_read, acc)
      {:more, chunk, conn} -> continue_body(chunk, conn, max_bytes, bytes_read, acc)
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_body(chunk, conn, max_bytes, bytes_read, acc) do
    if bytes_read + byte_size(chunk) > max_bytes do
      {:error, :request_too_large}
    else
      {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
    end
  end

  defp continue_body(chunk, conn, max_bytes, bytes_read, acc) do
    bytes_read = bytes_read + byte_size(chunk)

    if bytes_read > max_bytes do
      {:error, :request_too_large}
    else
      read_full_body(conn, max_bytes, bytes_read, [chunk | acc])
    end
  end

  defp receive_pack_max_bytes do
    case Application.get_env(:fornacast_web, :git_receive_pack_max_bytes) do
      max when is_integer(max) and max > 0 -> max
      _ -> @default_receive_pack_max_bytes
    end
  end

  defp validate_receive_pack_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        content_type = content_type |> String.split(";", parts: 2) |> hd() |> String.trim()

        if String.downcase(content_type) == @receive_pack_request_type,
          do: :ok,
          else: {:error, :unsupported_media_type}

      _ ->
        {:error, :unsupported_media_type}
    end
  end

  defp parse_upload_pack_request(body) do
    case GitTransport.UploadPack.parse_request_data(body) do
      {:done, _rest, request} -> {:ok, request}
      {:cont, _buffer, _request} -> {:error, :incomplete_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_receive_pack_request(body) do
    case GitTransport.ReceivePack.parse_request_data(body) do
      {:pack, pack, request} when pack != "" -> {:ok, request, pack}
      {:pack, _pack, _request} -> {:error, :incomplete_request}
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

  defp send_git_error(conn, :request_too_large),
    do: send_resp(conn, 413, "Git request is too large.\n")

  defp send_git_error(conn, :unsupported_media_type),
    do: send_resp(conn, 415, "Unsupported Git content type.\n")

  defp send_git_error(conn, reason) when is_binary(reason), do: send_resp(conn, 400, reason)
  defp send_git_error(conn, _reason), do: send_resp(conn, 500, "Git HTTP request failed.\n")
end
