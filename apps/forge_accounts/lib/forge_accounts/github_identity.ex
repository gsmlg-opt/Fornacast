defmodule ForgeAccounts.GitHubIdentity do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:user, :deleted]
  @max_github_user_id 9_223_372_036_854_775_807
  @max_login_length 255
  @max_url_length 2_048

  @type t :: %__MODULE__{}

  schema "github_identities" do
    field :kind, Ecto.Enum, values: @kinds
    field :github_user_id, :integer
    field :login, :string
    field :avatar_url, :string
    field :profile_url, :string
    field :local_user_id, :integer
    field :last_verified_at, :utc_datetime
    field :last_observed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def observed_changeset(%__MODULE__{kind: :deleted} = identity, _attrs) do
    identity
    |> change()
    |> add_error(:kind, "cannot be observed")
  end

  def observed_changeset(%__MODULE__{} = identity, attrs) do
    identity
    |> cast(attrs, [
      :github_user_id,
      :login,
      :avatar_url,
      :profile_url,
      :last_verified_at,
      :last_observed_at
    ])
    |> put_change(:kind, :user)
    |> validate_required([:kind, :github_user_id, :login])
    |> validate_inclusion(:kind, [:user])
    |> validate_number(:github_user_id,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_github_user_id
    )
    |> validate_safe_string(:login, @max_login_length, required?: true)
    |> validate_safe_string(:avatar_url, @max_url_length)
    |> validate_safe_string(:profile_url, @max_url_length)
    |> validate_github_url(:avatar_url, ["avatars.githubusercontent.com", "github.com"])
    |> validate_github_url(:profile_url, ["github.com"])
    |> unique_constraint(:github_user_id, name: :github_identities_user_id_index)
    |> unique_constraint(:github_user_id, name: ~r/github_identities_github_user_id/)
  end

  def link_changeset(%__MODULE__{kind: :deleted} = identity, _local_user_id) do
    identity
    |> change()
    |> add_error(:kind, "cannot be linked")
  end

  def link_changeset(%__MODULE__{} = identity, local_user_id) do
    identity
    |> cast(%{local_user_id: local_user_id}, [:local_user_id])
    |> validate_required([:local_user_id])
    |> validate_number(:local_user_id, greater_than: 0)
  end

  def unlink_changeset(%__MODULE__{} = identity) do
    change(identity, local_user_id: nil)
  end

  def deleted_changeset(%__MODULE__{} = identity) do
    identity
    |> change(%{
      kind: :deleted,
      github_user_id: nil,
      login: "ghost",
      avatar_url: nil,
      profile_url: nil,
      local_user_id: nil,
      last_verified_at: nil,
      last_observed_at: nil
    })
    |> validate_required([:kind, :login])
    |> validate_inclusion(:kind, [:deleted])
    |> unique_constraint(:kind, name: :github_identities_deleted_singleton_index)
  end

  def display_name(%__MODULE__{login: login}), do: "Github:" <> login

  defp validate_safe_string(changeset, field, max_length, opts \\ []) do
    required? = Keyword.get(opts, :required?, false)

    validate_change(changeset, field, fn ^field, value ->
      cond do
        not is_binary(value) ->
          [{field, "is invalid"}]

        required? and String.trim(value) == "" ->
          [{field, "can't be blank"}]

        :binary.match(value, <<0>>) != :nomatch ->
          [{field, "contains a NUL byte"}]

        String.length(value) > max_length ->
          [{field, "should be at most #{max_length} character(s)"}]

        true ->
          []
      end
    end)
  end

  defp validate_github_url(changeset, field, allowed_hosts) do
    validate_change(changeset, field, fn ^field, url ->
      if trusted_github_url?(url, allowed_hosts),
        do: [],
        else: [{field, "is not an allowed HTTPS URL"}]
    end)
  end

  defp trusted_github_url?(url, allowed_hosts) do
    with {:ok, %URI{scheme: "https", host: host, userinfo: nil, port: port}} when is_binary(host) <-
           URI.new(url),
         normalized_host <- String.downcase(host),
         true <- normalized_host in allowed_hosts,
         true <- port in [nil, 443] do
      true
    else
      _ -> false
    end
  end
end
