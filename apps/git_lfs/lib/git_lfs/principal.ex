defmodule GitLFS.Principal do
  @moduledoc """
  Authentication provenance retained while issuing short-lived transfer tokens.
  """

  alias ForgeAccounts.{APIKey, User}

  @enforce_keys [:credential_kind]
  defstruct [:actor, :credential_kind, :credential_id]

  @type credential_kind :: :anonymous | :password | :ssh | :api_key
  @type t :: %__MODULE__{
          actor: User.t() | nil,
          credential_kind: credential_kind(),
          credential_id: pos_integer() | nil
        }

  @spec anonymous() :: t()
  def anonymous, do: %__MODULE__{actor: nil, credential_kind: :anonymous, credential_id: nil}

  @spec password(User.t()) :: t()
  def password(%User{} = actor),
    do: %__MODULE__{actor: actor, credential_kind: :password, credential_id: nil}

  @spec ssh(User.t()) :: t()
  def ssh(%User{} = actor),
    do: %__MODULE__{actor: actor, credential_kind: :ssh, credential_id: nil}

  @spec api_key(User.t(), APIKey.t()) :: t()
  def api_key(%User{} = actor, %APIKey{id: id}),
    do: %__MODULE__{actor: actor, credential_kind: :api_key, credential_id: id}
end
