defmodule ForgeGitHub.ReleaseAssetClient do
  @moduledoc "Bounded release asset metadata and pull-driven binary downloads."

  alias ForgeGitHub.{Client, Error, RepositoryReference, RequestGate}
  alias ForgeGitHub.LFS.Transport

  @maximum_id 9_223_372_036_854_775_807
  @asset_keys ~w(id node_id name label content_type state size digest download_count created_at updated_at uploader)
  @redirect_hosts ~w(release-assets.githubusercontent.com objects.githubusercontent.com github-releases.githubusercontent.com)

  def list_assets_page(token, owner, repository, release_id, cursor, opts) do
    page = cursor || 1
    base = "/repos/#{owner}/#{repository}/releases/#{release_id}/assets"

    with true <- valid_repository?(owner, repository) and valid_id?(release_id),
         true <- is_integer(page) and page in 1..100,
         {:ok, %{json: assets, next_url: next_url}} <-
           Client.release_metadata_page(token, "#{base}?page=#{page}&per_page=100", opts),
         {:ok, assets} <- decode_assets(assets, token),
         {:ok, next_cursor} <- next_cursor(next_url, base, page) do
      {:ok, %{assets: assets, next_cursor: next_cursor}}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
      _ -> error(:invalid_request)
    end
  end

  def decode_asset(asset, token) when is_map(asset) do
    with true <- valid_id?(asset["id"]),
         true <- text?(asset["node_id"], 512, false),
         true <- filename?(asset["name"]),
         true <- text?(asset["label"], 1_020, true),
         true <- text?(asset["content_type"], 255, false),
         true <- not String.contains?(asset["content_type"], ["\r", "\n"]),
         true <- asset["state"] == "uploaded",
         true <- nonnegative?(asset["size"]) and nonnegative?(asset["download_count"]),
         true <- valid_digest?(asset["digest"]),
         {:ok, _, 0} <- datetime(asset["created_at"]),
         {:ok, _, 0} <- datetime(asset["updated_at"]),
         {:ok, uploader} <- uploader(asset["uploader"]),
         descriptor = asset |> Map.take(@asset_keys) |> Map.put("uploader", uploader),
         :ok <-
           ForgeAccounts.GitHubProfileSafety.validate(
             %{description: JSON.encode!(descriptor)},
             token
           ) do
      {:ok, descriptor}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def decode_asset(_, _), do: {:error, :invalid_response}

  def download(token, owner, repository, asset, consumer, opts) do
    with true <- is_binary(token) and byte_size(token) in 1..4_096,
         true <- valid_repository?(owner, repository),
         {:ok, asset} <- decode_asset(asset, token),
         true <- is_function(consumer, 2) do
      RequestGate.run(Keyword.get(opts, :gate_key), fn ->
        url = "https://api.github.com/repos/#{owner}/#{repository}/releases/assets/#{asset["id"]}"

        headers = [
          {"authorization", "Bearer " <> token},
          {"accept", "application/octet-stream"},
          {"accept-encoding", "identity"},
          {"user-agent", "Fornacast"},
          {"x-github-api-version", "2026-03-10"}
        ]

        deadline =
          System.monotonic_time(:millisecond) + Keyword.get(opts, :request_timeout, 300_000)

        do_download(url, headers, asset, consumer, opts, deadline, 0)
      end)
      |> normalize_gate_result()
    else
      _ -> error(:invalid_request)
    end
  end

  defp do_download(url, headers, asset, consumer, opts, deadline, redirects) do
    remaining = deadline - System.monotonic_time(:millisecond)
    digest = if asset["digest"], do: String.replace_prefix(asset["digest"], "sha256:", "")

    if remaining <= 0 do
      error(:timeout)
    else
      transport_opts =
        opts
        |> Keyword.take([:resolver, :transport_api])
        |> Keyword.put(:request_timeout, remaining)

      case Transport.request(
             :get,
             url,
             headers,
             {:consume_asset_download, consumer, asset["size"], digest},
             transport_opts
           ) do
        {:ok, %{status: 200}, {:ok, result}} ->
          {:ok, result}

        {:ok, %{status: status}, {:error, reason}} when status in [nil, 200] ->
          {:error, reason}

        {:ok, %{status: status, headers: response_headers}, _result}
        when status in [301, 302, 303, 307, 308] ->
          locations =
            for {key, value} <- response_headers, String.downcase(key) == "location", do: value

          with true <- redirects < 3,
               [location] <- locations,
               true <- safe_redirect?(location) do
            do_download(
              location,
              Enum.reject(headers, fn {key, _} -> key == "authorization" end),
              asset,
              consumer,
              opts,
              deadline,
              redirects + 1
            )
          else
            _ -> error(:unsafe_redirect)
          end

        {:ok, %{status: 401}, _} ->
          error(:invalid_credential)

        {:ok, %{status: 403}, _} ->
          error(:forbidden)

        {:ok, %{status: 404}, _} ->
          error(:not_found)

        {:ok, _, _} ->
          error(:upstream_unavailable)

        {:error, %Transport.Error{kind: kind}} ->
          error(kind)
      end
    end
  end

  defp safe_redirect?(url) when is_binary(url) and byte_size(url) <= 8_192 do
    case URI.new(url) do
      {:ok,
       %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil, path: path}} ->
        host in @redirect_hosts and is_binary(path) and String.starts_with?(path, "/")

      _ ->
        false
    end
  end

  defp safe_redirect?(_), do: false

  defp decode_assets(assets, token) when is_list(assets) and length(assets) <= 100 do
    Enum.reduce_while(assets, {:ok, []}, fn asset, {:ok, decoded} ->
      case decode_asset(asset, token) do
        {:ok, asset} -> {:cont, {:ok, [asset | decoded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_assets(_, _), do: {:error, :invalid_response}

  defp next_cursor(nil, _base, _page), do: {:ok, nil}
  defp next_cursor(_url, _base, 100), do: {:error, :pagination_limit}

  defp next_cursor(url, base, page) do
    with {:ok,
          %URI{scheme: nil, host: nil, path: ^base, userinfo: nil, fragment: nil, query: query}} <-
           URI.new(url),
         pairs <- URI.query_decoder(query) |> Enum.to_list(),
         true <- length(pairs) == 2,
         %{"page" => encoded, "per_page" => "100"} <- Map.new(pairs),
         true <- encoded == Integer.to_string(page + 1) do
      {:ok, page + 1}
    else
      _ -> {:error, :invalid_pagination}
    end
  rescue
    _ -> {:error, :invalid_pagination}
  end

  defp uploader(%{"id" => id, "node_id" => node_id, "login" => login}) do
    if valid_id?(id) and text?(node_id, 512, false) and text?(login, 105, false) and
         Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?(?:\[bot\])?$/, login),
       do: {:ok, %{"id" => id, "node_id" => node_id, "login" => login}},
       else: :error
  end

  defp uploader(_), do: :error

  defp filename?(name),
    do:
      text?(name, 255, false) and name not in [".", ".."] and
        not String.contains?(name, ["/", "\\", "\r", "\n"])

  defp valid_digest?(nil), do: true

  defp valid_digest?(digest) when is_binary(digest),
    do: Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, digest)

  defp valid_digest?(_), do: false
  defp text?(nil, _, true), do: true

  defp text?(text, max, nullable) when is_binary(text),
    do:
      String.valid?(text) and byte_size(text) <= max and :binary.match(text, <<0>>) == :nomatch and
        (nullable or text != "")

  defp text?(_, _, _), do: false
  defp valid_id?(id), do: is_integer(id) and id in 1..@maximum_id
  defp nonnegative?(value), do: is_integer(value) and value in 0..@maximum_id

  defp valid_repository?(owner, repository),
    do:
      RepositoryReference.valid_owner?(owner) and
        RepositoryReference.valid_repository?(repository)

  defp datetime(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp datetime(_), do: :error
  defp normalize_gate_result({:error, :busy}), do: error(:request_gate_busy)
  defp normalize_gate_result({:error, :invalid_gate_key}), do: error(:invalid_request)
  defp normalize_gate_result(result), do: result
  defp error(kind), do: {:error, %Error{kind: kind}}
end
