defmodule GitCore.Signature do
  @moduledoc """
  An explicitly supplied identity and timestamp for a Git object.
  """

  @enforce_keys [:name, :email, :seconds, :offset_minutes]
  defstruct [:name, :email, :seconds, :offset_minutes]

  @type t :: %__MODULE__{
          name: String.t(),
          email: String.t(),
          seconds: integer(),
          offset_minutes: integer()
        }
end

defmodule GitCore.MergeAnalysis do
  @moduledoc """
  Bounded analysis of an immutable base/head commit pair.

  `ahead_by` and `commit_count` are both the number of commits reachable from the head but
  not the base. `behind_by` is the inverse count. `changed_paths` is the number of leaf paths
  whose state differs between the merge-base tree and the head tree, so base-only work is not
  attributed to the pull request.
  """

  @enforce_keys [
    :base_oid,
    :head_oid,
    :mergeable,
    :ahead_by,
    :behind_by,
    :commit_count,
    :changed_paths
  ]
  defstruct [
    :base_oid,
    :head_oid,
    :mergeable,
    :ahead_by,
    :behind_by,
    :commit_count,
    :changed_paths
  ]

  @type t :: %__MODULE__{
          base_oid: String.t(),
          head_oid: String.t(),
          mergeable: boolean(),
          ahead_by: non_neg_integer(),
          behind_by: non_neg_integer(),
          commit_count: non_neg_integer(),
          changed_paths: non_neg_integer()
        }
end
