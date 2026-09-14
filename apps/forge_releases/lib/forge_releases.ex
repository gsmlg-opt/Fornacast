defmodule ForgeReleases do
  @moduledoc """
  Repository-scoped release metadata and its local mutation policy.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts.{GitHubIdentity, User}
  alias ForgeReleases.{Release, SyncEvents}
  alias ForgeRepos.Repository
  alias Fornacast.{Audit, Page, Repo}

  @type validation_error :: %{
          required(:resource) => String.t(),
          required(:field) => String.t(),
          required(:code) => :missing | :invalid | :unprocessable
        }

  if Mix.env() == :test do
    @fence_hook_key {__MODULE__, :fence_hook}

    @doc false
    def with_test_fence_hook(hook, fun) when is_function(hook, 0) and is_function(fun, 0) do
      previous = Process.get(@fence_hook_key)
      Process.put(@fence_hook_key, hook)

      try do
        fun.()
      after
        if previous,
          do: Process.put(@fence_hook_key, previous),
          else: Process.delete(@fence_hook_key)
      end
    end

    defp run_fence_hook do
      Process.get(@fence_hook_key, fn -> :ok end).()
      :ok
    end
  else
    defp run_fence_hook, do: :ok
  end

  @spec list(User.t() | nil, String.t(), String.t(), map()) ::
          {:ok, Page.t(Release.t())} | {:error, term()}
  def list(actor, owner_slug, repository_slug, filters) when is_map(filters) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner_slug,
             repository_slug,
             :repository_read
           ),
         {:ok, %{page: page, per_page: per_page}} <- validate_page(filters) do
      query =
        Release
        |> where(
          [release],
          release.repository_id == ^repository.id and is_nil(release.deleted_at)
        )
        |> scope_visible_releases(actor, repository)
        |> order_by([release], desc: release.inserted_at, desc: release.id)

      total = Repo.aggregate(query, :count, :id)
      offset = (page - 1) * per_page

      entries =
        query
        |> limit(^per_page)
        |> offset(^offset)
        |> Repo.all()
        |> decorate_releases(actor, repository)

      {:ok, %Page{entries: entries, total: total, page: page, per_page: per_page}}
    end
  end

  def list(_actor, _owner_slug, _repository_slug, _filters), do: invalid("base")

  @spec get(User.t() | nil, String.t(), String.t(), pos_integer()) ::
          {:ok, Release.t()} | {:error, term()}
  def get(actor, owner_slug, repository_slug, release_id)
      when is_integer(release_id) and release_id > 0 do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner_slug,
             repository_slug,
             :repository_read
           ),
         %Release{} = release <- fetch_visible_release(actor, repository, release_id) do
      {:ok, decorate_release(release, actor, repository)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def get(_actor, _owner_slug, _repository_slug, _release_id), do: {:error, :not_found}

  @spec get_by_tag(User.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, Release.t()} | {:error, term()}
  def get_by_tag(actor, owner_slug, repository_slug, tag_name) when is_binary(tag_name) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner_slug,
             repository_slug,
             :repository_read
           ),
         %Release{} = release <- fetch_visible_release_by_tag(actor, repository, tag_name) do
      {:ok, decorate_release(release, actor, repository)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def get_by_tag(_actor, _owner_slug, _repository_slug, _tag_name), do: {:error, :not_found}

  @spec latest(User.t() | nil, String.t(), String.t()) ::
          {:ok, Release.t()} | {:error, term()}
  def latest(actor, owner_slug, repository_slug) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner_slug,
             repository_slug,
             :repository_read
           ),
         %Release{} = release <-
           Repo.one(
             from(release in Release,
               where:
                 release.repository_id == ^repository.id and is_nil(release.deleted_at) and
                   release.draft == false and release.prerelease == false,
               order_by: [desc: release.published_at, desc: release.id],
               limit: 1
             )
           ) do
      {:ok, decorate_release(release, actor, repository)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec create(User.t(), String.t(), String.t(), map(), map()) ::
          {:ok, Release.t()} | {:error, term()}
  def create(actor, owner_slug, repository_slug, attrs, request_metadata)
      when is_struct(actor, User) and is_map(attrs) and is_map(request_metadata) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner_slug,
             repository_slug,
             :repository_write
           ),
         :ok <- run_fence_hook() do
      ForgeRepos.with_write_fence(repository, :tag, fn repository_path, remaining_ms ->
        repository
        |> create_multi(actor, attrs, request_metadata, repository_path, remaining_ms)
        |> transaction()
        |> map_mutation_result(:release, actor)
      end)
    end
  end

  def create(_actor, _owner_slug, _repository_slug, _attrs, _request_metadata),
    do: {:error, :forbidden}

  @spec update(User.t(), String.t(), String.t(), pos_integer(), map(), map()) ::
          {:ok, Release.t()} | {:error, term()}
  def update(actor, owner_slug, repository_slug, release_id, attrs, request_metadata)
      when is_struct(actor, User) and is_integer(release_id) and release_id > 0 and is_map(attrs) and
             is_map(request_metadata) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner_slug,
             repository_slug,
             :repository_write
           ),
         :ok <- run_fence_hook() do
      ForgeRepos.with_write_fence(repository, :tag, fn repository_path, remaining_ms ->
        actor
        |> update_multi(
          repository,
          release_id,
          attrs,
          request_metadata,
          repository_path,
          remaining_ms
        )
        |> transaction()
        |> map_mutation_result(:release, actor)
      end)
    end
  end

  def update(_actor, _owner_slug, _repository_slug, _release_id, _attrs, _request_metadata),
    do: {:error, :forbidden}

  @spec delete(User.t(), String.t(), String.t(), pos_integer(), map()) ::
          :ok | {:error, term()}
  def delete(actor, owner_slug, repository_slug, release_id, request_metadata)
      when is_struct(actor, User) and is_integer(release_id) and release_id > 0 and
             is_map(request_metadata) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner_slug,
             repository_slug,
             :repository_write
           ) do
      actor
      |> delete_multi(repository, release_id, request_metadata)
      |> transaction()
      |> map_delete_result()
    end
  end

  def delete(_actor, _owner_slug, _repository_slug, _release_id, _request_metadata),
    do: {:error, :forbidden}

  defdelegate release_sync_projection(repository_id, release_id), to: ForgeReleases.Sync

  defdelegate append_sync_release_observe(multi, key, expected), to: ForgeReleases.Sync

  defdelegate append_sync_release_apply(multi, key, request), to: ForgeReleases.Sync

  @doc false
  @spec create_multi(User.t(), Repository.t(), map(), map(), keyword()) :: Multi.t()
  def create_multi(
        %User{} = actor,
        %Repository{} = repository,
        attrs,
        request_metadata,
        options \\ []
      )
      when is_map(attrs) and is_map(request_metadata) and is_list(options) do
    create_multi(
      repository,
      actor,
      attrs,
      request_metadata,
      ForgeRepos.absolute_storage_path(repository),
      GitCore.Limits.get(:ref_deadline_ms),
      options
    )
  end

  @doc false
  @spec transaction(Multi.t()) :: {:ok, map()} | {:error, Multi.name(), term(), map()}
  def transaction(%Multi{} = multi), do: Repo.transaction(multi)

  defp create_multi(
         repository,
         actor,
         attrs,
         request_metadata,
         repository_path,
         remaining_ms,
         event_options \\ []
       ) do
    attrs = put_default(attrs, "target_commitish", repository.default_branch)

    Multi.new()
    |> Multi.run(:authorization, fn repo, _changes ->
      authorize_mutation(repo, actor.id, repository.id)
    end)
    |> Multi.insert(:release, fn %{authorization: %{actor: current_actor}} ->
      Release.create_changeset(
        %Release{repository_id: repository.id, author_user_id: current_actor.id},
        attrs
      )
    end)
    |> Multi.run(:tag, fn _repo, %{release: release} ->
      require_tag(repository_path, release.tag_name, remaining_ms)
    end)
    |> SyncEvents.release("release.created", event_options)
    |> Audit.record_multi(
      :audit,
      actor,
      "release.created",
      "release",
      fn %{release: release} -> release.id end,
      %{"repository_id" => repository.id, "result" => "success"},
      request_metadata: request_metadata
    )
  end

  defp update_multi(
         actor,
         repository,
         release_id,
         attrs,
         request_metadata,
         repository_path,
         remaining_ms
       ) do
    Multi.new()
    |> Multi.run(:authorization, fn repo, _changes ->
      authorize_release_mutation(repo, actor.id, repository.id, release_id)
    end)
    |> Multi.update(:release, fn %{authorization: %{release: release}} ->
      Release.update_changeset(release, attrs)
    end)
    |> Multi.run(:tag, fn _repo, %{release: release} ->
      require_tag(repository_path, release.tag_name, remaining_ms)
    end)
    |> SyncEvents.release("release.updated")
    |> Audit.record_multi(
      :audit,
      actor,
      "release.updated",
      "release",
      fn %{release: release} -> release.id end,
      %{"repository_id" => repository.id, "result" => "success"},
      request_metadata: request_metadata
    )
  end

  defp delete_multi(actor, repository, release_id, request_metadata) do
    Multi.new()
    |> Multi.run(:authorization, fn repo, _changes ->
      authorize_release_mutation(repo, actor.id, repository.id, release_id)
    end)
    |> Multi.update(:release, fn %{authorization: %{release: release}} ->
      Release.delete_changeset(release)
    end)
    |> SyncEvents.release("release.deleted")
    |> Audit.record_multi(
      :audit,
      actor,
      "release.deleted",
      "release",
      fn %{release: release} -> release.id end,
      %{"repository_id" => repository.id, "result" => "success"},
      request_metadata: request_metadata
    )
  end

  defp authorize_mutation(repo, actor_id, repository_id) do
    with %User{} = actor <- repo.get_by(User, id: actor_id, kind: :user, state: :active),
         %Repository{} = repository <- current_repository(repo, repository_id),
         true <- Fornacast.Access.allowed?(actor, :repository_write, repository) do
      {:ok, %{actor: actor, repository: repository}}
    else
      nil -> {:error, :forbidden}
      false -> {:error, :forbidden}
    end
  end

  defp authorize_release_mutation(repo, actor_id, repository_id, release_id) do
    with {:ok, authorization} <- authorize_mutation(repo, actor_id, repository_id),
         %Release{} = release <-
           repo.one(
             from(release in Release,
               where:
                 release.id == ^release_id and release.repository_id == ^repository_id and
                   is_nil(release.deleted_at),
               lock: "FOR UPDATE"
             )
           ) do
      {:ok, Map.put(authorization, :release, release)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp current_repository(repo, repository_id) do
    repo.one(
      from(repository in Repository,
        join: owner in User,
        on: owner.id == repository.owner_user_id,
        where:
          repository.id == ^repository_id and repository.lifecycle == :ready and
            is_nil(repository.deleted_at) and owner.state == :active and
            owner.kind in [:user, :organization],
        select: repository
      )
    )
  end

  defp require_tag(_repository_path, tag_name, _remaining_ms) when not is_binary(tag_name),
    do: missing_tag()

  defp require_tag(repository_path, tag_name, remaining_ms) when remaining_ms > 0 do
    case GitCore.exact_ref(repository_path, "refs/tags/#{tag_name}", deadline_ms: remaining_ms) do
      {:ok, nil} -> missing_tag()
      {:ok, _oid} -> {:ok, tag_name}
      {:error, _error} -> {:error, {:unavailable, :git}}
    end
  end

  defp require_tag(_repository_path, _tag_name, _remaining_ms),
    do: {:error, {:unavailable, :write_timeout}}

  defp fetch_visible_release(actor, repository, release_id) do
    Release
    |> where(
      [release],
      release.id == ^release_id and release.repository_id == ^repository.id and
        is_nil(release.deleted_at)
    )
    |> scope_visible_releases(actor, repository)
    |> Repo.one()
  end

  defp fetch_visible_release_by_tag(actor, repository, tag_name) do
    Release
    |> where(
      [release],
      release.repository_id == ^repository.id and release.tag_name == ^tag_name and
        is_nil(release.deleted_at)
    )
    |> scope_visible_releases(actor, repository)
    |> Repo.one()
  end

  defp scope_visible_releases(query, actor, repository) do
    if Fornacast.Access.allowed?(actor, :repository_write, repository),
      do: query,
      else: where(query, [release], release.draft == false)
  end

  defp decorate_releases(releases, actor, repository),
    do: Enum.map(releases, &decorate_release(&1, actor, repository))

  defp decorate_release(%Release{} = release, actor, repository) do
    writable = Fornacast.Access.allowed?(actor, :repository_write, repository)
    author = release_author(release, actor)
    %{release | author: author, capabilities: %{can_edit: writable, can_delete: writable}}
  end

  defp release_author(%Release{author_user_id: user_id}, %User{id: user_id} = actor), do: actor

  defp release_author(%Release{author_user_id: user_id}, _actor) when is_integer(user_id),
    do: ForgeAccounts.get_account(user_id)

  defp release_author(%Release{author_github_identity_id: identity_id}, _actor)
       when is_integer(identity_id),
       do: Repo.get(GitHubIdentity, identity_id)

  defp release_author(_release, _actor), do: nil

  defp map_mutation_result(
         {:ok, %{authorization: %{repository: repository}, release: release}},
         key,
         actor
       )
       when key == :release do
    {:ok, decorate_release(release, actor, repository)}
  end

  defp map_mutation_result({:error, :authorization, reason, _changes}, _key, _actor),
    do: {:error, reason}

  defp map_mutation_result({:error, :tag, reason, _changes}, _key, _actor),
    do: {:error, reason}

  defp map_mutation_result(
         {:error, :release, %Ecto.Changeset{} = changeset, _changes},
         _key,
         _actor
       ),
       do: {:error, {:validation, changeset_errors(changeset)}}

  defp map_mutation_result(
         {:error, _step, {:unavailable, _reason} = error, _changes},
         _key,
         _actor
       ),
       do: {:error, error}

  defp map_mutation_result({:error, _step, _reason, _changes}, _key, _actor),
    do: invalid("base")

  defp map_delete_result({:ok, _changes}), do: :ok
  defp map_delete_result({:error, :authorization, reason, _changes}), do: {:error, reason}
  defp map_delete_result({:error, _step, _reason, _changes}), do: invalid("base")

  defp changeset_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {_message, opts}} ->
      code = if Keyword.get(opts, :constraint), do: :unprocessable, else: :invalid
      %{resource: "Release", field: Atom.to_string(field), code: code}
    end)
  end

  defp validate_page(filters) do
    page = attr(filters, "page") || 1
    per_page = attr(filters, "per_page") || 30

    if is_integer(page) and page > 0 and is_integer(per_page) and per_page in 1..100,
      do: {:ok, %{page: page, per_page: per_page}},
      else: invalid("page")
  end

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, String.to_existing_atom(key)))

  defp put_default(attrs, key, value) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, String.to_existing_atom(key)),
      do: attrs,
      else: Map.put(attrs, key, value)
  end

  defp missing_tag,
    do: {:error, {:validation, [%{resource: "Release", field: "tag_name", code: :missing}]}}

  defp invalid(field),
    do: {:error, {:validation, [%{resource: "Release", field: field, code: :invalid}]}}
end
