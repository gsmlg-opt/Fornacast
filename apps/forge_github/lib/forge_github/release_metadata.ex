defmodule ForgeGitHub.ReleaseMetadata do
  @moduledoc false

  @keys ~w(body_html body_text mentions_count reactions discussion_url)
  @reaction_keys ~w(url total_count +1 -1 laugh hooray confused heart rocket eyes)

  def from_remote(release, token) when is_map(release) do
    immutable = Map.get(release, "immutable", false)
    metadata = Map.take(release, @keys)

    metadata =
      if is_map(metadata["reactions"]),
        do: Map.update!(metadata, "reactions", &Map.take(&1, @reaction_keys)),
        else: metadata

    with true <- is_boolean(immutable),
         :ok <- validate(metadata),
         :ok <-
           ForgeAccounts.GitHubProfileSafety.validate(
             %{description: JSON.encode!(metadata)},
             token
           ) do
      {:ok, immutable, metadata}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate(metadata) when is_map(metadata) do
    if Map.keys(metadata) -- @keys == [] and Enum.all?(metadata, &valid_field?/1),
      do: :ok,
      else: {:error, :invalid_release_metadata}
  end

  def validate(_), do: {:error, :invalid_release_metadata}

  defp valid_field?({key, value}) when key in ["body_html", "body_text"] do
    is_nil(value) or
      (is_binary(value) and String.valid?(value) and byte_size(value) <= 262_144 and
         :binary.match(value, <<0>>) == :nomatch)
  end

  defp valid_field?({"mentions_count", value}), do: count?(value)

  defp valid_field?({"reactions", value}) when is_map(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(@reaction_keys) and
      valid_reaction_url?(value["url"]) and
      Enum.all?(Map.delete(value, "url"), fn {_, count} -> count?(count) end)
  end

  defp valid_field?({"discussion_url", nil}), do: true

  defp valid_field?({"discussion_url", url}) when is_binary(url) and byte_size(url) <= 2_048 do
    case URI.new(url) do
      {:ok,
       %URI{
         scheme: "https",
         host: "github.com",
         port: 443,
         userinfo: nil,
         query: nil,
         fragment: nil,
         path: path
       }} ->
        is_binary(path) and Regex.match?(~r{\A/[^/]+/[^/]+/discussions/[1-9][0-9]*\z}, path)

      _ ->
        false
    end
  end

  defp valid_field?(_), do: false

  defp valid_reaction_url?(url) when is_binary(url) and byte_size(url) <= 2_048 do
    case URI.new(url) do
      {:ok,
       %URI{
         scheme: "https",
         host: "api.github.com",
         port: 443,
         userinfo: nil,
         query: nil,
         fragment: nil,
         path: path
       }} ->
        is_binary(path) and
          Regex.match?(
            ~r{\A/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/[1-9][0-9]*/reactions\z},
            path
          )

      _ ->
        false
    end
  end

  defp valid_reaction_url?(_), do: false
  defp count?(count), do: is_integer(count) and count in 0..9_223_372_036_854_775_807
end
