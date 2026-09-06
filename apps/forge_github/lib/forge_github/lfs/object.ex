defmodule ForgeGitHub.LFS.Object do
  @moduledoc "A validated object result from a Git LFS Batch response."

  alias ForgeGitHub.{Error, LFS.Action}

  @enforce_keys [:oid, :size, :authenticated, :actions]
  defstruct [:oid, :size, :authenticated, :actions, :error]

  @type t :: %__MODULE__{
          oid: String.t(),
          size: non_neg_integer(),
          authenticated: boolean(),
          actions: %{optional(Action.operation()) => Action.t()},
          error: Error.t() | nil
        }
end
