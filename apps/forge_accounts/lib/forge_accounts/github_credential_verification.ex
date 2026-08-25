defmodule ForgeAccounts.GitHubCredentialVerification do
  @moduledoc false

  @enforce_keys [
    :credential_id,
    :identity_id,
    :local_user_id,
    :verification_version,
    :generation_digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          credential_id: pos_integer(),
          identity_id: pos_integer(),
          local_user_id: pos_integer(),
          verification_version: pos_integer(),
          generation_digest: <<_::256>>
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(reference, opts) do
      concat([
        "#ForgeAccounts.GitHubCredentialVerification<",
        to_doc(
          [credential_id: reference.credential_id, identity_id: reference.identity_id],
          opts
        ),
        ">"
      ])
    end
  end
end
