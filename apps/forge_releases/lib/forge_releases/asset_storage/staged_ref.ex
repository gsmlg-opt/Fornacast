defmodule ForgeReleases.AssetStorage.StagedRef do
  @moduledoc """
  Opaque caller handle for staged bytes.

  Opacity and redacted inspection establish a caller convention; Elixir structs
  remain introspectable at runtime. Code outside the adapter must not retain or
  pattern-match the fields.
  """

  @enforce_keys [:inner, :options, :storage_key, :size]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            inner: ExStorageService.BlobStore.StagedBlob.t(),
            options: keyword(),
            storage_key: String.t(),
            size: non_neg_integer()
          }
end

defimpl Inspect, for: ForgeReleases.AssetStorage.StagedRef do
  def inspect(_staged, _options), do: "#ForgeReleases.AssetStorage.StagedRef<redacted>"
end
