defmodule ForgeAccounts.ExternalAttribution do
  @moduledoc "Safe presentation value for an unlinked GitHub identity."

  @enforce_keys [:github_identity_id, :username]
  defstruct [:github_identity_id, :username, :avatar_url, :profile_url]

  @type t :: %__MODULE__{
          github_identity_id: pos_integer(),
          username: String.t(),
          avatar_url: String.t() | nil,
          profile_url: String.t() | nil
        }

  @ghost_username "Github:ghost"

  @spec username_prefix() :: String.t()
  def username_prefix, do: "Github:"

  @spec ghost_username() :: String.t()
  def ghost_username, do: @ghost_username

  @spec from_identity(ForgeAccounts.GitHubIdentity.t()) :: t()
  def from_identity(%ForgeAccounts.GitHubIdentity{id: id, kind: :deleted}) do
    %__MODULE__{github_identity_id: id, username: @ghost_username}
  end

  def from_identity(%ForgeAccounts.GitHubIdentity{id: id, login: login} = identity) do
    %__MODULE__{
      github_identity_id: id,
      username: username_prefix() <> login,
      avatar_url: identity.avatar_url,
      profile_url: identity.profile_url
    }
  end
end
