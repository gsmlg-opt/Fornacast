defmodule ForgeImports do
  @moduledoc "GitHub import discovery and durable orchestration."

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}
  alias ForgeAccounts.GitHubCredentialVault.Envelope

  alias ForgeImports.{
    Conflicts,
    GitHubAccounts,
    ImportRun,
    OneTimeCredential,
    OrganizationOrchestrator,
    Persistence,
    ReportEntry,
    ReportView,
    RepositoryItem,
    RepositoryPublisher,
    RunView,
    Cancellation,
    Retry,
    Waits
  }

  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @run_view_read_attempts 3
  @worker_repository_item_targets [
    :staging_git,
    :git_staged,
    :staging_metadata,
    :ready_to_publish,
    :publishing,
    :published,
    :completed
  ]

  def provider, do: :github

  def create_repository_discovery(actor, attrs, request_metadata, opts \\ []),
    do: ForgeImports.Discovery.create_repository(actor, attrs, request_metadata, opts)

  def create_organization_discovery(actor, attrs, request_metadata, opts \\ []),
    do: ForgeImports.Discovery.create_organization(actor, attrs, request_metadata, opts)

  defdelegate list_github_accounts(actor), to: GitHubAccounts, as: :list

  def link_github_account(actor, pat, request_metadata, opts \\ []),
    do: GitHubAccounts.link(actor, pat, request_metadata, opts)

  def reverify_github_account(actor, identity_id, request_metadata, opts \\ []),
    do: GitHubAccounts.reverify(actor, identity_id, request_metadata, opts)

  def replace_github_credential(actor, identity_id, pat, request_metadata, opts \\ []),
    do: GitHubAccounts.replace(actor, identity_id, pat, request_metadata, opts)

  defdelegate delete_github_credential(actor, identity_id, request_metadata),
    to: GitHubAccounts,
    as: :delete_credential

  defdelegate unlink_github_account(actor, identity_id, request_metadata),
    to: GitHubAccounts,
    as: :unlink

  def create_run(%User{} = actor, attrs) when is_map(attrs) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           :ok <- validate_predecessor_run(active_actor, attrs),
           :ok <- validate_credential_binding(active_actor, attrs) do
        %ImportRun{}
        |> ImportRun.creation_changeset(active_actor.id, attrs)
        |> Repo.insert()
      end
    end)
  end

  def create_run(_actor, _attrs), do: {:error, :forbidden}

  def get_run(%User{} = actor, id) when is_integer(id) and id > 0 do
    read_run_view(actor, id, @run_view_read_attempts)
  end

  def get_run(_actor, _id), do: {:error, :not_found}

  def get_run_view(%User{} = actor, id), do: get_run(actor, id)

  def get_run_view(_actor, _id), do: {:error, :not_found}

  def get_status(%User{} = actor, id), do: get_run(actor, id)

  def get_status(_actor, _id), do: {:error, :not_found}

  def get_report(%User{} = actor, id), do: ReportView.load(actor, id)

  def get_report(_actor, _id), do: {:error, :not_found}

  def resolve_repository_conflicts(actor, run_id, decisions, request_metadata),
    do: Conflicts.resolve(actor, run_id, decisions, request_metadata)

  def start_import(actor, run_id, request_metadata, opts \\ [])

  def start_import(%User{} = actor, run_id, request_metadata, opts)
      when is_integer(run_id) and run_id > 0 and is_map(request_metadata) and is_list(opts) do
    case organization_import_run?(actor, run_id) do
      true -> OrganizationOrchestrator.start(actor, run_id, request_metadata, opts)
      false -> Conflicts.start(actor, run_id, request_metadata, opts)
    end
  end

  def start_import(_actor, _run_id, _request_metadata, _opts), do: {:error, :invalid_selection}

  defp organization_import_run?(%User{id: actor_id}, run_id)
       when is_integer(actor_id) and is_integer(run_id) do
    case Repo.one(
           from run in ImportRun,
             where: run.id == ^run_id and run.actor_user_id == ^actor_id,
             select: run.source_kind
         ) do
      :organization -> true
      _other -> false
    end
  end

  defp organization_import_run?(_actor, _run_id), do: false

  def mark_destination_changed(actor, run_id, item_reference, request_metadata),
    do: Conflicts.destination_changed(actor, run_id, item_reference, request_metadata)

  @spec publish_repository(User.t(), pos_integer(), map()) ::
          {:ok, %{repository: Repository.t(), replaced: Repository.t() | nil}}
          | {:error,
             :metadata_not_ready
             | :busy
             | :destination_changed
             | :cancelled
             | :not_found
             | :publication_unavailable
             | :persistence_unavailable
             | :publication_inconsistent
             | :invalid_request_metadata}
  def publish_repository(actor, item_id, request_metadata),
    do: RepositoryPublisher.publish(actor, item_id, request_metadata)

  defp read_run_view(actor, id, attempts_left) do
    with {:ok, active_actor} <- active_actor(actor),
         %ImportRun{} = run <- actor_run(active_actor.id, id),
         items <- run_repository_items(run.id),
         reports <- run_reports(run.id),
         {:ok, current_version} <- active_run_version(active_actor.id, run.id) do
      if current_version == run.lock_version do
        {:ok, RunView.from_run(run, items, reports)}
      else
        retry_run_view(actor, id, attempts_left)
      end
    else
      _masked -> {:error, :not_found}
    end
  end

  defp retry_run_view(actor, id, attempts_left) when attempts_left > 1,
    do: read_run_view(actor, id, attempts_left - 1)

  defp retry_run_view(_actor, _id, _attempts_left), do: {:error, :not_found}

  defp actor_run(actor_id, id) do
    Repo.one(
      from run in ImportRun,
        where: run.id == ^id and run.actor_user_id == ^actor_id
    )
  end

  defp run_repository_items(run_id) do
    RepositoryItem
    |> where([item], item.import_run_id == ^run_id)
    |> order_by([item], asc: item.id)
    |> Repo.all()
  end

  defp run_reports(run_id) do
    ReportEntry
    |> where([report], report.import_run_id == ^run_id)
    |> order_by([report], asc: report.id)
    |> Repo.all()
  end

  defp active_run_version(actor_id, run_id) do
    case Repo.one(
           from run in ImportRun,
             join: actor in User,
             on: actor.id == run.actor_user_id,
             where:
               run.id == ^run_id and run.actor_user_id == ^actor_id and actor.kind == :user and
                 actor.state == :active,
             select: run.lock_version
         ) do
      version when is_integer(version) -> {:ok, version}
      _masked -> {:error, :not_found}
    end
  end

  def update_repository_selection(%User{} = actor, run_id, selected_ids)
      when is_integer(run_id) and run_id > 0 and is_list(selected_ids) do
    with {:ok, normalized_ids} <- normalize_selected_ids(selected_ids),
         {:ok, _updated} <-
           transact(fn -> update_selection_transaction(actor, run_id, normalized_ids) end) do
      get_run(actor, run_id)
    end
  end

  def update_repository_selection(_actor, _run_id, _selected_ids), do: {:error, :not_found}

  def update_organization_destination(%User{} = actor, run_id, destination)
      when is_integer(run_id) and run_id > 0 and is_map(destination) do
    with {:ok, _updated} <-
           transact(fn -> update_destination_transaction(actor, run_id, destination) end) do
      get_run(actor, run_id)
    end
  end

  def update_organization_destination(_actor, _run_id, _destination),
    do: {:error, :not_found}

  def create_repository_item(%User{} = actor, %ImportRun{} = expected_run, attrs)
      when is_map(attrs) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, current_run} <- scoped_run(active_actor, expected_run, lock?: true),
           :ok <- available_for_discovery(current_run, expected_run),
           :ok <- validate_predecessor_item(active_actor, current_run, attrs) do
        Persistence.create_repository_item(current_run, attrs)
      end
    end)
  end

  def create_repository_item(_actor, _run, _attrs), do: {:error, :not_found}

  def repository_items(%User{} = actor, %ImportRun{} = expected_run) do
    with {:ok, active_actor} <- active_actor(actor),
         {:ok, run} <- scoped_run(active_actor, expected_run) do
      items =
        RepositoryItem
        |> where([item], item.import_run_id == ^run.id)
        |> order_by([item], asc: item.id)
        |> Repo.all()

      {:ok, items}
    else
      _ -> {:error, :not_found}
    end
  end

  def repository_items(_actor, _run), do: {:error, :not_found}

  def select_repository_item(
        %User{} = actor,
        %ImportRun{} = expected_run,
        %RepositoryItem{} = expected_item,
        selected
      )
      when is_boolean(selected) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, _current_run} <- scoped_run(active_actor, expected_run),
           {:ok, _current_item} <- scoped_item(expected_run, expected_item) do
        Persistence.select_repository_item(expected_run, expected_item, selected)
      end
    end)
  end

  def select_repository_item(_actor, _run, _item, _selected), do: {:error, :not_found}

  def transition_run(actor, run, target, attrs \\ %{})

  def transition_run(%User{} = actor, %ImportRun{} = expected_run, target, attrs)
      when is_atom(target) and is_map(attrs) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, current_run} <- scoped_run(active_actor, expected_run) do
        changeset = run_transition_changeset(expected_run, current_run, target, attrs)
        persist_changeset(expected_run, [expected_run.state], changeset, :invalid_transition)
      end
    end)
  end

  def transition_run(_actor, _run, _target, _attrs), do: {:error, :not_found}

  def transition_repository_item(actor, run, item, target, attrs \\ %{})

  def transition_repository_item(
        %User{},
        %ImportRun{},
        %RepositoryItem{},
        target,
        attrs
      )
      when target in @worker_repository_item_targets and is_map(attrs),
      do: {:error, :invalid_transition}

  def transition_repository_item(
        %User{} = actor,
        %ImportRun{} = expected_run,
        %RepositoryItem{} = expected_item,
        target,
        attrs
      )
      when is_atom(target) and is_map(attrs) do
    mutate_item(actor, expected_run, expected_item, fn current_item ->
      if current_item.attempt_count > 0 do
        {:error, :invalid_transition}
      else
        changeset = RepositoryItem.transition_changeset(current_item, target, attrs)
        persist_changeset(current_item, [current_item.state], changeset, :invalid_transition)
      end
    end)
  end

  def transition_repository_item(_actor, _run, _item, _target, _attrs),
    do: {:error, :not_found}

  def attach_one_time_credential(
        actor,
        run,
        envelope,
        keyring \\ Fornacast.Config.github_credential_keyring()
      )

  def attach_one_time_credential(
        %User{} = actor,
        %ImportRun{} = expected_run,
        %Envelope{} = envelope,
        keyring
      ) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, current_run} <- scoped_run(active_actor, expected_run),
           :ok <- OneTimeCredential.verify_envelope(current_run, envelope, keyring) do
        changeset = OneTimeCredential.attach_changeset(expected_run, envelope)

        persist_changeset(
          expected_run,
          [expected_run.state],
          changeset,
          :credential_service_unavailable
        )
      end
    end)
  end

  def attach_one_time_credential(_actor, _run, _envelope, _keyring), do: {:error, :not_found}

  def replace_run_credential(actor, run_id, credential_source, request_metadata, opts \\ [])

  def replace_run_credential(%User{} = actor, run_id, credential_source, request_metadata, opts)
      when is_integer(run_id) and run_id > 0 and is_map(credential_source) and
             is_map(request_metadata) and is_list(opts) do
    with {:ok, active_actor} <- active_actor(actor),
         %ImportRun{} = run <- actor_run(active_actor.id, run_id) do
      Waits.resume_with_credential(
        active_actor,
        run,
        credential_source,
        request_metadata,
        opts
      )
    else
      _ -> {:error, :not_found}
    end
  end

  def replace_run_credential(_actor, _run_id, _credential_source, _request_metadata, _opts),
    do: {:error, :not_found}

  def request_cancel(actor, run_id, request_metadata, opts \\ [])

  def request_cancel(%User{} = actor, run_id, request_metadata, opts)
      when is_integer(run_id) and run_id > 0 and is_map(request_metadata) and is_list(opts) do
    with {:ok, active_actor} <- active_actor(actor),
         %ImportRun{} = run <- actor_run(active_actor.id, run_id),
         {:ok, canceled} <- Cancellation.request(active_actor, run, request_metadata, opts) do
      {:ok, canceled}
    else
      {:error, :forbidden} -> {:error, :not_found}
      {:error, :invalid_transition} -> {:error, :invalid_transition}
      {:error, :invalid_request_metadata} -> {:error, :invalid_request_metadata}
      {:error, :persistence_unavailable} -> {:error, :persistence_unavailable}
      _ -> {:error, :not_found}
    end
  end

  def request_cancel(_actor, _run_id, _request_metadata, _opts), do: {:error, :not_found}

  def retry_import(actor, run_id, credential_source, request_metadata, opts \\ [])

  def retry_import(%User{} = actor, run_id, credential_source, request_metadata, opts)
      when is_integer(run_id) and run_id > 0 and is_map(request_metadata) and is_list(opts) do
    with {:ok, active_actor} <- active_actor(actor),
         %ImportRun{} = predecessor <- actor_run(active_actor.id, run_id),
         {:ok, successor} <-
           Retry.create_successor(
             active_actor,
             predecessor,
             credential_source,
             request_metadata,
             opts
           ) do
      get_run(active_actor, successor.id)
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, :invalid_request_metadata} -> {:error, :invalid_request_metadata}
      {:error, :persistence_unavailable} -> {:error, :persistence_unavailable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  def retry_import(_actor, _run_id, _credential_source, _request_metadata, _opts),
    do: {:error, :not_found}

  defp mutate_item(actor, expected_run, expected_item, callback) do
    transact(fn ->
      with {:ok, active_actor} <- active_actor(actor, lock?: true),
           {:ok, current_run} <- scoped_run(active_actor, expected_run),
           {:ok, current_item} <- scoped_item(current_run, expected_item),
           :ok <- exact_item_capability(current_item, expected_item) do
        callback.(current_item)
      end
    end)
  end

  defp exact_item_capability(current, expected) do
    if current.lock_version == expected.lock_version and current.state == expected.state,
      do: :ok,
      else: {:error, :stale}
  end

  defp persist_changeset(row, allowed_states, %Ecto.Changeset{valid?: true} = changeset, _error) do
    Persistence.update_without_lease(row, allowed_states, changeset)
  end

  defp persist_changeset(_row, _allowed_states, %Ecto.Changeset{}, error), do: {:error, error}

  defp active_actor(actor, opts \\ [])

  defp active_actor(%User{id: actor_id}, opts) when is_integer(actor_id) and actor_id > 0 do
    query =
      from user in User,
        where: user.id == ^actor_id and user.kind == :user and user.state == :active

    case query |> maybe_lock(Keyword.get(opts, :lock?, false)) |> Repo.one() do
      %User{} = active_actor -> {:ok, active_actor}
      nil -> {:error, :forbidden}
    end
  end

  defp active_actor(_actor, _opts), do: {:error, :forbidden}

  defp scoped_run(%User{id: actor_id}, %ImportRun{id: run_id}, opts \\ []) do
    query =
      from run in ImportRun,
        where: run.id == ^run_id and run.actor_user_id == ^actor_id

    case query |> maybe_lock(Keyword.get(opts, :lock?, false)) |> Repo.one() do
      %ImportRun{} = run -> {:ok, run}
      nil -> {:error, :not_found}
    end
  end

  defp scoped_item(%ImportRun{id: run_id}, %RepositoryItem{id: item_id}) do
    case Repo.one(
           from item in RepositoryItem,
             where: item.id == ^item_id and item.import_run_id == ^run_id
         ) do
      %RepositoryItem{} = item -> {:ok, item}
      nil -> {:error, :not_found}
    end
  end

  defp available_for_discovery(current, expected) do
    now = DateTime.utc_now(:second)

    cond do
      current.lock_version != expected.lock_version -> {:error, :stale}
      current.state != :discovering -> {:error, :stale}
      active_lease?(current, now) -> {:error, :busy}
      true -> :ok
    end
  end

  defp active_lease?(%{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp active_lease?(_row, _now), do: false

  defp run_transition_changeset(
         %ImportRun{state: :discovering} = expected_run,
         %ImportRun{id: run_id},
         :awaiting_resolution,
         attrs
       ) do
    count =
      RepositoryItem
      |> where([item], item.import_run_id == ^run_id and item.selected == true)
      |> Repo.aggregate(:count, :id)

    ImportRun.snapshot_selection_changeset(expected_run, count, attrs)
  end

  defp run_transition_changeset(expected_run, _current_run, target, attrs),
    do: ImportRun.transition_changeset(expected_run, target, attrs)

  defp validate_credential_binding(%User{} = actor, attrs) do
    case credential_source(attrs) do
      :saved -> validate_saved_credential(actor, attrs)
      :one_time -> validate_one_time_identity(attrs)
      _unknown -> :ok
    end
  end

  defp validate_predecessor_run(%User{id: actor_id}, attrs) do
    case optional_positive_id(attrs, :predecessor_run_id) do
      :absent ->
        :ok

      {:ok, predecessor_id} ->
        case Repo.get(ImportRun, predecessor_id) do
          %ImportRun{actor_user_id: ^actor_id, state: state}
          when state in [:failed, :canceled, :completed_with_warnings] ->
            :ok

          %ImportRun{actor_user_id: ^actor_id} ->
            {:error, :invalid_predecessor}

          _foreign_or_missing ->
            {:error, :not_found}
        end

      :error ->
        {:error, :invalid_predecessor}
    end
  end

  defp validate_predecessor_item(%User{id: actor_id}, %ImportRun{} = run, attrs) do
    case optional_positive_id(attrs, :predecessor_item_id) do
      :absent ->
        :ok

      {:ok, predecessor_item_id} ->
        predecessor =
          Repo.one(
            from item in RepositoryItem,
              join: predecessor_run in ImportRun,
              on: predecessor_run.id == item.import_run_id,
              where:
                item.id == ^predecessor_item_id and predecessor_run.actor_user_id == ^actor_id,
              select: item
          )

        case predecessor do
          nil ->
            {:error, :not_found}

          %RepositoryItem{} = item when item.import_run_id == run.predecessor_run_id ->
            if retryable_unpublished_predecessor?(item),
              do: :ok,
              else: {:error, :invalid_predecessor}

          %RepositoryItem{} ->
            {:error, :invalid_predecessor}
        end

      :error ->
        {:error, :invalid_predecessor}
    end
  end

  defp retryable_unpublished_predecessor?(%RepositoryItem{
         state: state,
         publication_evidence: evidence,
         cleanup_state: nil
       })
       when state in [:failed, :canceled] and is_map(evidence) do
    map_size(evidence) == 0
  end

  defp retryable_unpublished_predecessor?(_item), do: false

  defp validate_saved_credential(%User{id: actor_id}, attrs) do
    with {:ok, credential_id} <- positive_id(attrs, :github_credential_id),
         {:ok, identity_id} <- positive_id(attrs, :github_identity_id),
         %GitHubCredential{} <-
           Repo.one(
             from credential in GitHubCredential,
               join: identity in GitHubIdentity,
               on: identity.id == credential.github_identity_id,
               where:
                 credential.id == ^credential_id and credential.status == :valid and
                   credential.local_user_id == ^actor_id and identity.id == ^identity_id and
                   identity.local_user_id == ^actor_id and identity.kind == :user and
                   identity.github_user_id > 0
           ) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp validate_one_time_identity(attrs) do
    with {:ok, identity_id} <- positive_id(attrs, :github_identity_id),
         %GitHubIdentity{} <-
           Repo.one(
             from identity in GitHubIdentity,
               where:
                 identity.id == ^identity_id and identity.kind == :user and
                   identity.github_user_id > 0
           ) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp credential_source(attrs) do
    case Map.get(attrs, :credential_source) || Map.get(attrs, "credential_source") do
      :saved -> :saved
      "saved" -> :saved
      :one_time -> :one_time
      "one_time" -> :one_time
      value -> value
    end
  end

  defp positive_id(attrs, field) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    case Ecto.Type.cast(:integer, value) do
      {:ok, id} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp optional_positive_id(attrs, field) do
    value = Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))

    if is_nil(value), do: :absent, else: positive_id(attrs, field)
  end

  defp normalize_selected_ids(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case Ecto.Type.cast(:integer, value) do
        {:ok, id} when id > 0 -> {:cont, {:ok, [id | normalized]}}
        _ -> {:halt, {:error, :invalid_selection}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)

        if length(normalized) == length(Enum.uniq(normalized)),
          do: {:ok, normalized},
          else: {:error, :invalid_selection}

      error ->
        error
    end
  end

  defp update_selection_transaction(actor, run_id, selected_ids) do
    with {:ok, active_actor} <- active_actor(actor, lock?: true),
         %ImportRun{state: :awaiting_resolution} = run <-
           Repo.one(
             from run in ImportRun,
               where: run.id == ^run_id and run.actor_user_id == ^active_actor.id
           ),
         items <-
           Repo.all(
             from item in RepositoryItem,
               where: item.import_run_id == ^run.id,
               order_by: [asc: item.id]
           ),
         true <- selected_ids -- Enum.map(items, & &1.github_repository_id) == [],
         :ok <- persist_item_selections(items, selected_ids),
         changeset <- ImportRun.selected_count_changeset(run, length(selected_ids)),
         {:ok, updated_run} <-
           Persistence.update_without_lease(run, [:awaiting_resolution], changeset) do
      {:ok, updated_run}
    else
      nil -> {:error, :not_found}
      %ImportRun{} -> {:error, :stale}
      false -> {:error, :invalid_selection}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_item_selections(items, selected_ids) do
    selected = MapSet.new(selected_ids)

    Enum.reduce_while(items, :ok, fn item, :ok ->
      changeset =
        RepositoryItem.selection_changeset(item, %{
          selected: MapSet.member?(selected, item.github_repository_id)
        })

      case Persistence.update_without_lease(item, [item.state], changeset) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_destination_transaction(actor, run_id, destination) do
    with {:ok, active_actor} <- active_actor(actor, lock?: true),
         %ImportRun{state: :awaiting_resolution, source_kind: :organization} = run <-
           Repo.one(
             from run in ImportRun,
               where: run.id == ^run_id and run.actor_user_id == ^active_actor.id
           ),
         {:ok, destination_plan} <-
           ForgeImports.Destination.organization(
             active_actor,
             run.source_owner_login,
             destination
           ),
         :ok <- validate_destination_security(active_actor, run, destination_plan),
         items <-
           Repo.all(
             from item in RepositoryItem,
               where: item.import_run_id == ^run.id,
               order_by: [asc: item.id]
           ),
         :ok <- persist_destination_items(items, destination_plan),
         changeset <-
           ImportRun.destination_changeset(run, %{
             destination_organization_action: destination_plan.action,
             destination_organization_slug:
               Map.get(destination_plan, :requested_slug, destination_plan.slug),
             destination_organization_id: destination_plan.organization_id,
             destination_organization_status: destination_plan.status,
             destination_organization_classification: destination_plan.classification
           }),
         {:ok, updated_run} <-
           Persistence.update_without_lease(run, [:awaiting_resolution], changeset) do
      {:ok, updated_run}
    else
      nil -> {:error, :not_found}
      %ImportRun{} -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_destination_items(items, destination) do
    duplicate_slugs =
      items
      |> Enum.map(&proposed_destination_slug/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_slug, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    Enum.reduce_while(items, :ok, fn item, :ok ->
      attrs = destination_item_attrs(item, destination, duplicate_slugs)
      changeset = RepositoryItem.destination_changeset(item, attrs)

      case Persistence.update_without_lease(item, [item.state], changeset) do
        {:ok, _updated} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_destination_security(actor, run, destination) do
    with {:ok, profiles} <- ForgeImports.Destination.safety_profiles(destination),
         :ok <- ForgeAccounts.validate_github_external_profiles(actor, profiles),
         :ok <- validate_one_time_destination(actor, run, profiles) do
      :ok
    else
      {:error, :credential_service_unavailable} = error -> error
      _unsafe -> {:error, :invalid_destination}
    end
  end

  defp validate_one_time_destination(
         actor,
         %ImportRun{credential_source: :one_time} = run,
         profiles
       ),
       do: OneTimeCredential.validate_profiles(actor, run, profiles)

  defp validate_one_time_destination(_actor, %ImportRun{credential_source: :saved}, _profiles),
    do: :ok

  defp destination_item_attrs(item, %{status: :invalid} = destination, _duplicates) do
    destination_item_attrs(
      item,
      destination,
      :awaiting_resolution,
      destination.classification,
      nil
    )
  end

  defp destination_item_attrs(item, %{status: :conflict} = destination, _duplicates) do
    destination_item_attrs(
      item,
      destination,
      :awaiting_resolution,
      destination.classification,
      proposed_destination_slug(item)
    )
  end

  defp destination_item_attrs(item, destination, duplicates) do
    slug = proposed_destination_slug(item)

    cond do
      is_nil(slug) ->
        destination_item_attrs(
          item,
          destination,
          :awaiting_resolution,
          "invalid_repository_slug",
          nil
        )

      MapSet.member?(duplicates, slug) ->
        destination_item_attrs(
          item,
          destination,
          :awaiting_resolution,
          "normalized_slug_collision",
          slug
        )

      item.source_name != slug ->
        destination_item_attrs(
          item,
          destination,
          :awaiting_resolution,
          "repository_slug_normalized",
          slug
        )

      local_repository_conflict?(destination.owner_id, slug) ->
        destination_item_attrs(
          item,
          destination,
          :awaiting_resolution,
          "repository_conflict",
          slug
        )

      true ->
        destination_item_attrs(item, destination, :queued, nil, slug)
    end
  end

  defp destination_item_attrs(item, destination, state, wait_reason, slug) do
    %{
      destination_owner_id: destination.owner_id,
      destination_slug: slug,
      destination_visibility: item.destination_visibility,
      state: state,
      wait_reason: wait_reason
    }
  end

  defp local_repository_conflict?(owner_id, slug)
       when is_integer(owner_id) and is_binary(slug) do
    Repo.exists?(
      from repository in ForgeRepos.Repository,
        where:
          repository.owner_user_id == ^owner_id and repository.slug == ^slug and
            is_nil(repository.deleted_at)
    )
  end

  defp local_repository_conflict?(_owner_id, _slug), do: false

  defp proposed_destination_slug(%RepositoryItem{destination_slug: slug})
       when is_binary(slug),
       do: slug

  defp proposed_destination_slug(%RepositoryItem{source_name: source_name}) do
    slug = ForgeRepos.Repository.normalize_slug(source_name)
    if ForgeRepos.Repository.canonical_slug?(slug), do: slug
  end

  defp maybe_lock(query, true) do
    if postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  defp maybe_lock(query, false), do: query

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp transact(callback) do
    transaction = fn ->
      Repo.transaction(fn ->
        case callback.() do
          {:ok, _value} = ok -> ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end
end
