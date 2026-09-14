defmodule ForgeGitHub.ReleaseSyncProjection do
  @moduledoc "Canonical release projections shared by bootstrap and live synchronization."

  @max_id 9_223_372_036_854_775_807
  @max_assets 512
  @max_body_bytes 262_144
  @max_body_codepoints 65_536
  @max_name_bytes 1_020
  @max_name_codepoints 255
  @field_keys ~w(body draft name prerelease published_at tag_name target_commitish)
  @login ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?(?:\[bot\])?$/

  @spec from_local(map()) :: {:ok, map()} | {:error, :invalid_projection}
  def from_local(%{
        resource_kind: :release,
        local_resource_id: local_id,
        local_resource_type: "ForgeReleases.Release",
        local_version: local_version,
        deleted: false,
        fields: fields
      }) do
    with true <- valid_id?(local_id) and valid_id?(local_version),
         {:ok, snapshot} <- canonical_fields(fields) do
      {:ok,
       %{
         presence: :present,
         resource_kind: :release,
         local_resource_id: local_id,
         local_resource_type: "ForgeReleases.Release",
         local_version: local_version,
         snapshot: snapshot
       }}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  def from_local(_projection), do: {:error, :invalid_projection}

  @spec from_remote(map()) :: {:ok, map()} | {:error, :invalid_projection}
  def from_remote(%{
        "id" => id,
        "node_id" => node_id,
        "tag_name" => tag_name,
        "name" => name,
        "body" => body,
        "draft" => draft,
        "prerelease" => prerelease,
        "target_commitish" => target_commitish,
        "published_at" => published_at,
        "created_at" => created_at,
        "updated_at" => updated_at,
        "author" => author,
        "asset_count" => asset_count
      }) do
    with true <- valid_id?(id) and valid_node_id?(node_id),
         true <- is_integer(asset_count) and asset_count in 0..@max_assets,
         {:ok, author} <- canonical_author(author),
         {:ok, published_at} <- optional_datetime(published_at),
         {:ok, created_at} <- datetime(created_at),
         {:ok, updated_at} <- datetime(updated_at),
         {:ok, snapshot} <-
           canonical_fields(%{
             "tag_name" => tag_name,
             "name" => name,
             "body" => body,
             "draft" => draft,
             "prerelease" => prerelease,
             "target_commitish" => target_commitish,
             "published_at" => published_at
           }) do
      {:ok,
       %{
         presence: :present,
         resource_kind: :release,
         github_object_id: id,
         github_node_id: node_id,
         remote_created_at: created_at,
         remote_updated_at: updated_at,
         snapshot: snapshot,
         raw_author: author,
         asset_count: asset_count
       }}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  def from_remote(_release), do: {:error, :invalid_projection}

  @spec remote_attrs(map()) :: {:ok, map()} | {:error, :invalid_projection}
  def remote_attrs(fields) do
    with {:ok, canonical} <- canonical_fields(fields) do
      {:ok, Map.drop(canonical, ["published_at"])}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp canonical_fields(
         %{
           "tag_name" => tag_name,
           "name" => name,
           "body" => body,
           "draft" => draft,
           "prerelease" => prerelease,
           "target_commitish" => target_commitish,
           "published_at" => published_at
         } = fields
       )
       when map_size(fields) == 7 and is_boolean(draft) and is_boolean(prerelease) do
    valid_publication =
      (draft and is_nil(published_at)) or (not draft and match?(%DateTime{}, published_at))

    if Enum.sort(Map.keys(fields)) == @field_keys and valid_tag?(tag_name) and
         valid_text?(target_commitish, @max_name_bytes, false) and
         codepoints_at_most?(target_commitish, @max_name_codepoints) and
         valid_text?(name, @max_name_bytes, true) and
         optional_codepoints_at_most?(name, @max_name_codepoints) and
         valid_text?(body, @max_body_bytes, true) and
         optional_codepoints_at_most?(body, @max_body_codepoints) and valid_publication do
      {:ok, fields}
    else
      {:error, :invalid_projection}
    end
  end

  defp canonical_fields(_fields), do: {:error, :invalid_projection}

  defp valid_tag?(tag_name) do
    valid_text?(tag_name, @max_name_bytes, false) and not String.starts_with?(tag_name, "refs/") and
      codepoints_at_most?(tag_name, @max_name_codepoints) and
      match?(
        {:ok, _},
        GitCore.tracking_ref_name("release-projection", "refs/tags/#{tag_name}")
      )
  end

  defp canonical_author(%{"id" => id, "node_id" => node_id, "login" => login}) do
    if valid_id?(id) and valid_node_id?(node_id) and valid_text?(login, 420, false) and
         codepoints_at_most?(login, 105) and Regex.match?(@login, login),
       do: {:ok, %{"id" => id, "node_id" => node_id, "login" => login}},
       else: {:error, :invalid_projection}
  end

  defp canonical_author(_author), do: {:error, :invalid_projection}

  defp valid_id?(id), do: is_integer(id) and id in 1..@max_id

  defp valid_node_id?(value),
    do: valid_text?(value, 512, false) and value == String.trim(value)

  defp valid_text?(nil, _limit, true), do: true

  defp valid_text?(value, limit, allow_empty?) when is_binary(value) do
    byte_size(value) <= limit and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch and (allow_empty? or value != "")
  end

  defp valid_text?(_value, _limit, _nullable), do: false

  defp optional_codepoints_at_most?(nil, _limit), do: true
  defp optional_codepoints_at_most?(value, limit), do: codepoints_at_most?(value, limit)

  defp codepoints_at_most?(value, limit), do: codepoints_at_most?(value, limit, 0)
  defp codepoints_at_most?("", _limit, _count), do: true
  defp codepoints_at_most?(_value, limit, count) when count >= limit, do: false

  defp codepoints_at_most?(value, limit, count) do
    case String.next_codepoint(value) do
      {_codepoint, rest} -> codepoints_at_most?(rest, limit, count + 1)
      nil -> true
    end
  end

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(value), do: datetime(value)

  defp datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp datetime(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.truncate(datetime, :second)}
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp datetime(_value), do: {:error, :invalid_projection}
end
