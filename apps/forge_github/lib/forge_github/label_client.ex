defmodule ForgeGitHub.LabelClient do
  @moduledoc "Installation-gated label creation and lookup for permanent issue label mappings."

  alias ForgeGitHub.{Client, Error, RepositoryReference}

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
