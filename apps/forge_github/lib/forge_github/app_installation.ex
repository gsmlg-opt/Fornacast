defmodule ForgeGitHub.AppInstallation do
  @moduledoc "A bounded normalized GitHub App installation resource."

  @enforce_keys [
    :id,
    :account_id,
    :account_login,
    :account_type,
    :repository_selection,
    :permissions,
    :state
  ]
  defstruct @enforce_keys

  @type account_type :: :organization | :user | :enterprise
  @type repository_selection :: :all | :selected
  @type state :: :active | :suspended
  @type t :: %__MODULE__{
          id: pos_integer(),
          account_id: pos_integer(),
          account_login: String.t(),
          account_type: account_type(),
          repository_selection: repository_selection(),
          permissions: %{String.t() => String.t()},
          state: state()
        }

  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_response}
  def from_json(
        %{
          "id" => id,
          "account" => %{"id" => account_id, "type" => type} = account,
          "repository_selection" => selection,
          "permissions" => permissions
        } = json
      ) do
    with true <- valid_id?(id),
         true <- valid_id?(account_id),
         {:ok, account_type} <- account_type(type),
         {:ok, login} <- account_login(account, account_type),
         {:ok, repository_selection} <- repository_selection(selection),
         {:ok, permissions} <- validate_permissions(permissions),
         {:ok, state} <- state(Map.get(json, "suspended_at")) do
      {:ok,
       %__MODULE__{
         id: id,
         account_id: account_id,
         account_login: login,
         account_type: account_type,
         repository_selection: repository_selection,
         permissions: permissions,
         state: state
       }}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  def from_json(_json), do: {:error, :invalid_response}

  defp account_type("Organization"), do: {:ok, :organization}
  defp account_type("User"), do: {:ok, :user}
  defp account_type("Enterprise"), do: {:ok, :enterprise}
  defp account_type(_type), do: :error

  defp account_login(account, :enterprise) do
    login = Map.get(account, "login") || Map.get(account, "slug")
    if valid_login?(login), do: {:ok, login}, else: :error
  end

  defp account_login(account, _account_type) do
    login = Map.get(account, "login")
    if valid_login?(login), do: {:ok, login}, else: :error
  end

  defp repository_selection("all"), do: {:ok, :all}
  defp repository_selection("selected"), do: {:ok, :selected}
  defp repository_selection(_selection), do: :error

  defp state(nil), do: {:ok, :active}

  defp state(value) when is_binary(value) and byte_size(value) in 1..128 do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, :suspended}
      _invalid -> :error
    end
  end

  defp state(_value), do: :error

  defp valid_id?(value),
    do: is_integer(value) and value in 1..9_223_372_036_854_775_807

  defp valid_login?(value) do
    is_binary(value) and byte_size(value) in 1..255 and String.valid?(value) and
      value == String.trim(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp validate_permissions(permissions)
       when is_map(permissions) and map_size(permissions) <= 128 do
    if Enum.all?(permissions, fn {key, value} ->
         is_binary(key) and byte_size(key) in 1..128 and String.valid?(key) and
           is_binary(value) and value in ["read", "write"]
       end) do
      {:ok, permissions}
    else
      :error
    end
  end

  defp validate_permissions(_permissions), do: :error
end
