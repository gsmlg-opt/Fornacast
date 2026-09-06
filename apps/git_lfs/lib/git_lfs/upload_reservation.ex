defmodule GitLFS.UploadReservation do
  @moduledoc """
  Opaque, retryable reservation for one repository, generation, OID, and size.
  """

  @enforce_keys [:repository_id, :repository_generation, :oid, :size, :staging_key]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            repository_id: pos_integer(),
            repository_generation: pos_integer(),
            oid: String.t(),
            size: non_neg_integer(),
            staging_key: String.t()
          }
end

defimpl Inspect, for: GitLFS.UploadReservation do
  def inspect(_reservation, _options), do: "#GitLFS.UploadReservation<redacted>"
end
