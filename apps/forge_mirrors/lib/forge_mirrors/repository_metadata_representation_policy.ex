defmodule ForgeMirrors.RepositoryMetadataRepresentationPolicy do
  @moduledoc false

  @fields ~w(name description visibility default_branch archived)

  @spec valid_snapshot?(term()) :: boolean()
  def valid_snapshot?(snapshot) when is_map(snapshot) do
    Enum.sort(Map.keys(snapshot)) == Enum.sort(@fields) and valid_string?(snapshot["name"]) and
      valid_optional_description?(snapshot["description"]) and
      snapshot["visibility"] in ["public", "private", "internal"] and
      valid_string?(snapshot["default_branch"]) and is_boolean(snapshot["archived"])
  end

  def valid_snapshot?(_snapshot), do: false

  @spec classify(map()) :: :representable | {:unrepresentable, String.t()}
  def classify(%{"archived" => true, "visibility" => "internal"}),
    do: {:unrepresentable, "repository_archived_internal_unrepresentable"}

  def classify(%{"archived" => true}),
    do: {:unrepresentable, "repository_archived_unrepresentable"}

  def classify(%{"visibility" => "internal"}),
    do: {:unrepresentable, "repository_internal_visibility_unrepresentable"}

  def classify(%{"archived" => false, "visibility" => visibility})
      when visibility in ["public", "private"],
      do: :representable

  def classify(_snapshot), do: {:unrepresentable, "repository_metadata_unrepresentable"}

  defp valid_optional_description?(nil), do: true

  defp valid_optional_description?(description) when is_binary(description) do
    byte_size(description) <= 1_000 and String.valid?(description) and
      not String.contains?(description, <<0>>)
  end

  defp valid_optional_description?(_description), do: false

  defp valid_string?(value) do
    is_binary(value) and byte_size(value) in 1..255 and String.valid?(value) and
      value == String.trim(value)
  end
end
