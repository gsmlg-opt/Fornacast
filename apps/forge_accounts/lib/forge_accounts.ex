defmodule ForgeAccounts do
  @moduledoc """
  Account, password, and SSH-key management for Fornacast.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.Multi

  alias ForgeAccounts.{
    APIKey,
    APIScope,
    ExternalAttribution,
    GitHubAccounts,
    GitHubIdentity,
    GitHubIdentityWrite,
    Organization,
    OrganizationMember,
    SSHKey,
    User
  }

  alias Fornacast.{Audit, Page, Repo}

  @spec validate_namespace_slug(term()) :: {:ok, String.t()} | {:error, :invalid | :reserved}
  def validate_namespace_slug(value), do: ForgeAccounts.Namespace.validate(value)

  def reserved_namespace?(value), do: ForgeAccounts.Namespace.reserved?(value)

  @type validation_error :: %{
          required(:resource) => String.t(),
          required(:field) => String.t(),
          required(:code) =>
            :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
          optional(:message) => String.t()
        }

  @type api_error :: :forbidden | :not_found | {:validation, [validation_error()]}

  defdelegate list_github_accounts(actor), to: GitHubAccounts

  @doc false
  defdelegate github_account_reference(actor, identity_id), to: GitHubAccounts

  @doc false
  defdelegate github_account_references(actor), to: GitHubAccounts

  @doc false
  defdelegate validate_github_link_request(actor, request_metadata), to: GitHubAccounts

  @doc false
  defdelegate validate_github_account_request(actor, identity_id, request_metadata),
    to: GitHubAccounts

  @doc false
  defdelegate validate_github_import_request(actor, reference, request_metadata, profiles),
    to: GitHubAccounts

  @doc false
  def validate_github_request_metadata(metadata, credential \\ nil),
    do: ForgeAccounts.GitHubRequestMetadata.validate(metadata, credential)

  defdelegate save_github_account(actor, verified_profile, pat, request_metadata),
    to: GitHubAccounts

  @doc false
  defdelegate save_github_account_if_absent(actor, verified_profile, pat, request_metadata),
    to: GitHubAccounts

  @doc false
  defdelegate save_github_credential_if_absent(
                actor,
                identity_id,
                verified_profile,
                pat,
                request_metadata
              ),
              to: GitHubAccounts

  defdelegate replace_github_credential(
                actor,
                identity_id,
                verified_profile,
                pat,
                request_metadata
              ),
              to: GitHubAccounts

  @doc false
  defdelegate replace_github_credential_if_current(
                actor,
                identity_id,
                reference,
                verified_profile,
                pat,
                request_metadata
              ),
              to: GitHubAccounts

  defdelegate refresh_github_account(actor, identity_id, verified_profile, request_metadata),
    to: GitHubAccounts

  @doc false
  defdelegate refresh_github_account_if_current(
                actor,
                identity_id,
                reference,
                verified_profile,
                request_metadata
              ),
              to: GitHubAccounts

  @doc false
  defdelegate mark_github_credential_invalid(
                actor,
                identity_id,
                reference,
                request_metadata
              ),
              to: GitHubAccounts

  defdelegate delete_github_credential(actor, identity_id, request_metadata),
    to: GitHubAccounts

  @doc false
  defdelegate delete_github_credential(actor, identity_id, request_metadata, before_delete),
    to: GitHubAccounts

  defdelegate unlink_github_account(actor, identity_id, request_metadata),
    to: GitHubAccounts

  @doc false
  defdelegate unlink_github_account(actor, identity_id, request_metadata, before_unlink),
    to: GitHubAccounts

  @doc """
  Checks a saved PAT out only to a trusted internal callback.

  The callback may perform durable side effects, but it may return only `:ok` or a bounded
  `{:error, reason}` made from atoms and integers. Public results and exceptions never carry
  plaintext credentials. Deletion or unlink prevents future checkouts; a callback that already
  received the credential may finish.
  """
  defdelegate with_github_credential(actor, identity_id, callback), to: GitHubAccounts

  @doc false
  defdelegate with_github_credential_for_verification(actor, identity_id, callback),
    to: GitHubAccounts

  @doc false
  defdelegate with_github_import_credential(actor, identity_id, credential_id, callback),
    to: GitHubAccounts

  @doc false
  defdelegate validate_github_external_profile(actor, profile), to: GitHubAccounts

  @doc false
  defdelegate validate_github_external_profiles(actor, profiles), to: GitHubAccounts

  def get_account(id), do: Repo.get(User, id)

  def get_account_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: normalize_username(username))
  end

  def get_user(id), do: Repo.get_by(User, id: id, kind: :user)

  def get_users(ids) when is_list(ids) do
    User
    |> where([user], user.id in ^Enum.uniq(ids) and user.kind == :user)
    |> Repo.all()
  end

  @type attribution_ref :: {:user, pos_integer()} | {:github, pos_integer()}
  @type attribution_subject :: User.t() | ExternalAttribution.t()

  @spec resolve_attributions([attribution_ref()]) :: %{attribution_ref() => attribution_subject()}
  def resolve_attributions(refs) when is_list(refs) do
    refs = Enum.uniq(refs)

    user_ids = for {:user, id} <- refs, do: id

    users_by_id =
      user_ids
      |> Enum.uniq()
      |> get_users()
      |> Map.new(&{&1.id, &1})

    user_refs =
      refs
      |> Enum.filter(&match?({:user, _}, &1))
      |> Map.new(fn {:user, id} = ref ->
        case Map.fetch(users_by_id, id) do
          {:ok, user} -> {ref, user}
          :error -> {ref, nil}
        end
      end)
      |> Enum.reject(fn {_ref, value} -> is_nil(value) end)
      |> Map.new()

    github_ids = for {:github, id} <- refs, do: id

    github_refs =
      if github_ids == [] do
        %{}
      else
        linked_user_ids =
          GitHubIdentity
          |> where([identity], identity.id in ^github_ids and not is_nil(identity.local_user_id))
          |> select([identity], {identity.id, identity.local_user_id})
          |> Repo.all()
          |> Map.new()

        linked_users =
          linked_user_ids
          |> Map.values()
          |> Enum.uniq()
          |> get_users()
          |> Map.new(&{&1.id, &1})

        GitHubIdentity
        |> where([identity], identity.id in ^github_ids)
        |> Repo.all()
        |> Map.new(fn identity ->
          value =
            case Map.get(linked_user_ids, identity.id) do
              nil -> ExternalAttribution.from_identity(identity)
              linked_id -> Map.fetch!(linked_users, linked_id)
            end

          {{:github, identity.id}, value}
        end)
      end

    Map.merge(user_refs, github_refs)
  end

  @spec linked_user_id_for_github_identity(pos_integer()) :: pos_integer() | nil
  def linked_user_id_for_github_identity(github_identity_id)
      when is_integer(github_identity_id) do
    case Repo.get(GitHubIdentity, github_identity_id) do
      %GitHubIdentity{local_user_id: local_user_id} -> local_user_id
      nil -> nil
    end
  end

  def get_user!(id), do: Repo.get_by!(User, id: id, kind: :user)

  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: normalize_username(username), kind: :user)
  end

  @spec get_public_user(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_public_user(username) when is_binary(username) do
    case Repo.get_by(User,
           username: normalize_username(username),
           kind: :user,
           state: :active
         ) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  def get_public_user(_username), do: {:error, :not_found}

  def get_organization(id), do: Repo.get_by(Organization, id: id, kind: :organization)

  def get_organization_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Organization, username: normalize_username(slug), kind: :organization)
  end

  @spec get_public_organization(String.t()) :: {:ok, Organization.t()} | {:error, :not_found}
  def get_public_organization(slug) when is_binary(slug) do
    case Repo.get_by(Organization,
           username: normalize_username(slug),
           kind: :organization,
           state: :active
         ) do
      %Organization{} = organization -> {:ok, organization}
      nil -> {:error, :not_found}
    end
  end

  def get_public_organization(_slug), do: {:error, :not_found}

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

  def observe_github_identity(profile, observed_at)
      when is_map(profile) and is_struct(observed_at, DateTime) do
    attrs =
      profile
      |> github_profile_attrs()
      |> Map.put(:last_verified_at, observed_at)
      |> Map.put(:last_observed_at, observed_at)

    changeset = GitHubIdentity.observed_changeset(%GitHubIdentity{}, attrs)

    if changeset.valid?,
      do: upsert_github_identity(changeset, attrs.github_user_id),
      else: {:error, changeset}
  end

  def observe_github_identity(_profile, _observed_at), do: {:error, :invalid}

  def link_github_identity(local_user, %GitHubIdentity{id: identity_id})
      when is_integer(identity_id) do
    with {:ok, %User{id: local_user_id}} <- active_actor(local_user),
         %GitHubIdentity{kind: :user} = identity <- Repo.get(GitHubIdentity, identity_id) do
      cond do
        identity.local_user_id in [nil, local_user_id] ->
          claim_github_identity(identity_id, local_user_id)

        true ->
          {:error, :already_linked}
      end
    else
      nil -> {:error, :not_found}
      %GitHubIdentity{} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
      {:ok, _} -> {:error, :forbidden}
    end
  end

  def link_github_identity(_local_user, _identity), do: {:error, :forbidden}

  def unlink_github_identity(local_user, %GitHubIdentity{id: identity_id})
      when is_integer(identity_id) do
    with {:ok, %User{id: local_user_id}} <- active_actor(local_user) do
      unlink_github_identity_write(identity_id, local_user_id)
    end
  end

  def unlink_github_identity(_local_user, _identity), do: {:error, :forbidden}

  def list_github_identities(%User{id: local_user_id}) do
    GitHubIdentity
    |> where([identity], identity.local_user_id == ^local_user_id)
    |> order_by([identity], asc: identity.github_user_id, asc: identity.id)
    |> Repo.all()
  end

  def list_github_identities(_local_user), do: []

  def github_deleted_identity,
    do: GitHubIdentityWrite.with_retry(&fetch_github_deleted_identity/0)

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

  @doc false
  @spec github_import_organization_multi(
          Multi.t(),
          Multi.name(),
          User.t(),
          map(),
          map(),
          String.t()
        ) :: Multi.t()
  def github_import_organization_multi(
        %Multi{} = multi,
        key,
        %User{kind: :user, state: :active, id: owner_id} = actor,
        attrs,
        request_metadata,
        operation_id
      )
      when is_map(attrs) and is_map(request_metadata) and is_binary(operation_id) do
    multi
    |> Multi.insert(key, Organization.changeset(%Organization{}, attrs))
    |> Multi.insert({key, :owner_membership}, fn %{^key => organization} ->
      OrganizationMember.changeset(%OrganizationMember{}, %{
        organization_id: organization.id,
        user_id: owner_id,
        role: :owner
      })
    end)
    |> Audit.record_multi(
      {key, :audit},
      actor,
      "organization.created",
      "organization",
      fn %{^key => organization} -> organization.id end,
      fn %{^key => organization} ->
        %{
          "login" => organization.username,
          "admin" => actor.username,
          "result" => "success"
        }
      end,
      request_metadata: request_metadata,
      operation_id: operation_id
    )
  end

  def github_import_organization_multi(%Multi{} = multi, key, _actor, _attrs, _metadata, _id),
    do: Multi.error(multi, key, :forbidden)

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

  @spec create_api_organization(User.t(), map(), map()) ::
          {:ok, Organization.t()} | {:error, api_error()}
  def create_api_organization(%User{} = actor, attrs, request_metadata)
      when is_map(attrs) and is_map(request_metadata) do
    with {:ok, active_actor} <- active_actor(actor),
         {:ok, params, changeset} <- validate_api_organization_create(attrs),
         {:ok, owner} <- authorize_organization_admin(active_actor, params.admin) do
      Multi.new()
      |> Multi.insert(:organization, changeset)
      |> Multi.insert(:owner_membership, fn %{organization: organization} ->
        OrganizationMember.changeset(%OrganizationMember{}, %{
          organization_id: organization.id,
          user_id: owner.id,
          role: :owner
        })
      end)
      |> Audit.record_multi(
        :audit,
        active_actor,
        "organization.created",
        "organization",
        fn %{organization: organization} -> organization.id end,
        fn %{organization: organization} ->
          %{
            "login" => organization.username,
            "admin" => owner.username,
            "result" => "success"
          }
        end,
        request_metadata: request_metadata
      )
      |> Repo.transaction()
      |> map_create_organization_result()
    end
  end

  def create_api_organization(_actor, _attrs, _request_metadata), do: {:error, :forbidden}

  @spec update_organization(User.t(), Organization.t(), map(), map()) ::
          {:ok, Organization.t()} | {:error, api_error()}
  def update_organization(
        %User{} = actor,
        %Organization{id: organization_id, kind: :organization},
        attrs,
        request_metadata
      )
      when is_map(attrs) and is_map(request_metadata) do
    with {:ok, active_actor} <- active_actor(actor),
         {:ok, organization} <- active_organization(organization_id),
         :ok <- authorize_organization_update(active_actor, organization),
         {:ok, changeset} <- validate_api_organization_update(organization, attrs) do
      Multi.new()
      |> Multi.update(:organization, changeset)
      |> Audit.record_multi(
        :audit,
        active_actor,
        "organization.updated",
        "organization",
        fn %{organization: updated} -> updated.id end,
        fn %{organization: updated} ->
          %{"login" => updated.username, "result" => "success"}
        end,
        request_metadata: request_metadata
      )
      |> Repo.transaction()
      |> map_update_organization_result()
    end
  end

  def update_organization(_actor, _organization, _attrs, _request_metadata),
    do: {:error, :forbidden}

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

  @spec list_user_organizations(User.t(), keyword()) ::
          {:ok, Page.t(Organization.t())}
  def list_user_organizations(%User{id: user_id}, opts) when is_list(opts) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 30)

    query =
      Organization
      |> join(:inner, [organization], member in OrganizationMember,
        on: member.organization_id == organization.id
      )
      |> where(
        [organization, member],
        organization.kind == :organization and organization.state == :active and
          member.user_id == ^user_id
      )

    total = Repo.aggregate(query, :count, :id)
    offset = (page - 1) * per_page

    entries =
      if offset >= total do
        []
      else
        query
        |> order_by([organization], asc: organization.username, asc: organization.id)
        |> offset(^offset)
        |> limit(^per_page)
        |> Repo.all()
      end

    {:ok, %Page{entries: entries, total: total, page: page, per_page: per_page}}
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

  def organization_roles(user_ids, organization) when is_list(user_ids) do
    organization_id = organization_id(organization)

    OrganizationMember
    |> where(
      [member],
      member.organization_id == ^organization_id and member.user_id in ^Enum.uniq(user_ids)
    )
    |> select([member], {member.user_id, member.role})
    |> Repo.all()
    |> Map.new()
  end

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

  defp validate_api_organization_create(attrs) do
    login = fetch_param(attrs, :login)
    admin = fetch_param(attrs, :admin)
    profile_name = fetch_param(attrs, :profile_name)

    errors =
      validate_required_string("login", login) ++
        validate_required_string("admin", admin) ++
        validate_optional_string("profile_name", profile_name)

    if errors == [] do
      login = login |> elem(1) |> normalize_username()
      admin = admin |> elem(1) |> normalize_username()

      organization_attrs = %{"username" => login}

      organization_attrs =
        case profile_name do
          {:ok, value} -> Map.put(organization_attrs, "display_name", value)
          :missing -> organization_attrs
        end

      changeset = Organization.changeset(%Organization{}, organization_attrs)

      if changeset.valid? do
        {:ok, %{login: login, admin: admin}, changeset}
      else
        {:error,
         {:validation,
          changeset_errors(changeset, %{
            username: "login",
            email: "login",
            display_name: "profile_name"
          })}}
      end
    else
      {:error, {:validation, errors}}
    end
  end

  defp upsert_github_identity(changeset, github_user_id) do
    GitHubIdentityWrite.with_retry(fn ->
      with {:ok, _identity} <-
             Repo.insert(changeset,
               on_conflict: observed_identity_on_conflict(),
               conflict_target: github_identity_conflict_target()
             ) do
        {:ok, Repo.get_by!(GitHubIdentity, github_user_id: github_user_id)}
      end
    end)
  end

  defp observed_identity_on_conflict do
    if turso?(),
      do: turso_observed_identity_on_conflict(),
      else: postgres_observed_identity_on_conflict()
  end

  defp postgres_observed_identity_on_conflict do
    from(identity in GitHubIdentity,
      update: [
        set: [
          login:
            fragment(
              "CASE WHEN ? IS NULL OR EXCLUDED.last_observed_at >= ? THEN EXCLUDED.login ELSE ? END",
              identity.last_observed_at,
              identity.last_observed_at,
              identity.login
            ),
          avatar_url:
            fragment(
              "CASE WHEN ? IS NULL OR EXCLUDED.last_observed_at >= ? THEN EXCLUDED.avatar_url ELSE ? END",
              identity.last_observed_at,
              identity.last_observed_at,
              identity.avatar_url
            ),
          profile_url:
            fragment(
              "CASE WHEN ? IS NULL OR EXCLUDED.last_observed_at >= ? THEN EXCLUDED.profile_url ELSE ? END",
              identity.last_observed_at,
              identity.last_observed_at,
              identity.profile_url
            ),
          last_verified_at:
            fragment(
              "CASE WHEN ? IS NULL OR EXCLUDED.last_observed_at >= ? THEN EXCLUDED.last_verified_at ELSE ? END",
              identity.last_observed_at,
              identity.last_observed_at,
              identity.last_verified_at
            ),
          last_observed_at:
            fragment(
              "CASE WHEN ? IS NULL OR EXCLUDED.last_observed_at >= ? THEN EXCLUDED.last_observed_at ELSE ? END",
              identity.last_observed_at,
              identity.last_observed_at,
              identity.last_observed_at
            ),
          updated_at:
            fragment(
              "CASE WHEN ? IS NULL OR EXCLUDED.last_observed_at >= ? THEN EXCLUDED.updated_at ELSE ? END",
              identity.last_observed_at,
              identity.last_observed_at,
              identity.updated_at
            )
        ]
      ]
    )
  end

  defp turso_observed_identity_on_conflict do
    from(_identity in GitHubIdentity,
      update: [
        set: [
          login:
            fragment(
              "CASE WHEN last_observed_at IS NULL OR EXCLUDED.last_observed_at >= last_observed_at THEN EXCLUDED.login ELSE login END"
            ),
          avatar_url:
            fragment(
              "CASE WHEN last_observed_at IS NULL OR EXCLUDED.last_observed_at >= last_observed_at THEN EXCLUDED.avatar_url ELSE avatar_url END"
            ),
          profile_url:
            fragment(
              "CASE WHEN last_observed_at IS NULL OR EXCLUDED.last_observed_at >= last_observed_at THEN EXCLUDED.profile_url ELSE profile_url END"
            ),
          last_verified_at:
            fragment(
              "CASE WHEN last_observed_at IS NULL OR EXCLUDED.last_observed_at >= last_observed_at THEN EXCLUDED.last_verified_at ELSE last_verified_at END"
            ),
          last_observed_at:
            fragment(
              "CASE WHEN last_observed_at IS NULL OR EXCLUDED.last_observed_at >= last_observed_at THEN EXCLUDED.last_observed_at ELSE last_observed_at END"
            ),
          updated_at:
            fragment(
              "CASE WHEN last_observed_at IS NULL OR EXCLUDED.last_observed_at >= last_observed_at THEN EXCLUDED.updated_at ELSE updated_at END"
            )
        ]
      ]
    )
  end

  defp github_identity_conflict_target do
    if turso?() do
      # WORKAROUND(upstream): gsmlg-dev/concord#79 rejects Ecto's exact partial-index target.
      []
    else
      {:unsafe_fragment, "(github_user_id) WHERE github_user_id IS NOT NULL"}
    end
  end

  defp turso? do
    Application.get_env(:fornacast, :database_adapter) in ["libsql", "turso"]
  end

  defp fetch_github_deleted_identity do
    case Repo.get_by(GitHubIdentity, kind: :deleted) do
      %GitHubIdentity{} = identity ->
        identity

      nil ->
        %GitHubIdentity{}
        |> GitHubIdentity.deleted_changeset()
        |> Repo.insert(on_conflict: :nothing)

        Repo.get_by!(GitHubIdentity, kind: :deleted)
    end
  end

  defp claim_github_identity(identity_id, local_user_id) do
    case claim_github_identity_write(identity_id, local_user_id) do
      {1, _} -> claimed_github_identity_result(identity_id, local_user_id)
      {0, _} -> claimed_github_identity_result(identity_id, local_user_id)
    end
  end

  defp unlink_github_identity_write(identity_id, local_user_id) do
    case unlink_github_identity_update(identity_id, local_user_id) do
      {1, _} -> unlinked_github_identity_result(identity_id)
      {0, _} -> missing_github_identity_unlink_result(identity_id, local_user_id)
    end
  end

  defp claim_github_identity_write(identity_id, local_user_id) do
    GitHubIdentityWrite.with_retry(fn ->
      GitHubIdentity
      |> where(
        [identity],
        identity.id == ^identity_id and identity.kind == :user and
          (is_nil(identity.local_user_id) or identity.local_user_id == ^local_user_id)
      )
      |> Repo.update_all(
        set: [local_user_id: local_user_id, updated_at: DateTime.utc_now(:second)]
      )
    end)
  end

  defp claimed_github_identity_result(identity_id, local_user_id) do
    case reload_github_identity(identity_id) do
      %GitHubIdentity{local_user_id: ^local_user_id} = identity -> {:ok, identity}
      %GitHubIdentity{kind: :user} -> {:error, :already_linked}
      _ -> {:error, :forbidden}
    end
  end

  defp unlink_github_identity_update(identity_id, local_user_id) do
    GitHubIdentityWrite.with_retry(fn ->
      GitHubIdentity
      |> where(
        [identity],
        identity.id == ^identity_id and identity.local_user_id == ^local_user_id
      )
      |> Repo.update_all(set: [local_user_id: nil, updated_at: DateTime.utc_now(:second)])
    end)
  end

  defp unlinked_github_identity_result(identity_id) do
    case reload_github_identity(identity_id) do
      %GitHubIdentity{local_user_id: nil} = identity -> {:ok, identity}
      _ -> {:error, :not_found}
    end
  end

  defp missing_github_identity_unlink_result(identity_id, _local_user_id) do
    case reload_github_identity(identity_id) do
      %GitHubIdentity{kind: :user} -> {:error, :not_found}
      %GitHubIdentity{} -> {:error, :forbidden}
      nil -> {:error, :not_found}
    end
  end

  defp reload_github_identity(identity_id) do
    GitHubIdentityWrite.with_retry(fn ->
      maybe_inject_github_identity_read_busy()
      Repo.get(GitHubIdentity, identity_id)
    end)
  end

  if Mix.env() == :test do
    defp maybe_inject_github_identity_read_busy do
      key = {__MODULE__, :github_identity_read_hook}

      case Process.get(key) do
        :busy_once ->
          Process.put(key, :used)
          raise Turso.Error, code: :busy, message: "database is locked"

        _ ->
          :ok
      end
    end
  else
    defp maybe_inject_github_identity_read_busy, do: :ok
  end

  defp github_profile_attrs(profile) do
    %{
      github_user_id:
        github_profile_value(profile, [:github_user_id, "github_user_id", :id, "id"]),
      login: github_profile_value(profile, [:login, "login"]),
      avatar_url: github_profile_value(profile, [:avatar_url, "avatar_url"]),
      profile_url:
        github_profile_value(profile, [:profile_url, "profile_url", :html_url, "html_url"])
    }
  end

  defp github_profile_value(profile, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(profile, key), do: {:present, Map.fetch!(profile, key)}
    end)
    |> case do
      {:present, value} -> value
      nil -> nil
    end
  end

  defp validate_api_organization_update(organization, attrs) do
    name = fetch_param(attrs, :name)
    description = fetch_param(attrs, :description)

    errors =
      validate_optional_string("name", name) ++
        validate_optional_string("description", description)

    if errors == [] do
      changeset = Organization.profile_changeset(organization, attrs)

      if changeset.valid? do
        {:ok, changeset}
      else
        {:error,
         {:validation,
          changeset_errors(changeset, %{display_name: "name", description: "description"})}}
      end
    else
      {:error, {:validation, errors}}
    end
  end

  defp validate_required_string(field, :missing),
    do: [validation_error(field, :missing_field)]

  defp validate_required_string(field, {:ok, nil}),
    do: [validation_error(field, :missing_field)]

  defp validate_required_string(field, {:ok, value}) when is_binary(value) do
    if String.trim(value) == "" or contains_nul?(value),
      do: [validation_error(field, :invalid)],
      else: []
  end

  defp validate_required_string(field, {:ok, _value}),
    do: [validation_error(field, :invalid)]

  defp validate_optional_string(_field, :missing), do: []
  defp validate_optional_string(_field, {:ok, nil}), do: []

  defp validate_optional_string(field, {:ok, value}) when is_binary(value) do
    if contains_nul?(value), do: [validation_error(field, :invalid)], else: []
  end

  defp validate_optional_string(field, {:ok, _value}),
    do: [validation_error(field, :invalid)]

  defp fetch_param(attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, string_field) -> {:ok, Map.fetch!(attrs, string_field)}
      Map.has_key?(attrs, field) -> {:ok, Map.fetch!(attrs, field)}
      true -> :missing
    end
  end

  defp active_actor(%User{id: actor_id}) when is_integer(actor_id) do
    case Repo.get_by(User, id: actor_id, kind: :user, state: :active) do
      %User{} = actor -> {:ok, actor}
      nil -> {:error, :forbidden}
    end
  end

  defp active_actor(_actor), do: {:error, :forbidden}

  defp active_organization(organization_id) when is_integer(organization_id) do
    case Repo.get_by(Organization,
           id: organization_id,
           kind: :organization,
           state: :active
         ) do
      %Organization{} = organization -> {:ok, organization}
      nil -> {:error, :not_found}
    end
  end

  defp active_organization(_organization_id), do: {:error, :not_found}

  defp authorize_organization_admin(%User{role: :admin}, admin_login) do
    case Repo.get_by(User, username: admin_login, kind: :user, state: :active) do
      %User{} = owner -> {:ok, owner}
      nil -> {:error, {:validation, [validation_error("admin", :invalid)]}}
    end
  end

  defp authorize_organization_admin(%User{username: username} = actor, username),
    do: {:ok, actor}

  defp authorize_organization_admin(%User{}, _admin_login), do: {:error, :forbidden}

  defp authorize_organization_update(%User{role: :admin}, %Organization{}), do: :ok

  defp authorize_organization_update(%User{} = actor, %Organization{} = organization) do
    if organization_role(actor, organization) == :owner,
      do: :ok,
      else: {:error, :forbidden}
  end

  defp map_create_organization_result({:ok, %{organization: organization}}),
    do: {:ok, organization}

  defp map_create_organization_result({:error, :organization, %Changeset{} = changeset, _changes}) do
    {:error,
     {:validation,
      changeset_errors(changeset, %{
        username: "login",
        email: "login",
        display_name: "profile_name"
      })}}
  end

  defp map_create_organization_result({:error, :owner_membership, %Changeset{}, _changes}) do
    {:error, {:validation, [validation_error("admin", :invalid)]}}
  end

  defp map_create_organization_result({:error, :audit, %Changeset{}, _changes}) do
    {:error, {:validation, [validation_error("base", :unprocessable)]}}
  end

  defp map_create_organization_result({:error, _step, _reason, _changes}) do
    {:error, {:validation, [validation_error("base", :unprocessable)]}}
  end

  defp map_update_organization_result({:ok, %{organization: organization}}),
    do: {:ok, organization}

  defp map_update_organization_result({:error, :organization, %Changeset{} = changeset, _changes}) do
    {:error,
     {:validation,
      changeset_errors(changeset, %{display_name: "name", description: "description"})}}
  end

  defp map_update_organization_result({:error, :audit, %Changeset{}, _changes}) do
    {:error, {:validation, [validation_error("base", :unprocessable)]}}
  end

  defp map_update_organization_result({:error, _step, _reason, _changes}) do
    {:error, {:validation, [validation_error("base", :unprocessable)]}}
  end

  defp changeset_errors(%Changeset{} = changeset, field_names) do
    changeset.errors
    |> Enum.map(fn {field, {_message, metadata}} ->
      code = if Keyword.get(metadata, :constraint) == :unique, do: :already_exists, else: :invalid
      validation_error(Map.get(field_names, field, Atom.to_string(field)), code)
    end)
    |> Enum.uniq()
  end

  defp validation_error(field, code) do
    %{resource: "Organization", field: field, code: code}
  end

  defp contains_nul?(value), do: :binary.match(value, <<0>>) != :nomatch

  defp normalize_username(username) do
    username
    |> String.trim()
    |> String.downcase()
  end
end
