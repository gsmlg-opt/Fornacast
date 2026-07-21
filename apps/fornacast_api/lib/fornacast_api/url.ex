defmodule FornacastAPI.URL do
  @invalid_base_url_message "configured base URL must be an absolute HTTP or HTTPS URL with a nonempty host and no ASCII control characters"

  def api(path), do: join("/api/v3", path)
  def upload(path), do: join("/api/uploads", path)
  def web(path), do: join("", path)

  def user(login), do: api("/users/#{segment(login)}")
  def organization(login), do: api("/orgs/#{segment(login)}")
  def repository(owner, repo), do: api("/repos/#{segment(owner)}/#{segment(repo)}")

  defp join(prefix, path) when is_binary(path) and is_binary(prefix) do
    if String.starts_with?(path, "/") do
      base = validated_base_uri!()

      %{base | path: prefix <> path, query: nil, fragment: nil, userinfo: nil}
      |> URI.to_string()
    else
      raise ArgumentError, "path must be a string beginning with /, got: #{inspect(path)}"
    end
  end

  defp join(_prefix, path) do
    raise ArgumentError, "path must be a string beginning with /, got: #{inspect(path)}"
  end

  defp segment(value) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp segment(value) do
    raise ArgumentError, "path segment must be a string, got: #{inspect(value)}"
  end

  defp validated_base_uri! do
    base_url = Fornacast.Config.base_url()

    with true <- is_binary(base_url),
         false <- ascii_control?(base_url),
         {:ok, %URI{} = uri} <- URI.new(base_url),
         scheme when scheme in ["http", "https"] <- normalized_scheme(uri.scheme),
         host when is_binary(host) and byte_size(host) > 0 <- uri.host do
      %{uri | scheme: scheme}
    else
      _invalid -> raise ArgumentError, @invalid_base_url_message
    end
  end

  defp normalized_scheme(scheme) when is_binary(scheme), do: String.downcase(scheme)
  defp normalized_scheme(_scheme), do: nil

  defp ascii_control?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(fn byte -> byte < 32 or byte == 127 end)
  end
end
