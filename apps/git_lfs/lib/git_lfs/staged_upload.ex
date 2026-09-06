defmodule GitLFS.StagedUpload do
  @moduledoc """
  Opaque handle for fully received and integrity-checked LFS bytes.
  """

  @enforce_keys [:reservation, :staged_ref]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            reservation: GitLFS.UploadReservation.t(),
            staged_ref: ForgeBlobs.StagedRef.t()
          }
end

defimpl Inspect, for: GitLFS.StagedUpload do
  def inspect(_staged, _options), do: "#GitLFS.StagedUpload<redacted>"
end
