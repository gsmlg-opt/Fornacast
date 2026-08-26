defmodule ForgeAccounts.GitHubProfileSafety do
  @moduledoc false

  @profile_fields [
    {:login, 255, :text},
    {"login", 255, :text},
    {:owner_login, 255, :text},
    {"owner_login", 255, :text},
    {:name, 255, :text},
    {"name", 255, :text},
    {:full_name, 512, :text},
    {"full_name", 512, :text},
    {:description, 2_048, :text},
    {"description", 2_048, :text},
    {:default_branch, 255, :text},
    {"default_branch", 255, :text},
    {:avatar_url, 2_048, :url},
    {"avatar_url", 2_048, :url},
    {:profile_url, 2_048, :url},
    {"profile_url", 2_048, :url},
    {:html_url, 2_048, :url},
    {"html_url", 2_048, :url}
  ]
  @credential_markers ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "bearer "]

  @spec validate(term(), binary() | nil) :: :ok | {:error, :invalid_response}
  def validate(profile, credential \\ nil)

  def validate(nil, credential) when is_nil(credential) or is_binary(credential), do: :ok

  def validate(profile, credential)
      when is_map(profile) and (is_nil(credential) or is_binary(credential)) do
    Enum.reduce_while(@profile_fields, :ok, fn {key, max_bytes, kind}, :ok ->
      case Map.fetch(profile, key) do
        :error ->
          {:cont, :ok}

        {:ok, nil} ->
          {:cont, :ok}

        {:ok, value} when is_binary(value) ->
          if safe_string?(value, max_bytes, kind, credential),
            do: {:cont, :ok},
            else: {:halt, {:error, :invalid_response}}

        {:ok, _invalid} ->
          {:halt, {:error, :invalid_response}}
      end
    end)
  end

  def validate(_profile, _credential), do: {:error, :invalid_response}

  defp safe_string?(value, max_bytes, kind, credential) do
    byte_size(value) <= max_bytes and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch and not credential_marker?(value) and
      Enum.all?(credential_values(value, kind), &(not credential_overlap?(&1, credential)))
  end

  defp credential_values(value, :text), do: [value]

  defp credential_values(value, :url) do
    case URI.new(value) do
      {:ok, uri} -> [value | url_parts(uri)]
      {:error, _reason} -> [value]
    end
  end

  defp url_parts(uri) do
    [uri.path, uri.query, uri.fragment]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&String.split(&1, ~r/[^[:alnum:]_-]+/u, trim: true))
  end

  defp credential_marker?(value) do
    normalized = String.downcase(value)
    Enum.any?(@credential_markers, &String.contains?(normalized, &1))
  end

  defp credential_overlap?(_value, nil), do: false
  defp credential_overlap?(_value, ""), do: true

  defp credential_overlap?(value, credential) do
    value == credential or String.contains?(value, credential) or
      (byte_size(value) >= 8 and String.contains?(credential, value))
  end
end
