defmodule ForgeImports.GitHub.RepositoryReference do
  @moduledoc "Strict parser for GitHub.com repository references."

  @owner ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/
  @repository ~r/^[A-Za-z0-9._-]{1,100}$/

  @spec parse(term()) ::
          {:ok, %{owner: String.t(), repository: String.t()}} | {:error, :invalid_source}
  def parse(source) when is_binary(source) do
    source = String.trim(source)

    with true <- source != "" and String.valid?(source),
         :nomatch <- :binary.match(source, <<0>>),
         {:ok, owner, repository} <- parse_form(source),
         true <- valid_owner?(owner),
         true <- valid_repository?(repository) do
      {:ok, %{owner: owner, repository: repository}}
    else
      _ -> {:error, :invalid_source}
    end
  end

  def parse(_source), do: {:error, :invalid_source}

  @doc false
  def valid_owner?(owner) when is_binary(owner),
    do: String.valid?(owner) and Regex.match?(@owner, owner)

  def valid_owner?(_owner), do: false

  @doc false
  def valid_repository?(repository) when is_binary(repository) do
    String.valid?(repository) and repository not in [".", ".."] and
      Regex.match?(@repository, repository)
  end

  def valid_repository?(_repository), do: false

  defp parse_form(source) do
    if String.contains?(source, "://") do
      parse_url(source)
    else
      source =
        if String.ends_with?(source, "/"),
          do: String.replace_suffix(source, "/", ""),
          else: source

      case String.split(source, "/", parts: 3) do
        [owner, repository] -> {:ok, owner, String.replace_suffix(repository, ".git", "")}
        _other -> :error
      end
    end
  end

  defp parse_url(source) do
    with {:ok, uri} <- URI.new(source),
         "https" <- String.downcase(uri.scheme || ""),
         "github.com" <- String.downcase(uri.host || ""),
         true <- no_explicit_port?(source),
         {:ok, owner, repository} <- url_components(uri.path) do
      {:ok, owner, repository}
    else
      _ -> :error
    end
  end

  defp no_explicit_port?(source) do
    source
    |> String.split("://", parts: 2)
    |> List.last()
    |> String.split("/", parts: 2)
    |> List.first()
    |> String.split("@", parts: 2)
    |> List.last()
    |> then(&(not String.contains?(&1, ":")))
  end

  defp url_components(path) when is_binary(path) do
    path = if String.ends_with?(path, "/"), do: String.replace_suffix(path, "/", ""), else: path

    case String.split(path, "/", trim: false) do
      ["", owner, repository] when owner != "" and repository != "" ->
        {:ok, owner, String.replace_suffix(repository, ".git", "")}

      _other ->
        :error
    end
  end

  defp url_components(_path), do: :error
end
