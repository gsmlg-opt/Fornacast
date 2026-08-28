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

  @doc false
  @spec new(ForgeRepos.Repository.t(), Path.t(), GitCore.RepositoryReadLimiter.lease()) :: t()
  def new(repository, path, lease),
    do: %__MODULE__{repository: repository, path: path, lease: lease}

  @doc false
  @spec repository(t()) :: ForgeRepos.Repository.t()
  def repository(%__MODULE__{repository: repository}), do: repository

  @doc false
  @spec path(t()) :: Path.t()
  def path(%__MODULE__{path: path}), do: path

  @doc false
  @spec close(t()) :: :ok
  def close(%__MODULE__{lease: lease}), do: GitCore.RepositoryReadLimiter.release(lease)
end
