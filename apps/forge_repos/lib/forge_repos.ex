defmodule ForgeRepos do
  @moduledoc """
  Repository lifecycle, storage-path resolution, and repository lookup.
  """

  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

  alias Ecto.Changeset
  alias Ecto.Multi
  alias ForgeAccounts.{AccountView, Organization, OrganizationMember, User}
  alias ForgeRepos.{Collaborator, Repository, RepositoryView}
  alias Fornacast.{Audit, Page, Repo, Storage}

  @repository_permissions [:repository_read, :repository_write, :repository_admin]
  @unsupported_features ~w(
    has_projects
    has_wiki
    has_discussions
    allow_squash_merge
    allow_rebase_merge
  )a

  @type validation_error :: %{
          required(:resource) => String.t(),
          required(:field) => String.t(),
          required(:code) =>
            :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
          optional(:message) => String.t()
        }

  @type api_error ::
          :not_found
          | :forbidden
          | :git_initializer_unavailable
          | {:validation, [validation_error()]}
          | {:unavailable, atom()}

  @spec account_view(User.t() | nil, User.t() | Organization.t()) :: AccountView.t()
  def account_view(actor, %User{kind: :user} = account) do
    counts = directly_owned_repository_counts(account.id)
    private_repos = if same_active_personal_actor?(actor, account), do: counts.private, else: 0

    AccountView.new(account, counts.public, private_repos)
  end

  def account_view(_actor, %Organization{kind: :organization} = account) do
    counts = directly_owned_repository_counts(account.id)
    AccountView.new(account, counts.public, 0)
  end

  @spec fetch_authorized_repository(User.t() | nil, String.t(), String.t(), atom()) ::
          {:ok, Repository.t()} | {:error, :not_found | :forbidden}
  def fetch_authorized_repository(actor, owner_slug, repository_slug, permission)
      when is_binary(owner_slug) and is_binary(repository_slug) and
             permission in @repository_permissions do
    if contains_nul?(owner_slug) or contains_nul?(repository_slug) do
      {:error, :not_found}
    else
      repository =
        Repository
        |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
        |> where(
          [repository, owner],
          is_nil(repository.deleted_at) and owner.state == :active and
            owner.kind in [:user, :organization]
        )
        |> where([_repository, owner], owner.username == ^normalize_account_slug(owner_slug))
        |> where(
          [repository, _owner],
          repository.slug == ^Repository.normalize_slug(repository_slug)
        )
        |> select([repository, _owner], repository)
        |> Repo.one()

      authorize_fetched_repository(actor, repository, permission)
    end
  end

  def fetch_authorized_repository(_actor, _owner_slug, _repository_slug, _permission),
    do: {:error, :forbidden}

  @spec repository_view(User.t() | nil, Repository.t()) ::
          {:ok, RepositoryView.t()} | {:error, :not_found | {:unavailable, atom()}}
  def repository_view(actor, %Repository{id: repository_id}) when is_integer(repository_id) do
    actor = canonical_read_actor(actor)

    case load_repository_contexts([repository_id], actor) do
      %{^repository_id => context} -> build_repository_view(actor, context)
      %{} -> {:error, :not_found}
    end
  end

  def repository_view(_actor, %Repository{}), do: {:error, :not_found}

  @spec list_accessible_repository_views(User.t(), keyword()) ::
          {:ok, Page.t(RepositoryView.t())} | {:error, api_error()}
  def list_accessible_repository_views(actor, opts \\ [])

  def list_accessible_repository_views(%User{} = actor, opts) when is_list(opts) do
    with {:ok, actor} <- active_actor(actor),
         {:ok, params} <- validate_accessible_list_options(opts) do
      query = accessible_repository_query(actor, params)
      load_repository_view_page(actor, query, params)
    end
  end

  def list_accessible_repository_views(_actor, _opts), do: {:error, :forbidden}

  @spec list_account_repository_views(
          User.t() | nil,
          User.t() | Organization.t(),
          keyword()
        ) :: {:ok, Page.t(RepositoryView.t())} | {:error, api_error()}
  def list_account_repository_views(actor, account, opts \\ []) when is_list(opts) do
    with {:ok, actor} <- optional_active_actor(actor),
         {:ok, account} <- active_typed_account(account),
         {:ok, params} <- validate_account_list_options(account, actor, opts) do
      query = account_repository_query(actor, account, params)
      load_repository_view_page(actor, query, params)
    end
  end

  @spec create_api_repository(User.t(), User.t() | Organization.t(), map(), map()) ::
          {:ok, Repository.t()} | {:error, api_error()}
  def create_api_repository(%User{} = actor, owner, attrs, request_metadata)
      when is_map(attrs) and is_map(request_metadata) do
    with {:ok, actor} <- active_actor(actor),
         {:ok, owner_ref} <- owner_reference(owner),
         {:ok, _authorization} <- authorize_repository_create(Repo, actor, owner_ref),
         {:ok, params} <- normalize_api_create(attrs),
         :ok <- require_external_initializer(params.auto_init) do
      storage_path = generate_storage_path(owner_ref.id, params.slug)

      result =
        Multi.new()
        |> Multi.run(:authorization, fn repo, _changes ->
          authorize_repository_create(repo, actor, owner_ref)
        end)
        |> Multi.insert(:repository, fn %{authorization: %{owner: authorized_owner}} ->
          %Repository{owner_user_id: authorized_owner.id, storage_path: storage_path}
          |> Repository.api_create_changeset(Map.delete(params, :auto_init))
        end)
        |> Multi.run(:storage, fn _repo, %{repository: repository} ->
          init_repository_storage(repository)
        end)
        |> Audit.record_multi(
          :audit,
          actor,
          "repository.created",
          "repository",
          fn %{repository: repository} -> repository.id end,
          fn %{repository: repository, authorization: %{owner: authorized_owner}} ->
            %{
              "owner" => authorized_owner.username,
              "name" => repository.slug,
              "visibility" => to_string(repository.visibility),
              "result" => "success"
            }
          end,
          request_metadata: safe_request_metadata(request_metadata)
        )
        |> Repo.transaction()

      map_create_api_result(result, storage_path)
    end
  end

  def create_api_repository(_actor, _owner, _attrs, _request_metadata),
    do: {:error, :forbidden}

  @spec update_api_repository(User.t(), Repository.t(), map(), map()) ::
          {:ok, Repository.t()} | {:error, api_error()}
  def update_api_repository(
        %User{} = actor,
        %Repository{id: repository_id},
        attrs,
        request_metadata
      )
      when is_integer(repository_id) and is_map(attrs) and is_map(request_metadata) do
    required_permission = update_permission(attrs)

    with {:ok, actor} <- active_actor(actor),
         {:ok, _repository} <-
           authorize_repository_update(Repo, actor, repository_id, required_permission),
         {:ok, params} <- normalize_api_update(attrs) do
      Multi.new()
      |> Multi.run(:authorization, fn repo, _changes ->
        authorize_repository_update(repo, actor, repository_id, required_permission)
      end)
      |> Multi.run(:validation, fn _repo, %{authorization: repository} ->
        validate_repository_update(repository, params)
      end)
      |> Multi.update(:repository, fn %{validation: changeset} -> changeset end)
      |> Audit.record_multi(
        :audit,
        actor,
        "repository.updated",
        "repository",
        fn %{repository: repository} -> repository.id end,
        fn %{repository: repository} ->
          %{
            "name" => repository.slug,
            "visibility" => to_string(repository.visibility),
            "result" => "success"
          }
        end,
        request_metadata: safe_request_metadata(request_metadata)
      )
      |> Repo.transaction()
      |> map_update_api_result()
    end
  end

  def update_api_repository(_actor, _repository, _attrs, _request_metadata),
    do: {:error, :forbidden}

  def list_owner_repositories(%{id: owner_user_id}) do
    Repository
    |> where([repo], repo.owner_user_id == ^owner_user_id and is_nil(repo.deleted_at))
    |> order_by([repo], asc: repo.slug)
    |> Repo.all()
  end

  def list_accessible_repositories(%User{} = user) do
    owner_ids =
      [user | ForgeAccounts.list_user_organizations(user)]
      |> Enum.map(& &1.id)

    Repository
    |> where([repo], repo.owner_user_id in ^owner_ids and is_nil(repo.deleted_at))
    |> order_by([repo], asc: repo.slug)
    |> Repo.all()
  end

  def create_repository(owner, attrs) when is_map(attrs) do
    attrs = normalize_create_attrs(attrs)
    owner_id = owner_account_id!(owner)
    storage_path = generate_storage_path(owner_id, attrs.slug)

    changeset =
      %Repository{owner_user_id: owner_id, storage_path: storage_path}
      |> Repository.create_changeset(attrs)

    Multi.new()
    |> Multi.insert(:repository, changeset)
    |> Multi.run(:storage, fn _repo, %{repository: repository} ->
      init_repository_storage(repository)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{repository: repository}} -> {:ok, repository}
      {:error, :storage, reason, %{repository: repository}} -> cleanup_storage(repository, reason)
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def get_repository(owner_slug, repo_slug) when is_binary(owner_slug) and is_binary(repo_slug) do
    with %User{id: owner_user_id} <- ForgeAccounts.get_account_by_username(owner_slug) do
      Repository
      |> where([repo], repo.owner_user_id == ^owner_user_id)
      |> where([repo], repo.slug == ^Repository.normalize_slug(repo_slug))
      |> where([repo], is_nil(repo.deleted_at))
      |> Repo.one()
    end
  end

  def repository_owner(%Repository{owner_user_id: owner_user_id}) do
    ForgeAccounts.get_account(owner_user_id)
  end

  def resolve_git_path(path) when is_binary(path) do
    with {:ok, owner, repo} <- parse_git_path(path),
         %Repository{} = repository <- get_repository(owner, repo) do
      {:ok, repository}
    else
      _ -> {:error, :not_found}
    end
  end

  def storage_path(%Repository{storage_path: storage_path}), do: storage_path

  def absolute_storage_path(%Repository{} = repository) do
    repository.storage_path
    |> Storage.repository_path!()
  end

  defp safe_absolute_storage_path(%Repository{} = repository) do
    {:ok, absolute_storage_path(repository)}
  rescue
    File.Error -> {:error, :storage_unavailable}
    ArgumentError -> {:error, :storage_unavailable}
  end

  def empty?(%Repository{} = repository) do
    repository
    |> absolute_storage_path()
    |> GitCore.empty?()
  end

  def mark_pushed(%Repository{} = repository, pushed_at \\ DateTime.utc_now()) do
    pushed_at = DateTime.truncate(pushed_at, :second)

    repository
    |> change(last_pushed_at: pushed_at)
    |> Repo.update()
  end

  def ssh_clone_url(%Repository{} = repository, owner, actor \\ nil) do
    port = Fornacast.Config.ssh_port()
    host = Fornacast.Config.ssh_host()
    port_segment = if port == 22, do: "", else: ":#{port}"
    ssh_username = ssh_username(owner, actor)

    "ssh://#{ssh_username}@#{host}#{port_segment}/#{owner.username}/#{repository.slug}.git"
  end

  def http_clone_url(%Repository{} = repository, owner) do
    base_uri = URI.parse(Fornacast.Config.base_url())

    %URI{
      base_uri
      | path: "/#{owner.username}/#{repository.slug}.git",
        query: nil,
        fragment: nil,
        userinfo: nil
    }
    |> URI.to_string()
  end

  def parse_git_path(path) do
    path = String.trim(path)

    with false <- String.starts_with?(path, "/"),
         false <- String.contains?(path, ["..", "\\", "\0", ";", "&", "|", "`", "$", "(", ")"]),
         true <- String.ends_with?(path, ".git"),
         [owner, repo_with_suffix] <- String.split(path, "/", parts: 2),
         repo <- String.trim_trailing(repo_with_suffix, ".git"),
         true <- valid_git_path_segment?(owner),
         true <- valid_git_path_segment?(repo) do
      {:ok, owner, repo}
    else
      _ -> {:error, :invalid_path}
    end
  end

  def collaborator_role(%User{id: user_id}, %Repository{id: repository_id}) do
    ForgeRepos.Collaborator
    |> where([collaborator], collaborator.repository_id == ^repository_id)
    |> where([collaborator], collaborator.user_id == ^user_id)
    |> select([collaborator], collaborator.role)
    |> Repo.one()
  end

  defp directly_owned_repository_counts(owner_id) do
    counts =
      Repository
      |> where([repository], repository.owner_user_id == ^owner_id)
      |> where([repository], is_nil(repository.deleted_at))
      |> group_by([repository], repository.visibility)
      |> select([repository], {repository.visibility, count(repository.id)})
      |> Repo.all()
      |> Map.new()

    %{public: Map.get(counts, :public, 0), private: Map.get(counts, :private, 0)}
  end

  defp same_active_personal_actor?(
         %User{id: actor_id, kind: :user},
         %User{id: actor_id, kind: :user}
       ) do
    Repo.exists?(
      from user in User,
        where: user.id == ^actor_id and user.kind == :user and user.state == :active
    )
  end

  defp same_active_personal_actor?(_actor, _account), do: false

  defp authorize_fetched_repository(_actor, nil, _permission), do: {:error, :not_found}

  defp authorize_fetched_repository(actor, %Repository{} = repository, permission) do
    actor = canonical_read_actor(actor)

    case Fornacast.Access.authorize(actor, permission, repository) do
      :ok ->
        {:ok, repository}

      {:error, :unauthorized} ->
        case Fornacast.Access.authorize(actor, :repository_read, repository) do
          :ok -> {:error, :forbidden}
          {:error, :unauthorized} -> {:error, :not_found}
        end
    end
  end

  defp build_repository_view(actor, %{repository: repository, owner: owner} = context) do
    with :ok <- mask_repository_read(actor, context),
         {:ok, path} <- safe_absolute_storage_path(repository),
         {:ok, bytes} <- GitCore.repository_disk_usage(path) do
      {:ok,
       %RepositoryView{
         repository: repository,
         owner: owner,
         permissions: repository_permissions(actor, context),
         size_kib: div(bytes + 1023, 1024)
       }}
    else
      {:error, %GitCore.Error{kind: kind}} -> {:error, {:unavailable, kind}}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, {:unavailable, :storage_unavailable}}
    end
  end

  defp mask_repository_read(actor, context) do
    if context_authorized?(actor, :repository_read, context),
      do: :ok,
      else: {:error, :not_found}
  end

  defp repository_permissions(actor, context) do
    %{
      admin: context_authorized?(actor, :repository_admin, context),
      push: context_authorized?(actor, :repository_write, context),
      pull: context_authorized?(actor, :repository_read, context)
    }
  end

  defp context_authorized?(
         %User{role: :admin, state: :active},
         _permission,
         _context
       ),
       do: true

  defp context_authorized?(
         %User{id: actor_id, kind: :user, state: :active},
         _permission,
         %{
           repository: %Repository{owner_user_id: actor_id},
           owner: %User{kind: :user}
         }
       ),
       do: true

  defp context_authorized?(
         _actor,
         :repository_read,
         %{repository: %Repository{visibility: :public}}
       ),
       do: true

  defp context_authorized?(%User{state: :active}, permission, context) do
    organization_role_allows?(context.owner, context.organization_role, permission) or
      collaborator_role_allows?(context.collaborator_role, permission)
  end

  defp context_authorized?(_actor, _permission, _context), do: false

  defp organization_role_allows?(%Organization{}, :owner, _permission), do: true

  defp organization_role_allows?(%Organization{}, :member, :repository_read), do: true
  defp organization_role_allows?(_owner, _role, _permission), do: false

  defp collaborator_role_allows?(:admin, _permission), do: true

  defp collaborator_role_allows?(:write, permission),
    do: permission in [:repository_read, :repository_write]

  defp collaborator_role_allows?(:read, :repository_read), do: true
  defp collaborator_role_allows?(_role, _permission), do: false

  defp canonical_read_actor(%User{id: actor_id, kind: :user}) when is_integer(actor_id) do
    Repo.get_by(User, id: actor_id, kind: :user, state: :active)
  end

  defp canonical_read_actor(_actor), do: nil

  defp active_actor(%User{id: actor_id, kind: :user}) when is_integer(actor_id) do
    case Repo.get_by(User, id: actor_id, kind: :user, state: :active) do
      %User{} = actor -> {:ok, actor}
      nil -> {:error, :forbidden}
    end
  end

  defp active_actor(_actor), do: {:error, :forbidden}

  defp optional_active_actor(nil), do: {:ok, nil}
  defp optional_active_actor(%User{} = actor), do: active_actor(actor)
  defp optional_active_actor(_actor), do: {:error, :forbidden}

  defp active_typed_account(%User{id: account_id, kind: :user}) when is_integer(account_id) do
    case Repo.get_by(User, id: account_id, kind: :user, state: :active) do
      %User{} = account -> {:ok, account}
      nil -> {:error, :not_found}
    end
  end

  defp active_typed_account(%Organization{id: account_id, kind: :organization})
       when is_integer(account_id) do
    case Repo.get_by(Organization,
           id: account_id,
           kind: :organization,
           state: :active
         ) do
      %Organization{} = account -> {:ok, account}
      nil -> {:error, :not_found}
    end
  end

  defp active_typed_account(_account), do: {:error, :not_found}

  defp normalize_account_slug(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp validate_accessible_list_options(opts) do
    with {:ok, page} <- pagination_option(opts, :page, 1, 1, :infinity),
         {:ok, per_page} <- pagination_option(opts, :per_page, 30, 1, 100),
         {:ok, visibility_ceiling} <-
           enum_option(opts, :visibility_ceiling, :all, [:public, :all]),
         {:ok, visibility} <- enum_option(opts, :visibility, :all, [:all, :public, :private]),
         {:ok, affiliations} <- affiliation_option(opts),
         {:ok, type} <-
           enum_option(opts, :type, :all, [:all, :owner, :public, :private, :member]),
         :ok <- validate_type_filter_conflicts(opts),
         {:ok, sort} <-
           enum_option(opts, :sort, :full_name, [:created, :updated, :pushed, :full_name]),
         {:ok, direction} <- direction_option(opts, sort),
         {:ok, since} <- datetime_option(opts, :since),
         {:ok, before} <- datetime_option(opts, :before) do
      {:ok,
       %{
         page: page,
         per_page: per_page,
         visibility_ceiling: visibility_ceiling,
         visibility: visibility,
         affiliations: affiliations,
         type: type,
         sort: sort,
         direction: direction,
         since: since,
         before: before
       }}
    end
  end

  defp validate_account_list_options(account, actor, opts) do
    default_sort = if match?(%Organization{}, account), do: :created, else: :full_name

    with {:ok, page} <- pagination_option(opts, :page, 1, 1, :infinity),
         {:ok, per_page} <- pagination_option(opts, :per_page, 30, 1, 100),
         {:ok, requested_ceiling} <-
           enum_option(opts, :visibility_ceiling, :all, [:public, :all]),
         {:ok, type} <- account_type_option(account, opts),
         {:ok, sort} <-
           enum_option(opts, :sort, default_sort, [:created, :updated, :pushed, :full_name]),
         {:ok, direction} <- direction_option(opts, sort) do
      visibility_ceiling = if is_nil(actor), do: :public, else: requested_ceiling

      {:ok,
       %{
         page: page,
         per_page: per_page,
         visibility_ceiling: visibility_ceiling,
         type: type,
         sort: sort,
         direction: direction
       }}
    end
  end

  defp account_type_option(%User{}, opts) do
    enum_option(opts, :type, :owner, [:all, :owner, :member])
  end

  defp account_type_option(%Organization{}, opts) do
    enum_option(
      opts,
      :type,
      :all,
      [:all, :public, :private, :forks, :sources, :member, :internal]
    )
  end

  defp pagination_option(opts, field, default, minimum, maximum) do
    value = Keyword.get(opts, field, default)

    if is_integer(value) and value >= minimum and
         (maximum == :infinity or value <= maximum) do
      {:ok, value}
    else
      validation_result(Atom.to_string(field), :invalid)
    end
  end

  defp enum_option(opts, field, default, allowed) do
    value = opts |> Keyword.get(field, default) |> enum_value()

    if value in allowed,
      do: {:ok, value},
      else: validation_result(Atom.to_string(field), :invalid)
  end

  defp enum_value(value) when is_atom(value), do: value

  defp enum_value(value) when is_binary(value) do
    case value do
      "all" -> :all
      "public" -> :public
      "private" -> :private
      "owner" -> :owner
      "member" -> :member
      "created" -> :created
      "updated" -> :updated
      "pushed" -> :pushed
      "full_name" -> :full_name
      "asc" -> :asc
      "desc" -> :desc
      "forks" -> :forks
      "sources" -> :sources
      "internal" -> :internal
      _value -> :invalid
    end
  end

  defp enum_value(_value), do: :invalid

  defp affiliation_option(opts) do
    case Keyword.fetch(opts, :affiliation) do
      :error ->
        {:ok, [:owner, :collaborator, :organization_member]}

      {:ok, value} when is_binary(value) ->
        affiliations = String.split(value, ",", trim: false)
        normalized = Enum.map(affiliations, &affiliation_value/1)

        cond do
          length(affiliations) > 100 ->
            validation_result("affiliation", :unprocessable)

          affiliations != [] and Enum.all?(normalized, &(&1 != :invalid)) and
              Enum.uniq(normalized) == normalized ->
            {:ok, normalized}

          true ->
            validation_result("affiliation", :invalid)
        end

      {:ok, _value} ->
        validation_result("affiliation", :invalid)
    end
  end

  defp affiliation_value("owner"), do: :owner
  defp affiliation_value("collaborator"), do: :collaborator
  defp affiliation_value("organization_member"), do: :organization_member
  defp affiliation_value(_value), do: :invalid

  defp validate_type_filter_conflicts(opts) do
    if Keyword.has_key?(opts, :type) and
         (Keyword.has_key?(opts, :visibility) or Keyword.has_key?(opts, :affiliation)) do
      {:error, {:validation, [validation_error("type", :invalid)]}}
    else
      :ok
    end
  end

  defp direction_option(opts, sort) do
    default = if sort == :full_name, do: :asc, else: :desc
    enum_option(opts, :direction, default, [:asc, :desc])
  end

  defp datetime_option(opts, field) do
    case Keyword.fetch(opts, field) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, normalize_datetime_bound(datetime, field)}
          _result -> validation_result(Atom.to_string(field), :invalid)
        end

      {:ok, _value} ->
        validation_result(Atom.to_string(field), :invalid)
    end
  end

  defp normalize_datetime_bound(%DateTime{microsecond: {0, _precision}} = datetime, _field),
    do: DateTime.truncate(datetime, :second)

  defp normalize_datetime_bound(datetime, :before) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.add(1, :second)
  end

  defp normalize_datetime_bound(datetime, :since), do: DateTime.truncate(datetime, :second)

  defp accessible_repository_query(actor, params) do
    ids = accessible_repository_ids(actor, params.affiliations)

    Repository
    |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
    |> where([repository, _owner], repository.id in subquery(ids))
    |> apply_visibility_ceiling(params.visibility_ceiling)
    |> apply_accessible_visibility_filter(params.visibility)
    |> apply_accessible_type_filter(actor, params.type)
    |> apply_updated_bound(:since, params.since)
    |> apply_updated_bound(:before, params.before)
  end

  defp accessible_repository_ids(%User{id: actor_id}, affiliations) do
    relationship = affiliation_dynamic(affiliations, actor_id)

    Repository
    |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
    |> join(:left, [repository, _owner], membership in OrganizationMember,
      on:
        membership.organization_id == repository.owner_user_id and membership.user_id == ^actor_id
    )
    |> join(:left, [repository, _owner, _membership], collaborator in Collaborator,
      on: collaborator.repository_id == repository.id and collaborator.user_id == ^actor_id
    )
    |> where(
      [repository, owner, _membership, _collaborator],
      is_nil(repository.deleted_at) and owner.state == :active
    )
    |> where(^relationship)
    |> select([repository, _owner, _membership, _collaborator], repository.id)
    |> distinct(true)
  end

  defp affiliation_dynamic(affiliations, actor_id) do
    Enum.reduce(affiliations, dynamic(false), fn
      :owner, dynamic_query ->
        dynamic(
          [repository, owner, _membership, _collaborator],
          ^dynamic_query or
            (repository.owner_user_id == ^actor_id and owner.kind == :user)
        )

      :organization_member, dynamic_query ->
        dynamic(
          [_repository, owner, membership, _collaborator],
          ^dynamic_query or (owner.kind == :organization and not is_nil(membership.id))
        )

      :collaborator, dynamic_query ->
        dynamic(
          [_repository, _owner, _membership, collaborator],
          ^dynamic_query or not is_nil(collaborator.id)
        )
    end)
  end

  defp apply_visibility_ceiling(query, :all), do: query

  defp apply_visibility_ceiling(query, :public),
    do: where(query, [repository], repository.visibility == :public)

  defp apply_accessible_visibility_filter(query, :all), do: query

  defp apply_accessible_visibility_filter(query, visibility)
       when visibility in [:public, :private] do
    where(query, [repository], repository.visibility == ^visibility)
  end

  defp apply_accessible_type_filter(query, _actor, :all), do: query

  defp apply_accessible_type_filter(query, %User{id: actor_id}, :owner) do
    where(
      query,
      [repository, owner],
      repository.owner_user_id == ^actor_id and owner.kind == :user
    )
  end

  defp apply_accessible_type_filter(query, _actor, visibility)
       when visibility in [:public, :private] do
    where(query, [repository], repository.visibility == ^visibility)
  end

  defp apply_accessible_type_filter(query, %User{id: actor_id}, :member) do
    member_ids =
      Repository
      |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
      |> join(:inner, [repository, _owner], membership in OrganizationMember,
        on:
          membership.organization_id == repository.owner_user_id and
            membership.user_id == ^actor_id
      )
      |> where(
        [_repository, owner, _membership],
        owner.kind == :organization and owner.state == :active
      )
      |> select([repository, _owner, _membership], repository.id)

    where(query, [repository], repository.id in subquery(member_ids))
  end

  defp apply_updated_bound(query, _field, nil), do: query

  defp apply_updated_bound(query, :since, datetime) do
    where(query, [repository], repository.updated_at > ^datetime)
  end

  defp apply_updated_bound(query, :before, datetime) do
    where(query, [repository], repository.updated_at < ^datetime)
  end

  defp account_repository_query(actor, account, params) do
    candidate_ids = account_repository_ids(account, params.type)
    visible_ids = visible_repository_ids(candidate_ids, actor, params.visibility_ceiling)

    Repository
    |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
    |> where([repository, _owner], repository.id in subquery(visible_ids))
  end

  defp account_repository_ids(%User{id: account_id}, type) do
    Repository
    |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
    |> join(:left, [repository, _owner], membership in OrganizationMember,
      on:
        membership.organization_id == repository.owner_user_id and
          membership.user_id == ^account_id
    )
    |> where(
      [repository, owner, _membership],
      is_nil(repository.deleted_at) and owner.state == :active
    )
    |> where(^user_account_type_dynamic(type, account_id))
    |> select([repository, _owner, _membership], repository.id)
    |> distinct(true)
  end

  defp account_repository_ids(%Organization{id: organization_id}, type) do
    Repository
    |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
    |> where(
      [repository, owner],
      repository.owner_user_id == ^organization_id and is_nil(repository.deleted_at) and
        owner.kind == :organization and owner.state == :active
    )
    |> apply_organization_account_type(type)
    |> select([repository, _owner], repository.id)
  end

  defp user_account_type_dynamic(:owner, account_id) do
    dynamic(
      [repository, owner, _membership],
      repository.owner_user_id == ^account_id and owner.kind == :user
    )
  end

  defp user_account_type_dynamic(:member, _account_id) do
    dynamic(
      [_repository, owner, membership],
      owner.kind == :organization and not is_nil(membership.id)
    )
  end

  defp user_account_type_dynamic(:all, account_id) do
    dynamic(
      [repository, owner, membership],
      (repository.owner_user_id == ^account_id and owner.kind == :user) or
        (owner.kind == :organization and not is_nil(membership.id))
    )
  end

  defp apply_organization_account_type(query, :all), do: query
  defp apply_organization_account_type(query, :sources), do: query

  defp apply_organization_account_type(query, type)
       when type in [:forks, :internal, :member] do
    where(query, [_repository], false)
  end

  defp apply_organization_account_type(query, visibility)
       when visibility in [:public, :private] do
    where(query, [repository], repository.visibility == ^visibility)
  end

  defp visible_repository_ids(candidate_ids, _actor, :public) do
    Repository
    |> where([repository], repository.id in subquery(candidate_ids))
    |> where([repository], repository.visibility == :public)
    |> select([repository], repository.id)
  end

  defp visible_repository_ids(candidate_ids, nil, :all) do
    visible_repository_ids(candidate_ids, nil, :public)
  end

  defp visible_repository_ids(candidate_ids, %User{role: :admin}, :all) do
    Repository
    |> where([repository], repository.id in subquery(candidate_ids))
    |> select([repository], repository.id)
  end

  defp visible_repository_ids(candidate_ids, %User{id: actor_id}, :all) do
    Repository
    |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
    |> join(:left, [repository, _owner], membership in OrganizationMember,
      on:
        membership.organization_id == repository.owner_user_id and membership.user_id == ^actor_id
    )
    |> join(:left, [repository, _owner, _membership], collaborator in Collaborator,
      on: collaborator.repository_id == repository.id and collaborator.user_id == ^actor_id
    )
    |> where(
      [repository, _owner, _membership, _collaborator],
      repository.id in subquery(candidate_ids)
    )
    |> where(
      [repository, owner, membership, collaborator],
      repository.visibility == :public or
        (repository.owner_user_id == ^actor_id and owner.kind == :user) or
        (owner.kind == :organization and not is_nil(membership.id)) or
        not is_nil(collaborator.id)
    )
    |> select([repository, _owner, _membership, _collaborator], repository.id)
    |> distinct(true)
  end

  defp load_repository_view_page(actor, query, params) do
    total = Repo.aggregate(query, :count, :id)

    repositories =
      query
      |> order_repository_query(params.sort, params.direction)
      |> offset(^((params.page - 1) * params.per_page))
      |> limit(^params.per_page)
      |> select([repository, _owner], repository)
      |> Repo.all()

    case build_repository_views(actor, repositories) do
      {:ok, entries} ->
        {:ok,
         %Page{
           entries: entries,
           total: total,
           page: params.page,
           per_page: params.per_page
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_repository_views(actor, repositories) do
    contexts =
      repositories
      |> Enum.map(& &1.id)
      |> load_repository_contexts(actor)

    Enum.reduce_while(repositories, {:ok, []}, fn repository, {:ok, views} ->
      case Map.fetch(contexts, repository.id) do
        {:ok, context} ->
          case build_repository_view(actor, context) do
            {:ok, view} -> {:cont, {:ok, [view | views]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, views} -> {:ok, Enum.reverse(views)}
      error -> error
    end
  end

  defp load_repository_contexts([], _actor), do: %{}

  defp load_repository_contexts(repository_ids, actor) do
    actor
    |> repository_context_rows(repository_ids)
    |> Enum.reduce(%{}, fn
      {repository, %User{kind: :user} = owner, nil, organization_role, collaborator_role},
      contexts ->
        put_repository_context(
          contexts,
          repository,
          owner,
          organization_role,
          collaborator_role
        )

      {repository, %User{kind: :organization}, %Organization{kind: :organization} = owner,
       organization_role, collaborator_role},
      contexts ->
        put_repository_context(
          contexts,
          repository,
          owner,
          organization_role,
          collaborator_role
        )

      _row, contexts ->
        contexts
    end)
  end

  defp repository_context_rows(nil, repository_ids) do
    repository_ids
    |> repository_context_query()
    |> select([repository, owner, organization], {repository, owner, organization})
    |> Repo.all()
    |> Enum.map(fn {repository, owner, organization} ->
      {repository, owner, organization, nil, nil}
    end)
  end

  defp repository_context_rows(%User{id: actor_id}, repository_ids) do
    repository_ids
    |> repository_context_query()
    |> join(:left, [repository, _owner, _organization], membership in OrganizationMember,
      on:
        membership.organization_id == repository.owner_user_id and
          membership.user_id == ^actor_id
    )
    |> join(
      :left,
      [repository, _owner, _organization, _membership],
      collaborator in Collaborator,
      on: collaborator.repository_id == repository.id and collaborator.user_id == ^actor_id
    )
    |> select(
      [repository, owner, organization, membership, collaborator],
      {repository, owner, organization, membership.role, collaborator.role}
    )
    |> Repo.all()
  end

  defp repository_context_query(repository_ids) do
    Repository
    |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
    |> join(:left, [_repository, owner], organization in Organization,
      on:
        organization.id == owner.id and owner.kind == :organization and
          organization.kind == :organization and organization.state == :active
    )
    |> where(
      [repository, owner, _organization],
      repository.id in ^repository_ids and is_nil(repository.deleted_at) and
        owner.state == :active and owner.kind in [:user, :organization]
    )
  end

  defp put_repository_context(
         contexts,
         repository,
         owner,
         organization_role,
         collaborator_role
       ) do
    Map.put(contexts, repository.id, %{
      repository: repository,
      owner: owner,
      organization_role: organization_role,
      collaborator_role: collaborator_role
    })
  end

  defp order_repository_query(query, :full_name, :asc) do
    order_by(query, [repository, owner],
      asc: owner.username,
      asc: repository.slug,
      asc: repository.id
    )
  end

  defp order_repository_query(query, :full_name, :desc) do
    order_by(query, [repository, owner],
      desc: owner.username,
      desc: repository.slug,
      desc: repository.id
    )
  end

  defp order_repository_query(query, sort, direction) when sort in [:created, :updated] do
    field = if sort == :created, do: :inserted_at, else: :updated_at

    case direction do
      :asc -> order_by(query, [repository], asc: field(repository, ^field), asc: repository.id)
      :desc -> order_by(query, [repository], desc: field(repository, ^field), desc: repository.id)
    end
  end

  defp order_repository_query(query, :pushed, direction) do
    query = order_by(query, [repository], asc: is_nil(repository.last_pushed_at))

    case direction do
      :asc -> order_by(query, [repository], asc: repository.last_pushed_at, asc: repository.id)
      :desc -> order_by(query, [repository], desc: repository.last_pushed_at, desc: repository.id)
    end
  end

  defp owner_reference(%User{id: id, kind: :user}) when is_integer(id),
    do: {:ok, %{id: id, kind: :user}}

  defp owner_reference(%Organization{id: id, kind: :organization}) when is_integer(id),
    do: {:ok, %{id: id, kind: :organization}}

  defp owner_reference(%Organization{}), do: {:error, :not_found}
  defp owner_reference(%User{}), do: {:error, :not_found}
  defp owner_reference(_owner), do: {:error, :not_found}

  defp authorize_repository_create(repo, actor, %{kind: :user, id: owner_id}) do
    with {:ok, active_actor} <- reload_actor(repo, actor.id),
         %User{} = owner <- repo.get_by(User, id: owner_id, kind: :user, state: :active),
         true <- owner.id == active_actor.id do
      {:ok, %{actor: active_actor, owner: owner}}
    else
      nil -> {:error, :not_found}
      false -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_repository_create(repo, actor, %{kind: :organization, id: owner_id}) do
    with {:ok, active_actor} <- reload_actor(repo, actor.id),
         %Organization{} = owner <-
           repo.get_by(Organization,
             id: owner_id,
             kind: :organization,
             state: :active
           ) do
      case organization_role_with_repo(repo, active_actor.id, owner.id) do
        _role when active_actor.role == :admin ->
          {:ok, %{actor: active_actor, owner: owner}}

        :owner ->
          {:ok, %{actor: active_actor, owner: owner}}

        _role ->
          {:error, :forbidden}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reload_actor(repo, actor_id) do
    case repo.get_by(User, id: actor_id, kind: :user, state: :active) do
      %User{} = actor -> {:ok, actor}
      nil -> {:error, :forbidden}
    end
  end

  defp organization_role_with_repo(repo, actor_id, organization_id) do
    OrganizationMember
    |> where(
      [membership],
      membership.user_id == ^actor_id and membership.organization_id == ^organization_id
    )
    |> select([membership], membership.role)
    |> repo.one()
  end

  defp authorize_repository_update(repo, actor, repository_id, permission) do
    with {:ok, active_actor} <- reload_actor(repo, actor.id),
         %Repository{} = repository <- active_repository_for_update(repo, repository_id),
         :ok <- map_update_authorization(active_actor, permission, repository) do
      {:ok, repository}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_repository_for_update(repo, repository_id) do
    Repository
    |> join(:inner, [repository], owner in User, on: owner.id == repository.owner_user_id)
    |> where(
      [repository, owner],
      repository.id == ^repository_id and is_nil(repository.deleted_at) and
        owner.state == :active and owner.kind in [:user, :organization]
    )
    |> select([repository, _owner], repository)
    |> repo.one()
  end

  defp map_update_authorization(actor, permission, repository) do
    case Fornacast.Access.authorize(actor, permission, repository) do
      :ok ->
        :ok

      {:error, :unauthorized} ->
        case Fornacast.Access.authorize(actor, :repository_read, repository) do
          :ok -> {:error, :forbidden}
          {:error, :unauthorized} -> {:error, :not_found}
        end
    end
  end

  defp update_permission(attrs) do
    administrative_fields = [:name, :description, :private, :visibility, :default_branch]

    if Enum.any?(administrative_fields, &has_attr?(attrs, &1)),
      do: :repository_admin,
      else: :repository_write
  end

  defp normalize_api_create(attrs) do
    with {:ok, name} <- required_string_attr(attrs, :name),
         {:ok, description} <- optional_string_attr(attrs, :description),
         {:ok, visibility} <- visibility_attr(attrs, :public),
         {:ok, default_branch} <- default_branch_attr(attrs, "main"),
         {:ok, has_issues} <- boolean_attr(attrs, :has_issues, true),
         {:ok, allow_merge_commit} <- boolean_attr(attrs, :allow_merge_commit, true),
         {:ok, auto_init} <- boolean_attr(attrs, :auto_init, false),
         :ok <- validate_unsupported_features(attrs) do
      {:ok,
       %{
         slug: Repository.normalize_slug(name),
         name: String.trim(name),
         description: if(description == :missing, do: nil, else: description),
         visibility: visibility,
         default_branch: default_branch,
         has_issues: has_issues,
         allow_merge_commit: allow_merge_commit,
         auto_init: auto_init
       }}
    end
  end

  defp normalize_api_update(attrs) do
    with {:ok, name} <- optional_string_attr(attrs, :name),
         {:ok, description} <- optional_string_attr(attrs, :description),
         {:ok, visibility} <- visibility_attr(attrs, :missing),
         {:ok, default_branch} <- default_branch_attr(attrs, :missing),
         {:ok, has_issues} <- boolean_attr(attrs, :has_issues, :missing),
         {:ok, allow_merge_commit} <- boolean_attr(attrs, :allow_merge_commit, :missing),
         :ok <- validate_unsupported_features(attrs),
         :ok <- reject_update_auto_init(attrs) do
      params = %{}
      params = put_supplied(params, :description, description)
      params = put_supplied(params, :visibility, visibility)
      params = put_supplied(params, :default_branch, default_branch)
      params = put_supplied(params, :has_issues, has_issues)
      params = put_supplied(params, :allow_merge_commit, allow_merge_commit)

      params =
        case name do
          :missing ->
            params

          value ->
            params
            |> Map.put(:name, String.trim(value))
            |> Map.put(:slug, Repository.normalize_slug(value))
        end

      {:ok, params}
    end
  end

  defp required_string_attr(attrs, field) do
    case fetch_attr(attrs, field) do
      :missing -> validation_result(Atom.to_string(field), :missing_field)
      {:ok, value} -> validate_required_string(field, value)
    end
  end

  defp validate_required_string(field, value) when is_binary(value) do
    if String.trim(value) == "" or contains_nul?(value),
      do: validation_result(Atom.to_string(field), :invalid),
      else: {:ok, value}
  end

  defp validate_required_string(field, _value),
    do: validation_result(Atom.to_string(field), :invalid)

  defp optional_string_attr(attrs, field) do
    case fetch_attr(attrs, field) do
      :missing -> {:ok, :missing}
      {:ok, nil} when field == :description -> {:ok, nil}
      {:ok, value} when is_binary(value) -> validate_optional_string(field, value)
      {:ok, _value} -> validation_result(Atom.to_string(field), :invalid)
    end
  end

  defp validate_optional_string(field, value) do
    cond do
      contains_nul?(value) -> validation_result(Atom.to_string(field), :invalid)
      field == :name and String.trim(value) == "" -> validation_result("name", :invalid)
      true -> {:ok, if(field == :description, do: value, else: String.trim(value))}
    end
  end

  defp default_branch_attr(attrs, default) do
    case fetch_attr(attrs, :default_branch) do
      :missing ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        if value == "" or contains_nul?(value),
          do: validation_result("default_branch", :invalid),
          else: {:ok, value}

      {:ok, _value} ->
        validation_result("default_branch", :invalid)
    end
  end

  defp visibility_attr(attrs, default) do
    private = fetch_attr(attrs, :private)
    visibility = fetch_attr(attrs, :visibility)

    with {:ok, private_visibility} <- private_visibility(private),
         {:ok, explicit_visibility} <- explicit_visibility(visibility),
         :ok <- validate_visibility_match(private_visibility, explicit_visibility) do
      {:ok, explicit_visibility || private_visibility || default}
    end
  end

  defp private_visibility(:missing), do: {:ok, nil}
  defp private_visibility({:ok, true}), do: {:ok, :private}
  defp private_visibility({:ok, false}), do: {:ok, :public}
  defp private_visibility({:ok, _value}), do: validation_result("private", :invalid)

  defp explicit_visibility(:missing), do: {:ok, nil}
  defp explicit_visibility({:ok, value}) when value in [:public, :private], do: {:ok, value}
  defp explicit_visibility({:ok, "public"}), do: {:ok, :public}
  defp explicit_visibility({:ok, "private"}), do: {:ok, :private}

  defp explicit_visibility({:ok, value}) when value in [:internal, "internal"],
    do: validation_result("visibility", :unprocessable)

  defp explicit_visibility({:ok, value}) when is_binary(value) do
    if contains_nul?(value),
      do: validation_result("visibility", :invalid),
      else: validation_result("visibility", :invalid)
  end

  defp explicit_visibility({:ok, _value}), do: validation_result("visibility", :invalid)

  defp validate_visibility_match(nil, _visibility), do: :ok
  defp validate_visibility_match(_private, nil), do: :ok
  defp validate_visibility_match(visibility, visibility), do: :ok

  defp validate_visibility_match(_private, _visibility),
    do: {:error, {:validation, [validation_error("visibility", :invalid)]}}

  defp boolean_attr(attrs, field, default) do
    case fetch_attr(attrs, field) do
      :missing -> {:ok, default}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> validation_result(Atom.to_string(field), :invalid)
    end
  end

  defp validate_unsupported_features(attrs) do
    errors =
      Enum.flat_map(@unsupported_features, fn field ->
        case fetch_attr(attrs, field) do
          :missing -> []
          {:ok, false} -> []
          {:ok, true} -> [validation_error(Atom.to_string(field), :unprocessable)]
          {:ok, _value} -> [validation_error(Atom.to_string(field), :invalid)]
        end
      end)

    if errors == [], do: :ok, else: {:error, {:validation, errors}}
  end

  defp reject_update_auto_init(attrs) do
    case fetch_attr(attrs, :auto_init) do
      :missing -> :ok
      {:ok, _value} -> {:error, {:validation, [validation_error("auto_init", :unprocessable)]}}
    end
  end

  defp put_supplied(map, _field, :missing), do: map
  defp put_supplied(map, field, value), do: Map.put(map, field, value)

  defp fetch_attr(attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, string_field) -> {:ok, Map.fetch!(attrs, string_field)}
      Map.has_key?(attrs, field) -> {:ok, Map.fetch!(attrs, field)}
      true -> :missing
    end
  end

  defp has_attr?(attrs, field), do: fetch_attr(attrs, field) != :missing

  defp require_external_initializer(true), do: {:error, :git_initializer_unavailable}
  defp require_external_initializer(false), do: :ok

  defp validate_repository_update(repository, params) do
    changeset = Repository.api_update_changeset(repository, params)

    cond do
      not changeset.valid? ->
        {:error, {:validation, repository_changeset_errors(changeset)}}

      branch = Changeset.get_change(changeset, :default_branch) ->
        validate_changed_default_branch(repository, branch, changeset)

      true ->
        {:ok, changeset}
    end
  end

  defp validate_changed_default_branch(repository, branch, changeset) do
    selector = %GitCore.RefSelector{kind: :branch, full_name: "refs/heads/#{branch}"}

    with {:ok, path} <- safe_absolute_storage_path(repository) do
      case GitCore.resolve_snapshot(path, selector) do
        {:ok, %GitCore.Snapshot{}} ->
          {:ok, changeset}

        {:error, %GitCore.Error{kind: kind}} when kind in [:empty_repository, :ref_not_found] ->
          validation_result("default_branch", :missing)

        {:error, %GitCore.Error{kind: kind}} ->
          {:error, {:unavailable, kind}}

        {:error, _reason} ->
          {:error, {:unavailable, :storage_unavailable}}
      end
    else
      {:error, :storage_unavailable} ->
        {:error, {:unavailable, :storage_unavailable}}
    end
  end

  defp map_create_api_result({:ok, %{repository: repository}}, _storage_path),
    do: {:ok, repository}

  defp map_create_api_result(
         {:error, :authorization, reason, _changes},
         _storage_path
       ) do
    {:error, reason}
  end

  defp map_create_api_result(
         {:error, :repository, %Changeset{} = changeset, _changes},
         _storage_path
       ) do
    {:error, {:validation, repository_changeset_errors(changeset)}}
  end

  defp map_create_api_result({:error, :storage, reason, _changes}, storage_path) do
    cleanup_generated_storage(storage_path)
    {:error, {:unavailable, dependency_error_kind(reason)}}
  end

  defp map_create_api_result(
         {:error, :audit, %Changeset{}, _changes},
         storage_path
       ) do
    cleanup_generated_storage(storage_path)
    validation_result("base", :unprocessable)
  end

  defp map_create_api_result({:error, _step, _reason, _changes}, storage_path) do
    cleanup_generated_storage(storage_path)
    validation_result("base", :unprocessable)
  end

  defp map_update_api_result({:ok, %{repository: repository}}), do: {:ok, repository}

  defp map_update_api_result({:error, :authorization, reason, _changes}),
    do: {:error, reason}

  defp map_update_api_result({:error, :validation, reason, _changes}),
    do: {:error, reason}

  defp map_update_api_result({:error, :repository, %Changeset{} = changeset, _changes}) do
    {:error, {:validation, repository_changeset_errors(changeset)}}
  end

  defp map_update_api_result({:error, :audit, %Changeset{}, _changes}),
    do: validation_result("base", :unprocessable)

  defp map_update_api_result({:error, _step, _reason, _changes}),
    do: validation_result("base", :unprocessable)

  defp repository_changeset_errors(%Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {_message, metadata}} ->
      code = if Keyword.get(metadata, :constraint) == :unique, do: :already_exists, else: :invalid
      validation_error(repository_error_field(field), code)
    end)
    |> Enum.uniq()
  end

  defp repository_error_field(:slug), do: "name"
  defp repository_error_field(:owner_user_id), do: "name"
  defp repository_error_field(field), do: Atom.to_string(field)

  defp validation_result(field, code) do
    {:error, {:validation, [validation_error(field, code)]}}
  end

  defp validation_error(field, code) do
    %{resource: "Repository", field: field, code: code}
  end

  defp dependency_error_kind(%GitCore.Error{kind: kind}), do: kind

  defp dependency_error_kind({kind, _detail}) when is_atom(kind),
    do: safe_dependency_kind(kind)

  defp dependency_error_kind({kind, _detail}) when is_binary(kind), do: safe_dependency_atom(kind)
  defp dependency_error_kind(kind) when is_atom(kind), do: safe_dependency_kind(kind)
  defp dependency_error_kind(_reason), do: :storage_unavailable

  defp safe_dependency_kind(kind)
       when kind in [:storage_unavailable, :invalid_repository, :scan_timeout, :scan_busy],
       do: kind

  defp safe_dependency_kind(_kind), do: :storage_unavailable

  defp safe_dependency_atom("storage_unavailable"), do: :storage_unavailable
  defp safe_dependency_atom("invalid_repository"), do: :invalid_repository
  defp safe_dependency_atom("scan_timeout"), do: :scan_timeout
  defp safe_dependency_atom(_kind), do: :storage_unavailable

  defp cleanup_generated_storage(storage_path) do
    storage_path
    |> Storage.repository_path!()
    |> File.rm_rf()

    :ok
  rescue
    File.Error -> :ok
  end

  defp safe_request_metadata(metadata) do
    [:request_id, :api_version, :ip_address, :user_agent, :token_id]
    |> Enum.reduce(%{}, fn field, safe ->
      case fetch_attr(metadata, field) do
        :missing -> safe
        {:ok, value} -> Map.put(safe, field, value)
      end
    end)
  end

  defp contains_nul?(value) when is_binary(value),
    do: :binary.match(value, <<0>>) != :nomatch

  defp normalize_create_attrs(attrs) do
    slug =
      attrs
      |> get_attr(:slug)
      |> case do
        nil -> get_attr(attrs, :name)
        value -> value
      end
      |> Repository.normalize_slug()

    %{
      name: get_attr(attrs, :name) || slug,
      slug: slug,
      description: get_attr(attrs, :description),
      visibility: get_attr(attrs, :visibility) || :private,
      default_branch: get_attr(attrs, :default_branch) || "main"
    }
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp owner_account_id!(%User{kind: kind, id: id}) when kind in [:user, :organization], do: id
  defp owner_account_id!(%Organization{id: id}), do: id

  defp ssh_username(_owner, %User{kind: :user} = actor), do: actor.username
  defp ssh_username(%User{} = owner, _actor), do: owner.username
  defp ssh_username(%Organization{} = owner, _actor), do: owner.username

  defp generate_storage_path(owner_user_id, slug) do
    nonce = :crypto.strong_rand_bytes(24)

    digest =
      :sha256
      |> :crypto.hash("#{owner_user_id}:#{slug}:#{Base.url_encode64(nonce, padding: false)}")
      |> Base.encode16(case: :lower)

    Path.join([
      "@hashed",
      String.slice(digest, 0, 2),
      String.slice(digest, 2, 2),
      digest <> ".git"
    ])
  end

  defp init_repository_storage(%Repository{} = repository) do
    path = absolute_storage_path(repository)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, _path} <- GitCore.init_bare(path) do
      {:ok, path}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    File.Error -> {:error, :storage_unavailable}
  end

  defp cleanup_storage(repository, reason) do
    repository
    |> absolute_storage_path()
    |> File.rm_rf()

    {:error, reason}
  end

  defp valid_git_path_segment?(segment) do
    segment == Repository.normalize_slug(segment) and segment != ""
  end
end
