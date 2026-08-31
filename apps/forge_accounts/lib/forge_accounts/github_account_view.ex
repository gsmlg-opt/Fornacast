defmodule ForgeAccounts.GitHubAccountView do
  @moduledoc """
  Safe presentation data for a linked GitHub account.

  Credential envelope fields and plaintext credentials are deliberately absent.
  """

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity}

  @derive {Inspect,
           only: [
             :identity_id,
             :github_user_id,
             :login,
             :display_name,
             :avatar_url,
             :profile_url,
             :credential_present,
             :credential_status,
             :identity_last_verified_at,
             :credential_last_verified_at
           ]}

  @enforce_keys [
    :identity_id,
    :github_user_id,
    :login,
    :display_name,
    :credential_present
  ]

  defstruct [
    :identity_id,
    :github_user_id,
    :login,
    :display_name,
    :avatar_url,
    :profile_url,
    :credential_status,
    :identity_last_verified_at,
    :credential_last_verified_at,
    credential_present: false
  ]

  @type t :: %__MODULE__{
          identity_id: pos_integer(),
          github_user_id: non_neg_integer(),
          login: String.t(),
          display_name: String.t(),
          avatar_url: String.t() | nil,
          profile_url: String.t() | nil,
          credential_present: boolean(),
          credential_status: :valid | :invalid | nil,
          identity_last_verified_at: DateTime.t() | nil,
          credential_last_verified_at: DateTime.t() | nil
        }

  @doc false
  @spec from(GitHubIdentity.t(), GitHubCredential.t() | nil) :: t()
  def from(%GitHubIdentity{} = identity, credential) do
    %__MODULE__{
      identity_id: identity.id,
      github_user_id: identity.github_user_id,
      login: identity.login,
      display_name: GitHubIdentity.display_name(identity),
      avatar_url:
        trusted_url(identity.avatar_url, ["avatars.githubusercontent.com", "github.com"]),
      profile_url: trusted_url(identity.profile_url, ["github.com"]),
      credential_present: match?(%GitHubCredential{}, credential),
      credential_status: credential_value(credential, :status),
      identity_last_verified_at: identity.last_verified_at,
      credential_last_verified_at: credential_value(credential, :last_verified_at)
    }
  end

  defp credential_value(%GitHubCredential{} = credential, field),
    do: Map.fetch!(credential, field)

  defp credential_value(nil, _field), do: nil

  defp trusted_url(nil, _allowed_hosts), do: nil

  defp trusted_url(url, allowed_hosts) when is_binary(url) do
    with {:ok, %URI{scheme: "https", host: host, userinfo: nil, port: port}} when is_binary(host) <-
           URI.new(url),
         true <- String.downcase(host) in allowed_hosts,
         true <- port in [nil, 443] do
      url
    else
      _ -> nil
    end
  end

  defp trusted_url(_url, _allowed_hosts), do: nil
end
