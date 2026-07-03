defmodule Fornacast.Storage do
  @moduledoc """
  Safe repository storage path resolution.

  Database records store repository paths relative to the configured storage
  root. User-facing owner/repository slugs never become filesystem paths.
  """

  alias Fornacast.Config

  def ensure_root! do
    root = Config.repo_storage_root()
    File.mkdir_p!(root)
    root
  end

  def repository_path!(storage_path) when is_binary(storage_path) do
    root = ensure_root!()

    with :ok <- validate_relative_storage_path(storage_path),
         path <- Path.expand(Path.join(root, storage_path)),
         true <- inside_root?(root, path) do
      path
    else
      false -> raise ArgumentError, "repository storage path escapes storage root"
      {:error, reason} -> raise ArgumentError, "invalid repository storage path: #{reason}"
    end
  end

  defp validate_relative_storage_path(storage_path) do
    cond do
      Path.type(storage_path) != :relative ->
        {:error, "must be relative"}

      storage_path == "" ->
        {:error, "must not be empty"}

      String.split(storage_path, "/") |> Enum.any?(&(&1 in ["", ".", ".."])) ->
        {:error, "contains unsafe path segment"}

      not String.ends_with?(storage_path, ".git") ->
        {:error, "must end in .git"}

      true ->
        :ok
    end
  end

  defp inside_root?(root, path) do
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end
end
