defmodule ForgePulls.Comparison do
  @enforce_keys [:head_ref, :base_ref, :head_oid, :base_oid, :analysis]
  defstruct [:head_ref, :base_ref, :head_oid, :base_oid, :analysis]

  @type t :: %__MODULE__{
          head_ref: String.t(),
          base_ref: String.t(),
          head_oid: String.t(),
          base_oid: String.t(),
          analysis: GitCore.MergeAnalysis.t()
        }
end
