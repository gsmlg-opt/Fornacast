defmodule ForgeGitHub.InstallationToken do
  @moduledoc "A short-lived installation credential with redacted inspection."

  @enforce_keys [:token, :expires_at, :permissions]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          token: String.t(),
          expires_at: DateTime.t(),
          permissions: %{String.t() => String.t()}
        }

  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_response}
  def from_json(%{
        "token" => token,
        "expires_at" => expires_at,
        "permissions" => permissions
      }) do
    with true <- valid_token?(token),
         {:ok, expires_at, 0} <- DateTime.from_iso8601(expires_at),
         true <- valid_permissions?(permissions) do
      {:ok,
       %__MODULE__{
         token: token,
         expires_at: DateTime.truncate(expires_at, :second),
         permissions: permissions
       }}
    else
      _invalid -> {:error, :invalid_response}
    end
  rescue
    _exception -> {:error, :invalid_response}
  end

  def from_json(_json), do: {:error, :invalid_response}

  defp valid_token?(token) do
    is_binary(token) and byte_size(token) in 1..16_384 and String.valid?(token) and
      :binary.match(token, <<0>>) == :nomatch
  end

  defp valid_permissions?(permissions)
       when is_map(permissions) and map_size(permissions) <= 128 do
    Enum.all?(permissions, fn {key, value} ->
      is_binary(key) and byte_size(key) in 1..128 and is_binary(value) and
        value in ["read", "write"]
    end)
  end

  defp valid_permissions?(_permissions), do: false
end

defimpl Inspect, for: ForgeGitHub.InstallationToken do
  import Inspect.Algebra

  def inspect(token, opts) do
    concat([
      "#ForgeGitHub.InstallationToken<",
      to_doc(
        [token: "[REDACTED]", expires_at: token.expires_at, permissions: token.permissions],
        opts
      ),
      ">"
    ])
  end
end
