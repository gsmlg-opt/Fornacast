defmodule ForgeBlobs.Source do
  @moduledoc """
  Opaque, single-owner cursor for an opened blob.

  Opacity and redacted inspection establish a caller convention; Elixir structs
  remain introspectable at runtime. One controlling process must thread every
  returned cursor sequentially through `read/2` and finally `close/1`. A source
  must not be shared between tasks.
  """

  @enforce_keys [:io, :offset, :position, :remaining]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            io: :file.io_device(),
            offset: non_neg_integer(),
            position: non_neg_integer(),
            remaining: non_neg_integer()
          }
end

defimpl Inspect, for: ForgeBlobs.Source do
  def inspect(_source, _options), do: "#ForgeBlobs.Source<redacted>"
end
