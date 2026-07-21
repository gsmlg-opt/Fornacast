defmodule FornacastAPI.URL do
  def api(path), do: join("/api/v3", path)
  def upload(path), do: join("/api/uploads", path)
  def web(path), do: join("", path)

  def user(login), do: api("/users/#{segment(login)}")
  def organization(login), do: api("/orgs/#{segment(login)}")
  def repository(owner, repo), do: api("/repos/#{segment(owner)}/#{segment(repo)}")

  defp join(prefix, path) when is_binary(path) and is_binary(prefix) do
    if String.starts_with?(path, "/") do
      base = URI.parse(Fornacast.Config.base_url())

      if is_binary(base.scheme) and is_binary(base.host) do
        %{base | path: prefix <> path, query: nil, fragment: nil, userinfo: nil}
        |> URI.to_string()
      else
        raise ArgumentError, "configured base URL must include a scheme and host"
      end
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
end
