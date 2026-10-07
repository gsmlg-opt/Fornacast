defmodule FornacastWeb.ReleaseDownload do
  @moduledoc false
  import Plug.Conn

  def asset(conn, actor, owner, repo, asset) do
    case range(get_req_header(conn, "range"), asset.size) do
      {:ok, range} ->
        storage_range =
          case range do
            :all -> :all
            {first, last} -> {first, last - first + 1}
          end

        case ForgeReleases.open_asset(actor, owner, repo, asset.id, storage_range) do
          {:ok, asset, source} -> stream(conn, asset, source, range)
          {:error, reason} -> FornacastWeb.RepositoryWeb.error(conn, nil, reason)
        end

      :error ->
        conn |> put_resp_header("content-range", "bytes */#{asset.size}") |> send_resp(416, "")
    end
  end

  def disposition(name),
    do: "attachment; filename*=UTF-8''" <> URI.encode(name, &URI.char_unreserved?/1)

  def range([], _size), do: {:ok, :all}

  def range([value], size) when size > 0 and byte_size(value) <= 256 do
    case Regex.run(~r/\Abytes=([0-9]*)-([0-9]*)\z/, value) do
      [_, "", suffix] when suffix != "" ->
        suffix = String.to_integer(suffix)
        if suffix > 0, do: {:ok, {max(size - suffix, 0), size - 1}}, else: :error

      [_, first, last] when first != "" ->
        first = String.to_integer(first)
        last = if last == "", do: size - 1, else: min(String.to_integer(last), size - 1)
        if first < size and first <= last, do: {:ok, {first, last}}, else: :error

      _ ->
        :error
    end
  end

  def range(_headers, _size), do: :error

  defp stream(conn, asset, source, range) do
    {status, length} =
      case range do
        :all -> {200, asset.size}
        {first, last} -> {206, last - first + 1}
      end

    conn =
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", disposition(asset.name))
      |> put_resp_header("content-length", to_string(length))
      |> put_resp_content_type(asset.content_type)

    conn =
      case range do
        :all ->
          conn

        {first, last} ->
          put_resp_header(conn, "content-range", "bytes #{first}-#{last}/#{asset.size}")
      end

    try do
      conn = send_chunked(conn, status)

      case chunks(conn, source) do
        {:ok, conn} ->
          ForgeReleases.complete_asset_download(asset.id)
          conn

        {:error, conn} ->
          conn
      end
    after
      ForgeReleases.close_asset(source)
    end
  end

  defp chunks(conn, source) do
    case ForgeReleases.read_asset_chunk(source, 64_000) do
      {:ok, bytes, next} ->
        case chunk(conn, bytes) do
          {:ok, conn} -> chunks(conn, next)
          {:error, _} -> {:error, conn}
        end

      :eof ->
        {:ok, conn}

      {:error, _} ->
        {:error, conn}
    end
  end
end
