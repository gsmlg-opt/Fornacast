defmodule FornacastWeb.RequestParsers do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(options), do: Plug.Parsers.init(options)

  @impl Plug
  def call(%Plug.Conn{path_info: path_info} = conn, options) do
    if lfs_path?(path_info) do
      conn
    else
      Plug.Parsers.call(conn, options)
    end
  end

  defp lfs_path?([_owner, repo_dot_git, "info", "lfs" | _rest]) do
    repo_dot_git
    |> URI.decode()
    |> String.ends_with?(".git")
  rescue
    ArgumentError -> false
  end

  defp lfs_path?(_path_info), do: false
end
