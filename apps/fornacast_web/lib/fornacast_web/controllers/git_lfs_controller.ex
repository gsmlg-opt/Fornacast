defmodule FornacastWeb.GitLFSController do
  use FornacastWeb, :controller

  alias ForgeAccounts.APIScope
  alias ForgeRepos.Repository
  alias GitLFS.{Principal, TransferToken}

  @lfs_json "application/vnd.git-lfs+json"
  @object_content_type "application/octet-stream"
  @max_batch_bytes 1_048_576
  @max_verify_bytes 65_536
  @read_chunk_bytes 1_048_576

  def batch(conn, %{"owner" => owner, "repo_dot_git" => repo_dot_git}) do
    with :ok <- require_media_type(conn, @lfs_json) do
      case read_full_body(conn, @max_batch_bytes) do
        {:ok, body, conn} -> process_batch(conn, owner, repo_dot_git, body)
        {:error, reason, conn} -> send_lfs_error(conn, reason)
      end
    else
      {:error, reason} -> send_lfs_error(conn, reason)
    end
  end

  def upload(conn, %{"owner" => owner, "repo_dot_git" => repo_dot_git, "oid" => oid}) do
    with :ok <- require_media_type(conn, @object_content_type),
         {:ok, size} <- content_length(conn),
         {:ok, principal, authorized_repository, _token} <-
           authenticate_object(conn, :upload, oid, size),
         {:ok, repository} <-
           bind_requested_repository(owner, repo_dot_git, principal, authorized_repository) do
      perform_upload(conn, repository, oid, size)
    else
      {:error, reason} -> send_lfs_error(conn, reason)
    end
  end

  def verify(conn, %{"owner" => owner, "repo_dot_git" => repo_dot_git, "oid" => oid}) do
    with :ok <- require_media_type(conn, @lfs_json) do
      case read_full_body(conn, @max_verify_bytes) do
        {:ok, body, conn} -> process_verify(conn, owner, repo_dot_git, oid, body)
        {:error, reason, conn} -> send_lfs_error(conn, reason)
      end
    else
      {:error, reason} -> send_lfs_error(conn, reason)
    end
  end

  def download(conn, %{"owner" => owner, "repo_dot_git" => repo_dot_git, "oid" => oid}) do
    with {:ok, principal, authorized_repository, token} <-
           authenticate_object(conn, :download, oid),
         {:ok, repository} <-
           bind_requested_repository(owner, repo_dot_git, principal, authorized_repository),
         {:ok, %{size: total_size}} <- GitLFS.object_metadata(repository, oid),
         {:ok, _principal, _repository} <-
           TransferToken.verify(token, :object, :download, oid, object_size: total_size),
         {:ok, range, status, headers} <- requested_range(conn, total_size),
         {:ok, source, metadata} <- GitLFS.open_object(repository, oid, total_size, range) do
      conn
      |> put_resp_header("accept-ranges", "bytes")
      |> put_download_headers(headers, metadata)
      |> put_resp_content_type(@object_content_type)
      |> stream_source(status, source)
    else
      {:error, reason} -> send_lfs_error(conn, reason)
    end
  end

  defp process_batch(conn, owner, repo_dot_git, body) do
    with {:ok, request} <- decode_object(body),
         {:ok, operation} <- batch_operation(request),
         {:ok, principal, api_key, authorized_repository} <-
           authenticate_batch(conn, operation),
         {:ok, repository} <-
           bind_requested_repository(owner, repo_dot_git, principal, authorized_repository),
         :ok <- authorize(principal, api_key, repository, operation),
         {:ok, response} <-
           GitLFS.batch(repository, principal, request, Fornacast.Config.base_url()) do
      send_lfs_json(conn, 200, response)
    else
      {:error, reason} -> send_lfs_error(conn, reason)
    end
  end

  defp process_verify(conn, owner, repo_dot_git, oid, body) do
    with {:ok, %{"oid" => ^oid, "size" => size}} <- decode_object(body),
         true <- is_integer(size) and size >= 0,
         {:ok, principal, authorized_repository, _token} <-
           authenticate_object(conn, :verify, oid, size),
         {:ok, repository} <-
           bind_requested_repository(owner, repo_dot_git, principal, authorized_repository),
         :ok <- GitLFS.verify_object(repository, oid, size) do
      send_lfs_json(conn, 200, %{})
    else
      false -> send_lfs_error(conn, :invalid_request)
      {:error, reason} -> send_lfs_error(conn, reason)
      _invalid -> send_lfs_error(conn, :invalid_request)
    end
  end

  defp perform_upload(conn, repository, oid, size) do
    case GitLFS.with_upload_lock(repository, oid, fn ->
           perform_locked_upload(conn, repository, oid, size)
         end) do
      %Plug.Conn{} = conn -> conn
      {:error, reason} -> send_lfs_error(conn, reason)
    end
  end

  defp perform_locked_upload(conn, repository, oid, size) do
    case GitLFS.reserve_upload(repository, oid, size) do
      {:ok, :already_present} ->
        send_resp(conn, 200, "")

      {:ok, reservation} ->
        recover_or_stage_upload(conn, reservation)

      {:error, reason} ->
        send_lfs_error(conn, reason)
    end
  end

  defp recover_or_stage_upload(conn, reservation) do
    case GitLFS.recover_upload(reservation) do
      {:ok, staged} ->
        commit_upload(conn, staged)

      {:error, :not_found} ->
        stage_upload(conn, reservation)

      {:error, reason} when reason in [:integrity_mismatch, :invalid_source] ->
        case GitLFS.cleanup_upload(reservation) do
          :ok -> stage_upload(conn, reservation)
          {:error, cleanup_reason} -> send_lfs_error(conn, cleanup_reason)
        end

      {:error, reason} ->
        send_lfs_error(conn, reason)
    end
  end

  defp stage_upload(conn, reservation) do
    case GitLFS.stage_upload(reservation, &read_upload_chunk/2, %{conn: conn, done: false}) do
      {:ok, staged, %{conn: conn}} ->
        commit_upload(conn, staged)

      {:error, :size_mismatch, %{conn: conn}} ->
        send_resp(conn, 422, "Object size does not match.\n")

      {:error, :sha256_mismatch, %{conn: conn}} ->
        send_resp(conn, 422, "Object SHA-256 does not match.\n")

      {:error, reason, %{conn: conn}} ->
        send_lfs_error(conn, reason)
    end
  end

  defp commit_upload(conn, staged) do
    case GitLFS.commit_upload(staged) do
      {:ok, _object} -> send_resp(conn, 200, "")
      {:error, reason} -> send_lfs_error(conn, reason)
    end
  end

  defp read_upload_chunk(%{done: true} = state, _options), do: {:done, state}

  defp read_upload_chunk(%{conn: conn} = state, options) do
    length = min(Keyword.get(options, :length, @read_chunk_bytes), @read_chunk_bytes)
    read_timeout = Keyword.get(options, :read_timeout, 15_000)

    case Plug.Conn.read_body(conn,
           length: length,
           read_length: length,
           read_timeout: read_timeout
         ) do
      {:more, chunk, conn} -> {:more, chunk, %{state | conn: conn}}
      {:ok, "", conn} -> {:done, %{state | conn: conn, done: true}}
      {:ok, chunk, conn} -> {:more, chunk, %{state | conn: conn, done: true}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp authenticate_batch(conn, operation) do
    case get_req_header(conn, "authorization") do
      [] -> {:ok, Principal.anonymous(), nil, nil}
      [authorization] -> authenticate_batch_authorization(authorization, operation)
      _multiple -> {:error, :invalid_credentials}
    end
  end

  defp authenticate_batch_authorization(authorization, operation) do
    cond do
      match = Regex.run(~r/^[ \t]*basic[ \t]+(\S+)[ \t]*\z/i, authorization) ->
        with {:ok, principal, api_key} <- authenticate_basic(Enum.at(match, 1)) do
          {:ok, principal, api_key, nil}
        end

      match = Regex.run(~r/^[ \t]*bearer[ \t]+(\S+)[ \t]*\z/i, authorization) ->
        with {:ok, principal, authorized_repository} <-
               TransferToken.verify(Enum.at(match, 1), :batch, operation, nil) do
          {:ok, principal, nil, authorized_repository}
        end

      true ->
        {:error, :invalid_credentials}
    end
  end

  defp authenticate_basic(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [username, secret] <- String.split(decoded, ":", parts: 2) do
      case secret do
        "fc_pat_" <> _ ->
          with {:ok, actor, api_key} <- ForgeAccounts.authenticate_api_key(username, secret) do
            {:ok, Principal.api_key(actor, api_key), api_key}
          end

        password ->
          with {:ok, actor} <- ForgeAccounts.authenticate_password(username, password) do
            {:ok, Principal.password(actor), :password}
          end
      end
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp authenticate_object(conn, operation, oid, object_size \\ nil) do
    with [authorization] <- get_req_header(conn, "authorization"),
         [_, token] <- Regex.run(~r/^[ \t]*bearer[ \t]+(\S+)[ \t]*\z/i, authorization),
         {:ok, principal, authorized_repository} <-
           TransferToken.verify(token, :object, operation, oid, object_size: object_size) do
      {:ok, principal, authorized_repository, token}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp authorize(principal, api_key, repository, operation) do
    permission = if operation == :upload, do: :repository_write, else: :repository_read

    with :ok <- Fornacast.Access.authorize(principal.actor, permission, repository),
         :ok <- authorize_api_key(api_key, operation, repository.visibility) do
      :ok
    else
      {:error, :unauthorized} -> {:error, authorization_error(principal)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_api_key(nil, :download, :public), do: :ok
  defp authorize_api_key(nil, _operation, _visibility), do: :ok
  defp authorize_api_key(:password, _operation, _visibility), do: :ok

  defp authorize_api_key(api_key, :download, visibility),
    do: APIScope.authorize(api_key, :git_read, visibility)

  defp authorize_api_key(api_key, :upload, visibility),
    do: APIScope.authorize(api_key, :git_write, visibility)

  defp authorization_error(%Principal{actor: nil}), do: :invalid_credentials
  defp authorization_error(%Principal{}), do: :not_found

  defp load_repository(owner, repo_dot_git) do
    with {:ok, slug} <- git_repo_slug(repo_dot_git),
         %Repository{} = repository <- ForgeRepos.get_repository(owner, slug) do
      {:ok, repository}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp bind_requested_repository(owner, repo_dot_git, principal, authorized_repository) do
    case load_repository(owner, repo_dot_git) do
      {:ok, repository} ->
        if is_nil(authorized_repository) or same_repository?(authorized_repository, repository),
          do: {:ok, repository},
          else: {:error, :not_found}

      {:error, :not_found} when is_nil(authorized_repository) ->
        {:error, authorization_error(principal)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp git_repo_slug(repo_dot_git) when is_binary(repo_dot_git) do
    if String.ends_with?(repo_dot_git, ".git") and byte_size(repo_dot_git) > 4,
      do: {:ok, String.replace_suffix(repo_dot_git, ".git", "")},
      else: {:error, :not_found}
  end

  defp same_repository?(left, right),
    do: left.id == right.id and left.generation == right.generation

  defp batch_operation(%{"operation" => "download"}), do: {:ok, :download}
  defp batch_operation(%{"operation" => "upload"}), do: {:ok, :upload}
  defp batch_operation(_request), do: {:error, :invalid_request}

  defp content_length(conn) do
    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 -> {:ok, size}
          _invalid -> {:error, :invalid_request}
        end

      _missing ->
        {:error, :invalid_request}
    end
  end

  defp require_media_type(conn, expected) do
    case get_req_header(conn, "content-type") do
      [value] ->
        value
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()
        |> then(fn actual ->
          if actual == expected, do: :ok, else: {:error, :unsupported_media_type}
        end)

      _missing ->
        {:error, :unsupported_media_type}
    end
  end

  defp decode_object(body) do
    case JSON.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _invalid -> {:error, :invalid_request}
    end
  end

  defp read_full_body(conn, max_bytes), do: read_full_body(conn, max_bytes, 0, [])

  defp read_full_body(conn, max_bytes, total, chunks) do
    case read_body(conn, length: min(max_bytes + 1, @read_chunk_bytes)) do
      {:more, chunk, conn} ->
        continue_full_body(conn, max_bytes, total, chunks, chunk)

      {:ok, chunk, conn} ->
        size = total + byte_size(chunk)

        if size <= max_bytes,
          do: {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn},
          else: {:error, :request_too_large, conn}

      {:error, _reason} ->
        {:error, :unavailable, conn}
    end
  end

  defp continue_full_body(conn, max_bytes, total, chunks, chunk) do
    size = total + byte_size(chunk)

    if size <= max_bytes,
      do: read_full_body(conn, max_bytes, size, [chunk | chunks]),
      else: {:error, :request_too_large, conn}
  end

  defp requested_range(conn, total_size) do
    case get_req_header(conn, "range") do
      [] -> {:ok, :all, 200, []}
      [header] -> parse_range(header, total_size)
      _multiple -> {:error, :invalid_range}
    end
  end

  defp parse_range("bytes=" <> range, total_size) when total_size > 0 do
    case String.split(range, "-", parts: 2) do
      [start_text, end_text] when start_text != "" ->
        with {start, ""} <- Integer.parse(start_text),
             true <- start >= 0 and start < total_size,
             {:ok, finish} <- range_finish(end_text, total_size),
             true <- finish >= start do
          length = finish - start + 1

          {:ok, {start, length}, 206,
           [{"content-range", "bytes #{start}-#{finish}/#{total_size}"}]}
        else
          _invalid -> {:error, :invalid_range}
        end

      ["", suffix_text] ->
        with {suffix, ""} <- Integer.parse(suffix_text),
             true <- suffix > 0 do
          length = min(suffix, total_size)
          start = total_size - length

          {:ok, {start, length}, 206,
           [{"content-range", "bytes #{start}-#{total_size - 1}/#{total_size}"}]}
        else
          _invalid -> {:error, :invalid_range}
        end

      _invalid ->
        {:error, :invalid_range}
    end
  end

  defp parse_range(_header, _total_size), do: {:error, :invalid_range}

  defp range_finish("", total_size), do: {:ok, total_size - 1}

  defp range_finish(value, total_size) do
    case Integer.parse(value) do
      {finish, ""} when finish >= 0 -> {:ok, min(finish, total_size - 1)}
      _invalid -> {:error, :invalid_range}
    end
  end

  defp put_download_headers(conn, headers, metadata) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc -> put_resp_header(acc, key, value) end)

    put_resp_header(conn, "content-length", Integer.to_string(metadata.size))
  end

  defp stream_source(conn, status, source) do
    conn = send_chunked(conn, status)

    try do
      do_stream_source(conn, source)
    after
      GitLFS.close(source)
    end
  end

  defp do_stream_source(conn, source) do
    case GitLFS.read(source, @read_chunk_bytes) do
      {:ok, bytes, next_source} ->
        case chunk(conn, bytes) do
          {:ok, conn} -> do_stream_source(conn, next_source)
          {:error, _reason} -> conn
        end

      :eof ->
        conn

      {:error, reason} ->
        exit({:git_lfs_download_failed, reason})
    end
  end

  defp send_lfs_json(conn, status, value) do
    conn
    |> put_resp_content_type(@lfs_json)
    |> send_resp(status, JSON.encode!(value))
  end

  defp send_lfs_error(conn, :not_found),
    do: send_resp(conn, 404, "Repository or object not found.\n")

  defp send_lfs_error(conn, reason) when reason in [:invalid_credentials, :unauthorized] do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Fornacast Git LFS"))
    |> send_resp(401, "Authentication required.\n")
  end

  defp send_lfs_error(conn, :insufficient_scope),
    do: send_resp(conn, 403, "Insufficient API key scope.\n")

  defp send_lfs_error(conn, :unsupported_media_type),
    do: send_resp(conn, 415, "Unsupported Git LFS content type.\n")

  defp send_lfs_error(conn, reason) when reason in [:request_too_large, :too_many_objects],
    do: send_resp(conn, 413, "Git LFS request is too large.\n")

  defp send_lfs_error(conn, :invalid_range),
    do: send_resp(conn, 416, "Requested range is not satisfiable.\n")

  defp send_lfs_error(conn, reason)
       when reason in [
              :invalid_request,
              :unsupported_hash_algorithm,
              :unsupported_transfer,
              :invalid_source
            ],
       do: send_lfs_json(conn, 400, %{"message" => "Invalid Git LFS request"})

  defp send_lfs_error(conn, :size_mismatch),
    do: send_resp(conn, 422, "Object size does not match.\n")

  defp send_lfs_error(conn, :sha256_mismatch),
    do: send_resp(conn, 422, "Object SHA-256 does not match.\n")

  defp send_lfs_error(conn, _reason),
    do: send_resp(conn, 503, "Git LFS service temporarily unavailable.\n")
end
