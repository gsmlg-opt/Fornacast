defmodule ForgeGitHub.LabelClient do
  @moduledoc "Installation-gated label creation and lookup for permanent issue label mappings."

  alias ForgeGitHub.{Client, Error, RepositoryReference}

  @max_page 2_147_483_647

  @doc "Reads at most 100 labels; the validated next cursor is never fetched eagerly."
  def list_labels_page(token, owner, repository, cursor, opts) do
    page = if is_nil(cursor), do: 1, else: cursor

    with {:ok, path} <- base_path(owner, repository),
         true <- is_integer(page) and page in 1..@max_page and valid_options?(opts) do
      with {:ok, %{json: json, next_url: next_url}} <-
             Client.label_metadata_page(token, "#{path}?page=#{page}&per_page=100", opts),
           {:ok, labels} <- decode_page(json, token),
           {:ok, next_cursor} <- next_cursor(next_url, path, page) do
        {:ok, %{labels: labels, next_cursor: next_cursor}}
      end
    else
      _invalid -> error(:invalid_request)
    end
  end

  defp decode_page(labels, token) when is_list(labels) and length(labels) <= 100 do
    if Enum.all?(labels, &match?({:ok, _}, decode_label({:ok, &1}))) and
         Enum.all?(labels, &safe_page_label?(&1, token)) and
         length(Enum.uniq_by(labels, & &1["id"])) == length(labels) and
         length(Enum.uniq_by(labels, & &1["node_id"])) == length(labels),
       do: {:ok, Enum.map(labels, &Map.take(&1, ~w(id node_id name color description)))},
       else: error(:invalid_response)
  end

  defp decode_page(_json, _token), do: error(:invalid_response)

  defp safe_page_label?(label, token) do
    node = label["node_id"]

    byte_size(node) <= 512 and node == String.trim(node) and
      Enum.all?(~w(node_id name color description), fn field ->
        # Metadata bounds above are in codepoints; the description safety slot
        # preserves those limits while checking every retained string for credentials.
        ForgeAccounts.GitHubProfileSafety.validate(%{description: label[field]}, token) == :ok
      end)
  end

  defp next_cursor(nil, _path, _page), do: {:ok, nil}
  defp next_cursor(_url, _path, @max_page), do: error(:pagination_limit)

  defp next_cursor(url, path, page) do
    with {:ok, %URI{path: ^path, query: query}} <- URI.new(url),
         true <- is_binary(query),
         pairs <- Enum.to_list(URI.query_decoder(query)),
         true <- length(pairs) == 2,
         true <- Map.new(pairs) == %{"page" => Integer.to_string(page + 1), "per_page" => "100"} do
      {:ok, page + 1}
    else
      _invalid -> error(:invalid_pagination)
    end
  rescue
    _exception -> error(:invalid_pagination)
  end

  def create_label(token, owner, repository, attrs, opts) do
    with {:ok, path} <- base_path(owner, repository),
         true <- valid_options?(opts),
         {:ok, attrs} <- normalize_attrs(attrs),
         true <- valid_metadata?(attrs) do
      Client.request(token, :post, path, Keyword.put(opts, :json, attrs))
      |> decode_label()
    else
      _invalid -> error(:invalid_request)
    end
  end

  def get_label(token, owner, repository, name, opts) do
    with {:ok, path} <- base_path(owner, repository),
         true <- valid_options?(opts),
         true <- text?(name, 255) and name != "" do
      # Encode reserved characters and dot-only segments, never allowing the
      # label name to alter the repository endpoint or query string.
      segment = URI.encode(name, &URI.char_unreserved?/1)
      segment = if segment in [".", ".."], do: String.replace(segment, ".", "%2E"), else: segment
      Client.request(token, :get, path <> "/" <> segment, opts) |> decode_label()
    else
      _invalid -> error(:invalid_request)
    end
  end

  defp base_path(owner, repository) do
    if RepositoryReference.valid_owner?(owner) and
         RepositoryReference.valid_repository?(repository),
       do: {:ok, "/repos/#{owner}/#{repository}/labels"},
       else: :error
  end

  defp valid_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and not Keyword.has_key?(opts, :json) and
      case Keyword.get(opts, :gate_key) do
        {:github_installation, id} when is_integer(id) and id > 0 -> true
        _invalid -> false
      end
  end

  defp valid_options?(_opts), do: false

  defp normalize_attrs(attrs) when is_map(attrs) and map_size(attrs) in 2..3 do
    normalized =
      Map.new(attrs, fn {key, value} ->
        {if(is_atom(key), do: Atom.to_string(key), else: key), value}
      end)

    if map_size(normalized) == map_size(attrs) and
         Enum.all?(Map.keys(normalized), &(&1 in ~w(name color description))),
       do: {:ok, normalized},
       else: :error
  end

  defp normalize_attrs(_attrs), do: :error

  defp valid_metadata?(%{"name" => name, "color" => color} = attrs) do
    text?(name, 255) and name != "" and is_binary(color) and
      Regex.match?(~r/\A[0-9a-fA-F]{6}\z/, color) and
      (is_nil(attrs["description"]) or text?(attrs["description"], 100))
  end

  defp valid_metadata?(_attrs), do: false

  defp decode_label({:ok, %{"id" => id, "node_id" => node_id} = label}) do
    if is_integer(id) and id in 1..9_223_372_036_854_775_807 and
         text?(node_id, 512) and node_id != "" and valid_metadata?(label),
       do: {:ok, label},
       else: error(:invalid_response)
  end

  defp decode_label({:error, %Error{}} = error), do: error
  defp decode_label(_response), do: error(:invalid_response)

  defp text?(value, maximum) when is_binary(value) and byte_size(value) <= maximum * 4 do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      length(String.codepoints(value)) <= maximum
  end

  defp text?(_value, _maximum), do: false
  defp error(kind), do: {:error, Error.new(kind)}
end
