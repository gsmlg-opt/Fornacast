defmodule ForgeGitHub do
  @moduledoc """
  GitHub provider boundary for authentication, bounded API transport, resource
  decoding, and webhook primitives.
  """

  @type provider :: :github
  @type external_id :: pos_integer()
  @type installation_id :: pos_integer()

  defdelegate merge_pull(repository, pull, actor, attrs, request_metadata),
    to: ForgeGitHub.PullMergeAdmission,
    as: :merge

  defdelegate merge(repository, pull, actor, attrs, request_metadata),
    to: ForgeGitHub.PullMergeAdmission
end
