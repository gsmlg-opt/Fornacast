defmodule ForgeGitHub.RepositoryMetadataProjection do
  @moduledoc false

  @fields [
    :id,
    :node_id,
    :name,
    :description,
    :visibility,
    :default_branch,
    :archived,
    :updated_at
  ]

  @allowed_visibilities [:public, :private, :internal]

  def from_remote(remote) when is_map(remote) do
    projection = Map.take(remote, @fields)

    if valid_projection?(projection),
      do: {:ok, projection},
      else: {:error, :invalid_remote_repository}
  end

  def from_remote(_), do: {:error, :invalid_remote_repository}

  defp valid_projection?(projection) do
    Map.keys(projection) |> Enum.sort() == Enum.sort(@fields) and
      is_integer(projection.id) and projection.id > 0 and
      valid_string?(projection.node_id, 255) and
      valid_string?(projection.name, 100) and
      valid_optional_string?(projection.description, 1_000) and
      projection.visibility in @allowed_visibilities and
      valid_string?(projection.default_branch, 255) and
      is_boolean(projection.archived) and
      valid_utc_datetime?(projection.updated_at)
  end

  defp valid_optional_string?(nil, _maximum), do: true
  defp valid_optional_string?(value, maximum), do: valid_string?(value, maximum)

  defp valid_string?(value, maximum) when is_binary(value) do
    String.valid?(value) and value == String.trim(value) and value != "" and
      byte_size(value) <= maximum and not String.contains?(value, <<0>>)
  end

  defp valid_string?(_, _maximum), do: false

  defp valid_utc_datetime?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}),
    do: true

  defp valid_utc_datetime?(_), do: false
end
