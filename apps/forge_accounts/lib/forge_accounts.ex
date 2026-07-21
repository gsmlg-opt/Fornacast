defmodule ForgeAccounts do
  @moduledoc """
  Account, password, and SSH-key management for Fornacast.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.Multi
  alias ForgeAccounts.{APIKey, APIScope, Organization, OrganizationMember, SSHKey, User}
  alias Fornacast.Repo

  def get_account(id), do: Repo.get(User, id)

  def get_account_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: normalize_username(username))
  end

  def get_user(id), do: Repo.get_by(User, id: id, kind: :user)

  def get_user!(id), do: Repo.get_by!(User, id: id, kind: :user)

  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: normalize_username(username), kind: :user)
  end

  def get_organization(id), do: Repo.get_by(Organization, id: id, kind: :organization)

  def get_organization_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Organization, username: normalize_username(slug), kind: :organization)
  end

  def admin_exists? do
    Repo.exists?(from user in User, where: user.kind == :user and user.role == :admin)
  end

  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(Map.put(attrs, :role, :user))
    |> Repo.insert()
  end

  def create_admin(attrs) do
    %User{}
    |> User.registration_changeset(Map.put(attrs, :role, :admin))
    |> Repo.insert()
  end

  def ensure_development_admin(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:role, :admin)
      |> Map.put_new(:state, :active)
      |> Map.update!(:username, &normalize_username/1)

    case get_user_by_username(attrs.username) do
      %User{} = user -> update_development_admin(user, attrs)
      nil -> create_development_admin(attrs)
    end
  end

  def create_first_admin(attrs) do
    Repo.transaction(fn ->
      if admin_exists?() do
        Repo.rollback(:admin_exists)
      else
        case create_admin(attrs) do
          {:ok, user} -> user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  defp create_development_admin(attrs) do
    %User{}
    |> User.registration_changeset(Map.put(attrs, :role, :admin), password_min_length: 1)
    |> Repo.insert()
  end

  defp update_development_admin(%User{} = user, attrs) do
    user
    |> User.registration_changeset(attrs, password_min_length: 1)
    |> Repo.update()
  end

  def create_organization(%User{kind: :user, state: :active, id: owner_id}, attrs)
      when is_map(attrs) do
    changeset = Organization.changeset(%Organization{}, attrs)

    with {:ok, changeset} <- reject_taken_account_slug(changeset) do
      insert_organization(owner_id, changeset)
    end
  end

  def create_organization(_owner, _attrs), do: {:error, :unauthorized}

  defp insert_organization(owner_id, changeset) do
    Multi.new()
    |> Multi.insert(:organization, changeset)
    |> Multi.run(:owner_membership, fn repo, %{organization: organization} ->
      %OrganizationMember{}
      |> OrganizationMember.changeset(%{
        organization_id: organization.id,
        user_id: owner_id,
        role: :owner
      })
      |> repo.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: organization}} -> {:ok, organization}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def add_organization_member(organization, %User{kind: :user, id: user_id}, role \\ :member) do
    organization_id = organization_id(organization)

    %OrganizationMember{}
    |> OrganizationMember.changeset(%{
      organization_id: organization_id,
      user_id: user_id,
      role: role
    })
    |> Repo.insert()
  end

  def list_user_organizations(%User{id: user_id}) do
    Organization
    |> join(:inner, [organization], member in OrganizationMember,
      on: member.organization_id == organization.id
    )
    |> where(
      [organization, member],
      organization.kind == :organization and member.user_id == ^user_id
    )
    |> order_by([organization], asc: organization.username)
    |> Repo.all()
  end

  def list_repository_owners(%User{kind: :user} = user) do
    [user | list_owned_organizations(user)]
  end

  def repository_owner_by_slug_for(%User{kind: :user, state: :active} = user, slug)
      when is_binary(slug) do
    slug = normalize_username(slug)

    cond do
      slug == user.username ->
        {:ok, user}

      organization = get_organization_by_slug(slug) ->
        if can_manage_organization?(user, organization) do
          {:ok, organization}
        else
          {:error, :unauthorized}
        end

      true ->
        {:error, :not_found}
    end
  end

  def repository_owner_by_slug_for(_user, _slug), do: {:error, :unauthorized}

  def organization_role(%User{kind: :user, id: user_id}, organization) do
    organization_id = organization_id(organization)

    OrganizationMember
    |> where([member], member.organization_id == ^organization_id and member.user_id == ^user_id)
    |> select([member], member.role)
    |> Repo.one()
  end

  def organization_role(_user, _organization), do: nil

  def authenticate_password(username, password)
      when is_binary(username) and is_binary(password) do
    case get_user_by_username(username) do
      %User{state: :active, password_hash: password_hash} = user ->
        if Bcrypt.verify_pass(password, password_hash), do: {:ok, user}, else: password_error()

      _ ->
        password_error()
    end
  end

  def authenticate_password(_, _) do
    password_error()
  end

  def create_api_key(%User{kind: :user, state: :active, id: user_id}, attrs) when is_map(attrs) do
    {secret, token_prefix, token_hash} = APIKey.generate_secret()

    result =
      %APIKey{user_id: user_id, token_prefix: token_prefix, token_hash: token_hash}
      |> APIKey.creation_changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, api_key} -> {:ok, api_key, secret}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def create_api_key(_user, _attrs), do: {:error, :unauthorized}

  def list_user_api_keys(%User{id: user_id}) do
    APIKey
    |> where([key], key.user_id == ^user_id)
    |> order_by([key], desc: key.inserted_at)
    |> select(
      [key],
      struct(key, [
        :id,
        :user_id,
        :name,
        :token_prefix,
        :scopes,
        :expires_at,
        :last_used_at,
        :revoked_at,
        :inserted_at,
        :updated_at
      ])
    )
    |> Repo.all()
  end

  def revoke_api_key(%User{id: user_id}, key_id) do
    revoked_at = DateTime.utc_now(:second)

    {updated_count, _} =
      APIKey
      |> where([key], key.id == ^key_id and key.user_id == ^user_id and is_nil(key.revoked_at))
      |> Repo.update_all(set: [revoked_at: revoked_at, updated_at: revoked_at])

    case updated_count do
      1 -> {:ok, Repo.get!(APIKey, key_id)}
      0 -> {:error, :not_found}
    end
  end

  @spec authenticate_api_key(String.t()) ::
          {:ok, User.t(), APIKey.t()} | {:error, :invalid_credentials}
  def authenticate_api_key(secret) when is_binary(secret) do
    with {%User{} = user, %APIKey{} = api_key} <- find_api_key(secret),
         {:ok, authenticated_key} <- touch_active_api_key(api_key) do
      {:ok, user, authenticated_key}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def authenticate_api_key(_secret), do: {:error, :invalid_credentials}

  @spec authenticate_api_key(String.t(), String.t()) ::
          {:ok, User.t(), APIKey.t()} | {:error, :invalid_credentials}
  def authenticate_api_key(username, secret)
      when is_binary(username) and is_binary(secret) do
    with {%User{} = user, %APIKey{} = api_key} <- find_api_key(secret),
         true <- user.username == normalize_username(username),
         {:ok, authenticated_key} <- touch_active_api_key(api_key) do
      {:ok, user, authenticated_key}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def authenticate_api_key(_username, _secret), do: {:error, :invalid_credentials}

  @spec authenticate_api_key(String.t(), String.t(), String.t()) ::
          {:ok, User.t(), APIKey.t()} | {:error, :invalid_credentials | :insufficient_scope}
  def authenticate_api_key(username, secret, required_scope)
      when is_binary(username) and is_binary(secret) and is_binary(required_scope) do
    with {%User{} = user, %APIKey{} = api_key} <- find_api_key(secret),
         true <- user.username == normalize_username(username),
         :ok <- authorize_api_key_scope(api_key, required_scope),
         {:ok, authenticated_key} <- touch_active_api_key(api_key) do
      {:ok, user, authenticated_key}
    else
      {:error, :insufficient_scope} = error -> error
      _ -> {:error, :invalid_credentials}
    end
  end

  def authenticate_api_key(_, _, _), do: {:error, :invalid_credentials}

  def create_ssh_key(%User{} = user, attrs) do
    %SSHKey{user_id: user.id}
    |> SSHKey.changeset(attrs)
    |> Repo.insert()
  end

  def list_user_ssh_keys(%User{id: user_id}), do: list_user_ssh_keys(user_id)

  def list_user_ssh_keys(user_id) do
    SSHKey
    |> where([key], key.user_id == ^user_id)
    |> order_by([key], desc: key.inserted_at)
    |> Repo.all()
  end

  def delete_ssh_key(%User{id: user_id}, key_id) do
    case Repo.get_by(SSHKey, id: key_id, user_id: user_id) do
      nil -> {:error, :not_found}
      key -> Repo.delete(key)
    end
  end

  def authorized_ssh_key?(username, public_key) do
    match?({:ok, _user}, authenticate_ssh_key(username, public_key))
  end

  def authenticate_ssh_key(username, public_key)
      when is_binary(username) and is_binary(public_key) do
    with %User{state: :active} = user <- get_user_by_username(username),
         {:ok, fingerprint} <- SSHKey.fingerprint(public_key),
         %SSHKey{} = key <- Repo.get_by(SSHKey, user_id: user.id, fingerprint_sha256: fingerprint) do
      touch_ssh_key(key)
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate_ssh_key(username, decoded_public_key) when is_binary(username) do
    with %User{state: :active} = user <- get_user_by_username(username),
         %SSHKey{} = key <- find_matching_ssh_key(user, decoded_public_key) do
      touch_ssh_key(key)
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate_ssh_key(_, _), do: {:error, :unauthorized}

  defp password_error do
    Bcrypt.no_user_verify()
    {:error, :invalid_credentials}
  end

  defp find_api_key(secret) do
    token_prefix = String.slice(secret, 0, 15)
    token_hash = APIKey.hash(secret)
    token_hash_bytes = byte_size(token_hash)
    now = DateTime.utc_now(:second)

    APIKey
    |> join(:inner, [key], user in User, on: user.id == key.user_id)
    |> where(
      [key, user],
      key.token_prefix == ^token_prefix and is_nil(key.revoked_at) and
        (is_nil(key.expires_at) or key.expires_at > ^now) and user.kind == :user and
        user.state == :active
    )
    |> select([key, user], {user, key})
    |> Repo.all()
    |> Enum.filter(fn {_user, key} ->
      is_binary(key.token_hash) and byte_size(key.token_hash) == token_hash_bytes and
        :crypto.hash_equals(key.token_hash, token_hash)
    end)
    |> case do
      [match] -> match
      _matches -> nil
    end
  end

  defp authorize_api_key_scope(%APIKey{} = api_key, "repo:read"),
    do: APIScope.authorize(api_key, :git_read, :private)

  defp authorize_api_key_scope(%APIKey{} = api_key, "repo:write"),
    do: APIScope.authorize(api_key, :git_write, :private)

  defp authorize_api_key_scope(%APIKey{}, _scope), do: {:error, :insufficient_scope}

  defp touch_active_api_key(%APIKey{id: key_id, user_id: user_id} = api_key) do
    now = DateTime.utc_now(:second)

    active_user_ids =
      User
      |> where([user], user.id == ^user_id and user.kind == :user and user.state == :active)
      |> select([user], user.id)

    {updated_count, _} =
      APIKey
      |> where(
        [key],
        key.id == ^key_id and key.user_id in subquery(active_user_ids) and
          is_nil(key.revoked_at) and (is_nil(key.expires_at) or key.expires_at > ^now)
      )
      |> Repo.update_all(set: [last_used_at: now, updated_at: now])

    case updated_count do
      1 -> {:ok, %{api_key | last_used_at: now, updated_at: now}}
      0 -> {:error, :invalid_credentials}
    end
  end

  defp reject_taken_account_slug(%Changeset{valid?: true} = changeset) do
    username = Changeset.get_field(changeset, :username)

    if get_account_by_username(username) do
      {:error, Changeset.add_error(changeset, :username, "has already been taken")}
    else
      {:ok, changeset}
    end
  end

  defp reject_taken_account_slug(changeset), do: {:ok, changeset}

  defp list_owned_organizations(%User{id: user_id}) do
    Organization
    |> join(:inner, [organization], member in OrganizationMember,
      on: member.organization_id == organization.id
    )
    |> where(
      [organization, member],
      organization.kind == :organization and member.user_id == ^user_id and member.role == :owner
    )
    |> order_by([organization], asc: organization.username)
    |> Repo.all()
  end

  defp can_manage_organization?(%User{role: :admin}, %Organization{}), do: true

  defp can_manage_organization?(%User{} = user, %Organization{} = organization) do
    organization_role(user, organization) == :owner
  end

  defp organization_id(%Organization{id: id}), do: id
  defp organization_id(%User{kind: :organization, id: id}), do: id

  defp touch_ssh_key(%SSHKey{id: id}) do
    from(key in SSHKey, where: key.id == ^id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])

    :ok
  end

  defp find_matching_ssh_key(%User{} = user, decoded_public_key) do
    user
    |> list_user_ssh_keys()
    |> Enum.find(fn key ->
      case SSHKey.decode_public_key(key.public_key) do
        {:ok, stored_public_key} -> stored_public_key == decoded_public_key
        {:error, _reason} -> false
      end
    end)
  end

  defp normalize_username(username) do
    username
    |> String.trim()
    |> String.downcase()
  end
end
