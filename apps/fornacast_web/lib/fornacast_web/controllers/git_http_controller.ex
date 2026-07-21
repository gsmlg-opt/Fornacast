defmodule FornacastWeb.GitHTTPController do
  use FornacastWeb, :controller

  alias ForgeRepos.Repository

  @upload_pack_advertisement_type "application/x-git-upload-pack-advertisement"
  @upload_pack_result_type "application/x-git-upload-pack-result"
  @receive_pack_advertisement_type "application/x-git-receive-pack-advertisement"
  @receive_pack_request_type "application/x-git-receive-pack-request"
  @receive_pack_result_type "application/x-git-receive-pack-result"
  @default_upload_pack_max_bytes 1024 * 1024

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
         {:ok, body, conn} <- read_full_body(conn, upload_pack_max_bytes()),
         {:ok, body} <- decode_upload_pack_body(conn, body),
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
         {:ok, body, conn} <-
           read_full_body(conn, GitTransport.ReceivePack.max_request_bytes()),
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
    with {:ok, actor, api_key} <- authenticate_actor(conn, :read) do
      load_readable_repository_for_actor(actor, api_key, owner_slug, repo_slug)
    end
  end

  defp load_readable_repository_for_actor(actor, api_key, owner_slug, repo_slug) do
    case ForgeRepos.get_repository(owner_slug, repo_slug) do
      %Repository{} = repository -> authorize_repository_read(actor, api_key, repository)
      nil -> read_repository_not_found(actor)
    end
  end

  defp authorize_repository_read(actor, api_key, repository) do
    case Fornacast.Access.authorize(actor, :repository_read, repository) do
      :ok ->
        with :ok <- authorize_git_scope(api_key, :git_read, repository.visibility) do
          {:ok, actor, repository}
        end

      {:error, :unauthorized} ->
        read_repository_not_found(actor)
    end
  end

  defp read_repository_not_found(nil), do: {:error, :invalid_credentials}
  defp read_repository_not_found(_actor), do: {:error, :not_found}

  defp load_writable_repository(conn, owner_slug, repo_slug) do
    with {:ok, actor, api_key} <- authenticate_actor(conn, :write),
         %Repository{} = repository <- ForgeRepos.get_repository(owner_slug, repo_slug),
         :ok <- authorize_repository_write(actor, repository),
         :ok <- authorize_git_scope(api_key, :git_write, repository.visibility) do
      {:ok, actor, repository}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_git_scope(nil, :git_read, :public), do: :ok
  defp authorize_git_scope(nil, _action, _visibility), do: {:error, :invalid_credentials}

  defp authorize_git_scope(api_key, action, visibility) do
    ForgeAccounts.APIScope.authorize(api_key, action, visibility)
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

  defp authenticate_actor(conn, operation) do
    case get_req_header(conn, "authorization") do
      [] when operation == :read -> {:ok, nil, nil}
      [] -> {:error, :invalid_credentials}
      [authorization] -> authenticate_authorization(authorization)
      _ -> {:error, :invalid_credentials}
    end
  end

  defp authenticate_authorization(authorization) do
    case Regex.run(~r/^[ \t]*basic[ \t]+(\S+)[ \t]*\z/i, authorization, capture: :all_but_first) do
      [encoded] -> authenticate_basic(encoded)
      _ -> {:error, :invalid_credentials}
    end
  end

  defp authenticate_basic(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [username, "fc_pat_" <> _ = secret] <- String.split(decoded, ":", parts: 2),
         {:ok, user, api_key} <- ForgeAccounts.authenticate_api_key(username, secret) do
      {:ok, user, api_key}
    else
      _reason -> {:error, :invalid_credentials}
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

  defp upload_pack_max_bytes do
    case Application.get_env(:fornacast_web, :git_upload_pack_max_bytes) do
      max when is_integer(max) and max > 0 -> max
      _ -> @default_upload_pack_max_bytes
    end
  end

  defp decode_upload_pack_body(conn, body) do
    case get_req_header(conn, "content-encoding") do
      [] ->
        {:ok, body}

      [encoding] when is_binary(encoding) ->
        if String.downcase(String.trim(encoding)) == "gzip" do
          try do
            {:ok, :zlib.gunzip(body)}
          rescue
            ErlangError -> {:error, "ERROR: Invalid gzip request body.\n"}
          end
        else
          {:error, :unsupported_media_type}
        end

      _ ->
        {:error, :unsupported_media_type}
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

  defp send_git_error(conn, :insufficient_scope),
    do: send_resp(conn, 403, "Insufficient API key scope.\n")

  defp send_git_error(conn, :incomplete_request),
    do: send_resp(conn, 400, "Incomplete Git request.\n")

  defp send_git_error(conn, :request_too_large),
    do: send_resp(conn, 413, "Git request is too large.\n")

  defp send_git_error(conn, :unsupported_media_type),
    do: send_resp(conn, 415, "Unsupported Git content type.\n")

  defp send_git_error(conn, reason) when is_binary(reason), do: send_resp(conn, 400, reason)
  defp send_git_error(conn, _reason), do: send_resp(conn, 500, "Git HTTP request failed.\n")
end
