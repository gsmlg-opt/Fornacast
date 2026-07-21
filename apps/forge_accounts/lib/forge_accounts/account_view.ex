defmodule ForgeAccounts.AccountView do
  alias ForgeAccounts.{Organization, User}

  @enforce_keys [:account, :public_repos, :private_repos]
  defstruct [:account, :public_repos, :private_repos, two_factor_authentication: false]

  @type account :: %User{} | %Organization{}
  @type t :: %__MODULE__{
          account: account(),
          public_repos: non_neg_integer(),
          private_repos: non_neg_integer(),
          two_factor_authentication: false
        }

  @spec new(account(), non_neg_integer(), non_neg_integer()) :: t()
  def new(%User{} = account, public_repos, private_repos)
      when is_integer(public_repos) and public_repos >= 0 and is_integer(private_repos) and
             private_repos >= 0 do
    %__MODULE__{account: account, public_repos: public_repos, private_repos: private_repos}
  end

  def new(%Organization{} = account, public_repos, private_repos)
      when is_integer(public_repos) and public_repos >= 0 and is_integer(private_repos) and
             private_repos >= 0 do
    %__MODULE__{account: account, public_repos: public_repos, private_repos: private_repos}
  end

  def new(account, _public_repos, _private_repos)
      when is_struct(account, User) or is_struct(account, Organization) do
    raise ArgumentError, "account view requires non-negative integer repository counts"
  end

  def new(_account, _public_repos, _private_repos) do
    raise ArgumentError, "account view requires a User or Organization account"
  end

  @spec validate!(term()) :: t()
  def validate!(
        %__MODULE__{
          account: account,
          public_repos: public_repos,
          private_repos: private_repos,
          two_factor_authentication: false
        } = view
      )
      when (is_struct(account, User) or is_struct(account, Organization)) and
             is_integer(public_repos) and public_repos >= 0 and is_integer(private_repos) and
             private_repos >= 0 do
    view
  end

  def validate!(_value) do
    raise ArgumentError, "expected a valid ForgeAccounts.AccountView"
  end
end
