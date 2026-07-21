defmodule ForgeRepos.RepositoryView do
  alias ForgeAccounts.{Organization, User}
  alias ForgeRepos.Repository

  @enforce_keys [:repository, :owner, :permissions, :size_kib]
  defstruct [:repository, :owner, :permissions, :size_kib]

  @type t :: %__MODULE__{
          repository: Repository.t(),
          owner: User.t() | Organization.t(),
          permissions: %{admin: boolean(), push: boolean(), pull: boolean()},
          size_kib: non_neg_integer()
        }
end
