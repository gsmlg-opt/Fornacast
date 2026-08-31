defmodule ForgeRepos.RepositoryReadHandle do
  @moduledoc """
  Opaque ownership token for a repository read lease.

  Consumers use the accessors on `ForgeRepos`; the lease itself is deliberately
  not part of the public repository-read interface.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:repository, :path, :lease]
  defstruct [:repository, :path, :lease]

  @opaque t :: %__MODULE__{
            repository: ForgeRepos.Repository.t(),
            path: Path.t(),
            lease: GitCore.RepositoryReadLimiter.lease()
          }
end
