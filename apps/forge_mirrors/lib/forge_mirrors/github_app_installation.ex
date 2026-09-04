defmodule ForgeMirrors.GitHubAppInstallation do
  use Ecto.Schema

  import Ecto.Changeset

  @account_types [:organization, :user, :enterprise]
  @repository_selections [:all, :selected]
  @states [:active, :suspended, :revoked]

  @type t :: %__MODULE__{}

  schema "github_app_installations" do
    field :github_installation_id, :integer
    field :github_account_id, :integer
    field :github_account_login, :string
    field :account_type, Ecto.Enum, values: @account_types
    field :repository_selection, Ecto.Enum, values: @repository_selections
    field :permissions, :map, default: %{}
    field :state, Ecto.Enum, values: @states
    field :last_verified_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  def legal_transition?(state, state) when state in [:active, :suspended], do: true
  def legal_transition?(:active, target) when target in [:suspended, :revoked], do: true
  def legal_transition?(:suspended, target) when target in [:active, :revoked], do: true
  def legal_transition?(_state, _target), do: false

  def observation_changeset(installation, attrs) do
    installation
    |> cast(attrs, [
      :github_installation_id,
      :github_account_id,
      :github_account_login,
      :account_type,
      :repository_selection,
      :permissions,
      :state,
      :last_verified_at
    ])
    |> validate_required([
      :github_installation_id,
      :github_account_id,
      :github_account_login,
      :account_type,
      :repository_selection,
      :permissions,
      :state,
      :last_verified_at
    ])
    |> validate_number(:github_installation_id,
      greater_than: 0,
      less_than_or_equal_to: 9_223_372_036_854_775_807
    )
    |> validate_number(:github_account_id,
      greater_than: 0,
      less_than_or_equal_to: 9_223_372_036_854_775_807
    )
    |> validate_length(:github_account_login, min: 1, max: 255, count: :bytes)
    |> validate_trimmed_login()
    |> validate_permissions()
    |> unique_constraint(:github_installation_id)
    |> check_constraint(:github_installation_id,
      name: :github_app_installations_installation_id_check
    )
    |> check_constraint(:github_account_id, name: :github_app_installations_account_id_check)
    |> check_constraint(:github_account_login,
      name: :github_app_installations_account_login_check
    )
    |> check_constraint(:account_type, name: :github_app_installations_account_type_check)
    |> check_constraint(:repository_selection,
      name: :github_app_installations_repository_selection_check
    )
    |> check_constraint(:permissions, name: :github_app_installations_permissions_check)
    |> check_constraint(:state, name: :github_app_installations_state_check)
  end

  def update_observation_changeset(installation, attrs) do
    installation
    |> cast(attrs, [
      :github_account_login,
      :repository_selection,
      :permissions,
      :state,
      :last_verified_at
    ])
    |> validate_required([
      :github_account_login,
      :repository_selection,
      :permissions,
      :state,
      :last_verified_at
    ])
    |> validate_length(:github_account_login, min: 1, max: 255, count: :bytes)
    |> validate_trimmed_login()
    |> validate_permissions()
    |> check_constraint(:github_account_login,
      name: :github_app_installations_account_login_check
    )
    |> check_constraint(:repository_selection,
      name: :github_app_installations_repository_selection_check
    )
    |> check_constraint(:permissions, name: :github_app_installations_permissions_check)
    |> check_constraint(:state, name: :github_app_installations_state_check)
  end

  defp validate_trimmed_login(changeset) do
    validate_change(changeset, :github_account_login, fn :github_account_login, value ->
      if value == String.trim(value) and String.valid?(value) and
           :binary.match(value, <<0>>) == :nomatch,
         do: [],
         else: [github_account_login: "is invalid"]
    end)
  end

  defp validate_permissions(changeset) do
    validate_change(changeset, :permissions, fn :permissions, permissions ->
      cond do
        not is_map(permissions) or map_size(permissions) == 0 ->
          [permissions: "must be a non-empty object"]

        map_size(permissions) > 128 ->
          [permissions: "has too many entries"]

        not Enum.all?(permissions, fn {key, value} ->
          is_binary(key) and byte_size(key) in 1..128 and String.valid?(key) and
            is_binary(value) and value in ["read", "write"]
        end) ->
          [permissions: "contains an invalid permission"]

        encoded_size(permissions) > 65_536 ->
          [permissions: "is too large"]

        true ->
          []
      end
    end)
  end

  defp encoded_size(value) do
    value |> JSON.encode_to_iodata!() |> IO.iodata_length()
  rescue
    _exception -> 65_537
  end
end
