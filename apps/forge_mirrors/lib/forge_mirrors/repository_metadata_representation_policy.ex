defmodule ForgeMirrors.RepositoryMetadataRepresentationPolicy do
  @moduledoc false

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
end
