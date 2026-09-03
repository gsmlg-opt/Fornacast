defmodule ForgeImports.OrganizationOrchestrator do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{Namespace, Organization, OrganizationMember, User}

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    Persistence,
    Reconciler,
    RepositoryItem,
    RepositoryPublisher
  }

  alias Fornacast.{Audit, Repo}

  @allow_test_options Mix.env() == :test

  @spec start(User.t(), pos_integer(), map(), keyword()) ::
          {:ok, ForgeImports.RunView.t()} | {:error, atom()}
  def start(%User{} = actor, run_id, request_metadata, opts)
      when is_integer(run_id) and run_id > 0 and is_map(request_metadata) and is_list(opts) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, options} <- start_options(opts),
         {:ok, %{run: running, organization: organization}} <-
           transact(fn -> start_transaction(actor, run_id, safe_metadata, options) end),
         :ok <- dispatch(running.id, options),
         {:ok, view} <- ForgeImports.get_run(actor, run_id) do
      {:ok, %{view | destination_organization: organization}}
    end
  end

  def start(_actor, _run_id, _request_metadata, _opts), do: {:error, :invalid_selection}

  @spec freeze_and_activate(User.t(), ImportRun.t(), map()) ::
          {:ok,
           %{run: ImportRun.t(), organization: Organization.t(), items: [RepositoryItem.t()]}}
          | {:error, atom()}
  def freeze_and_activate(%User{} = actor, %ImportRun{} = run, request_metadata)
      when is_map(request_metadata) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata) do
      transact(fn ->
        freeze_and_activate_transaction(actor, run.id, safe_metadata, %{
          audit: Audit,
          dispatch: :manual,
          reconciler: Reconciler
        })
      end)
    end
  end

  def freeze_and_activate(_actor, _run, _request_metadata), do: {:error, :invalid_selection}

  @spec create_destination_organization(module(), User.t(), ImportRun.t()) ::
          {:ok, Organization.t()} | {:error, atom()}
  def create_destination_organization(repo, %User{} = actor, %ImportRun{} = run)
      when is_atom(repo) do
    attrs = organization_attrs(run)
    operation_id = organization_operation_id(run.id)

    metadata =
      (run.request_metadata || %{})
      |> Map.put("operation_id", operation_id)

    multi =
      Ecto.Multi.new()
      |> ForgeAccounts.github_import_organization_multi(
        :organization,
        actor,
        attrs,
        metadata,
        operation_id
      )

    case repo.transaction(multi) do
      {:ok, %{organization: organization}} ->
        with {:ok, _updated_run} <-
               propagate_organization(run, selected_items(run.id), organization.id),
             {:ok, _audit} <-
               Audit.record(
                 actor,
                 "github_import.organization_activated",
                 "organization",
                 organization.id,
                 %{"github_import_run_id" => run.id, "result" => "success"},
                 request_metadata: metadata,
                 operation_id: operation_id
               ) do
          {:ok, organization}
        else
          {:error, reason} -> {:error, reason}
          _failure -> {:error, :destination_changed}
        end

      {:error, _step, _reason, _changes} ->
        {:error, :destination_changed}
    end
  end

  def create_destination_organization(_repo, _actor, _run), do: {:error, :destination_changed}

  @spec activate_existing_organization(module(), User.t(), ImportRun.t()) ::
          {:ok, Organization.t()} | {:error, atom()}
  def activate_existing_organization(repo, %User{} = actor, %ImportRun{} = run)
      when is_atom(repo) do
    with {:ok, organization} <- locked_owned_organization(actor, run) do
      {:ok, organization}
    end
  end

  def activate_existing_organization(_repo, _actor, _run), do: {:error, :stale}

  defp start_transaction(actor, run_id, request_metadata, options) do
    freeze_and_activate_transaction(actor, run_id, request_metadata, options)
  end

  defp freeze_and_activate_transaction(actor, run_id, request_metadata, options) do
    with_actor_run(actor, run_id, fn active_actor, run, now ->
      with :ok <- startable_run(active_actor, run, now),
           items <- run_items(run.id),
           {:ok, selected_items} <- exact_selected_items(run, items, now),
           :ok <- prelock_replacement_targets(selected_items),
           {:ok, frozen_plans} <- freeze_plans(active_actor, run, selected_items),
           :ok <- unique_final_slugs(frozen_plans),
           {:ok, frozen_items} <- persist_frozen_plans(frozen_plans, now),
           skip_count <- Enum.count(frozen_plans, &(&1.action == :skip)),
           {:ok, ready} <-
             Persistence.update_without_lease(
               run,
               [:awaiting_resolution],
               ImportRun.transition_changeset(run, :ready, %{
                 skipped_count: run.skipped_count + skip_count
               }),
               now
             ),
           {:ok, running} <-
             Persistence.update_without_lease(
               ready,
               [:ready],
               ImportRun.transition_changeset(ready, :running, %{}),
               now
             ),
           {:ok, organization, activated_run} <-
             activate_destination(Repo, active_actor, running, frozen_items, request_metadata),
           :ok <-
             record_start_audits(
               options.audit,
               active_actor,
               activated_run,
               frozen_plans,
               request_metadata
             ) do
        {:ok, %{run: activated_run, organization: organization, items: frozen_items}}
      end
    end)
  end

  defp activate_destination(repo, actor, run, frozen_items, request_metadata) do
    case run.destination_organization_action do
      :new ->
        activate_new_destination(repo, actor, run, frozen_items, request_metadata)

      :existing ->
        with {:ok, organization} <- activate_existing_organization(repo, actor, run) do
          {:ok, organization, run}
        end
    end
  end

  defp activate_new_destination(repo, actor, run, frozen_items, request_metadata) do
    attrs = organization_attrs(run)
    operation_id = organization_operation_id(run.id)

    metadata =
      request_metadata
      |> Map.put("operation_id", operation_id)

    multi =
      Ecto.Multi.new()
      |> ForgeAccounts.github_import_organization_multi(
        :organization,
        actor,
        attrs,
        metadata,
        operation_id
      )

    case repo.transaction(multi) do
      {:ok, %{organization: organization}} ->
        with {:ok, updated_run} <- propagate_organization(run, frozen_items, organization.id),
             {:ok, _audit} <-
               Audit.record(
                 actor,
                 "github_import.organization_activated",
                 "organization",
                 organization.id,
                 %{"github_import_run_id" => run.id, "result" => "success"},
                 request_metadata: metadata,
                 operation_id: operation_id
               ),
             true <- updated_run.destination_organization_id == organization.id do
          {:ok, organization, updated_run}
        else
          _failure -> {:error, :destination_changed}
        end

      {:error, _step, _reason, _changes} ->
        {:error, :destination_changed}
    end
  end

  defp locked_owned_organization(actor, run) do
    organization_id = run.destination_organization_id
    slug = run.destination_organization_slug

    query =
      from organization in Organization,
        join: membership in OrganizationMember,
        on: membership.organization_id == organization.id,
        where:
          organization.id == ^organization_id and organization.kind == :organization and
            organization.state == :active and organization.username == ^slug and
            membership.user_id == ^actor.id and membership.role == :owner

    case query |> maybe_lock() |> Repo.one() do
      %Organization{} = organization -> {:ok, organization}
      nil -> {:error, :stale}
    end
  end

  defp propagate_organization(run, items, organization_id) do
    run_changeset = ImportRun.organization_activation_changeset(run, organization_id)

    with true <- run_changeset.valid?,
         {1, _rows} <-
           Repo.update_all(
             from(candidate in ImportRun,
               where:
                 candidate.id == ^run.id and candidate.lock_version == ^run.lock_version and
                   candidate.state == :running and
                   is_nil(candidate.destination_organization_id)
             ),
             set: [
               destination_organization_id: organization_id,
               updated_at: DateTime.utc_now(:second)
             ],
             inc: [lock_version: 1]
           ),
         :ok <- propagate_item_owners(items, organization_id) do
      {:ok, Repo.get!(ImportRun, run.id)}
    else
      _stale -> {:error, :destination_changed}
    end
  end

  defp propagate_item_owners(items, organization_id) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      changeset = RepositoryItem.destination_owner_activation_changeset(item, organization_id)

      if changeset.valid? do
        case Repo.update_all(
               from(candidate in RepositoryItem,
                 where:
                   candidate.id == ^item.id and candidate.import_run_id == ^item.import_run_id and
                     candidate.lock_version == ^item.lock_version and
                     is_nil(candidate.destination_owner_id) and
                     is_nil(candidate.hidden_repository_id)
               ),
               set: [destination_owner_id: organization_id, updated_at: DateTime.utc_now(:second)],
               inc: [lock_version: 1]
             ) do
          {1, _rows} -> {:cont, :ok}
          {0, _rows} -> {:halt, {:error, :destination_changed}}
        end
      else
        {:halt, {:error, :destination_changed}}
      end
    end)
  end

  defp organization_attrs(run) do
    %{
      username: run.destination_organization_slug,
      display_name: Map.get(run.source_metadata, "name") || run.destination_organization_slug,
      description: Map.get(run.source_metadata, "description"),
      state: :active
    }
  end

  defp organization_operation_id(run_id), do: "github-import-organization-#{run_id}"

  defp selected_items(run_id) do
    RepositoryItem
    |> where([item], item.import_run_id == ^run_id and item.selected == true)
    |> order_by([item], asc: item.id)
    |> Repo.all()
  end

  defp startable_run(
         actor,
         %ImportRun{state: :awaiting_resolution, source_kind: :organization} = run,
         now
       ) do
    cond do
      active_lease?(run, now) -> {:error, :busy}
      run.destination_organization_status != :clean -> {:error, :stale}
      true -> validate_run_destination(actor, run)
    end
  end

  defp startable_run(_actor, %ImportRun{}, _now), do: {:error, :stale}

  defp validate_run_destination(
         actor,
         %ImportRun{
           destination_organization_action: :existing,
           destination_organization_id: organization_id,
           destination_organization_slug: slug
         }
       )
       when is_integer(organization_id) do
    if Enum.any?(ForgeAccounts.list_repository_owners(actor), fn owner ->
         owner.id == organization_id and owner.kind == :organization and owner.state == :active and
           owner.username == slug
       end),
       do: :ok,
       else: {:error, :stale}
  end

  defp validate_run_destination(
         _actor,
         %ImportRun{
           destination_organization_action: :new,
           destination_organization_id: nil,
           destination_organization_slug: slug
         }
       ) do
    with {:ok, ^slug} <- Namespace.validate(slug),
         false <- Repo.exists?(from user in User, where: user.username == ^slug) do
      :ok
    else
      _changed -> {:error, :stale}
    end
  end

  defp validate_run_destination(_actor, _run), do: {:error, :stale}

  defp exact_selected_items(run, items, now) do
    selected = Enum.filter(items, & &1.selected)

    cond do
      selected == [] ->
        {:error, :invalid_selection}

      length(selected) != run.selected_count ->
        {:error, :stale}

      Enum.any?(selected, &active_lease?(&1, now)) ->
        {:error, :busy}

      Enum.any?(selected, &(&1.state != :queued)) ->
        {:error, :invalid_selection}

      true ->
        {:ok, selected}
    end
  end

  defp freeze_plans(actor, run, items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, plans} ->
      with {:ok, decision, action} <- immutable_decision(item),
           :ok <- validate_frozen_destination(actor, run, item, action) do
        {:cont, {:ok, [%{item: item, decision: decision, action: action} | plans]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      error -> error
    end
  end

  defp immutable_decision(%RepositoryItem{conflict_action: nil} = item) do
    if clean_create?(item),
      do: {:ok, %{"action" => "create", "slug" => item.destination_slug}, :create},
      else: {:error, :invalid_selection}
  end

  defp immutable_decision(%RepositoryItem{conflict_action: :skip}),
    do: {:ok, %{"action" => "skip"}, :skip}

  defp immutable_decision(%RepositoryItem{conflict_action: :rename} = item) do
    if ForgeRepos.Repository.canonical_slug?(item.destination_slug),
      do: {:ok, %{"action" => "rename", "slug" => item.destination_slug}, :rename},
      else: {:error, :invalid_selection}
  end

  defp immutable_decision(%RepositoryItem{conflict_action: :replace} = item) do
    {:ok,
     %{
       "action" => "replace",
       "slug" => item.destination_slug,
       "replacement_repository_id" => item.replacement_repository_id
     }, :replace}
  end

  defp immutable_decision(_item), do: {:error, :invalid_selection}

  defp validate_frozen_destination(actor, run, item, :skip),
    do: validate_destination_owner(actor, run, item.destination_owner_id)

  defp validate_frozen_destination(actor, run, item, action)
       when action in [:create, :rename] do
    with :ok <- validate_destination_owner(actor, run, item.destination_owner_id),
         false <- local_repository_conflict?(item.destination_owner_id, item.destination_slug) do
      :ok
    else
      _changed -> {:error, :stale}
    end
  end

  defp validate_frozen_destination(actor, run, item, :replace) do
    with {:ok, target} <- exact_replacement_target(item.replacement_repository_id),
         true <- replacement_fingerprint_matches?(item, target),
         :ok <- validate_replace_scope(actor, run, item, target) do
      :ok
    else
      false -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_replace_scope(
         actor,
         %ImportRun{destination_organization_action: :new},
         item,
         target
       ) do
    if item.destination_owner_id == target.owner_user_id and
         replacement_authorized?(actor, target) do
      :ok
    else
      {:error, :stale}
    end
  end

  defp validate_replace_scope(actor, run, item, _target) do
    validate_destination_owner(actor, run, item.destination_owner_id)
  end

  defp replacement_authorized?(actor, repository) do
    case Fornacast.Access.authorize(actor, :repository_admin, repository) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, :stale}
    end
  end

  defp validate_destination_owner(actor, run, owner_id) do
    with {:ok, expected_owner_id} <- expected_destination_owner(actor, run),
         true <- owner_id == expected_owner_id do
      :ok
    else
      _changed -> {:error, :stale}
    end
  end

  defp expected_destination_owner(
         _actor,
         %ImportRun{
           destination_organization_action: :new,
           destination_organization_id: nil
         }
       ),
       do: {:ok, nil}

  defp expected_destination_owner(
         actor,
         %ImportRun{
           destination_organization_action: :existing,
           destination_organization_id: organization_id,
           destination_organization_slug: slug
         }
       )
       when is_integer(organization_id) do
    case Enum.find(ForgeAccounts.list_repository_owners(actor), fn owner ->
           owner.id == organization_id and owner.kind == :organization and owner.state == :active and
             owner.username == slug
         end) do
      %{id: ^organization_id, kind: :organization} -> {:ok, organization_id}
      nil -> {:error, :stale}
    end
  end

  defp expected_destination_owner(_actor, _run), do: {:error, :stale}

  defp local_repository_conflict?(nil, _slug), do: false

  defp local_repository_conflict?(owner_id, slug) do
    Repo.exists?(
      from repository in ForgeRepos.Repository,
        where:
          repository.owner_user_id == ^owner_id and repository.slug == ^slug and
            is_nil(repository.deleted_at)
    )
  end

  defp exact_replacement_target(repository_id)
       when is_integer(repository_id) and repository_id > 0 do
    query =
      from repository in ForgeRepos.Repository,
        join: owner in User,
        on: owner.id == repository.owner_user_id,
        where:
          repository.id == ^repository_id and repository.lifecycle == :ready and
            is_nil(repository.deleted_at) and owner.state == :active and
            owner.kind in [:user, :organization],
        select: repository

    case query |> maybe_lock() |> Repo.one() do
      %ForgeRepos.Repository{} = repository -> {:ok, repository}
      nil -> {:error, :stale}
    end
  end

  defp exact_replacement_target(_repository_id), do: {:error, :stale}

  defp replacement_fingerprint_matches?(item, target) do
    item.replacement_repository_id == target.id and
      item.replacement_owner_id == target.owner_user_id and
      item.replacement_storage_path == target.storage_path and
      item.replacement_generation == target.generation and
      item.replacement_write_version == target.write_version and
      item.replacement_updated_at == target.updated_at and
      item.replacement_last_pushed_at == target.last_pushed_at and
      item.destination_owner_id == target.owner_user_id and item.destination_slug == target.slug
  end

  defp unique_final_slugs(plans) do
    slugs =
      plans
      |> Enum.reject(&(&1.action == :skip))
      |> Enum.map(& &1.item.destination_slug)

    if length(slugs) == length(Enum.uniq(slugs)),
      do: :ok,
      else: {:error, :invalid_selection}
  end

  defp persist_frozen_plans(plans, now) do
    Enum.reduce_while(plans, {:ok, []}, fn plan, {:ok, frozen} ->
      item = plan.item
      attempt_number = item.attempt_count + 1
      terminal? = plan.action == :skip

      attempt_attrs = %{
        repository_item_id: item.id,
        attempt_number: attempt_number,
        state: if(terminal?, do: :completed, else: :running),
        decision: plan.decision,
        started_at: now,
        terminal_at: if(terminal?, do: now)
      }

      with :ok <- ensure_plan_adoption_safe(plan.action, item),
           {:ok, _attempt} <-
             %ImportAttempt{}
             |> ImportAttempt.create_changeset(attempt_attrs)
             |> Repo.insert(),
           {:ok, updated_item} <-
             Persistence.update_without_lease(
               item,
               [:queued],
               RepositoryItem.freeze_attempt_changeset(item, plan.action, attempt_number),
               now
             ),
           {:ok, resumed_item} <- resume_frozen_item(updated_item, plan.action, now) do
        {:cont, {:ok, [resumed_item | frozen]}}
      else
        {:error, :cleanup_conflict} -> {:halt, {:error, :stale}}
        {:error, %Ecto.Changeset{}} -> {:halt, {:error, :stale}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, frozen} -> {:ok, Enum.reverse(frozen)}
      error -> error
    end
  end

  defp resume_frozen_item(item, :skip, _now), do: {:ok, item}

  defp resume_frozen_item(item, action, now) when action in [:create, :rename, :replace] do
    with {:ok, target} <- durable_resume_state(item) do
      if target == :queued do
        {:ok, item}
      else
        Persistence.update_without_lease(
          item,
          [:queued],
          RepositoryItem.frozen_resume_changeset(item, target),
          now
        )
      end
    end
  end

  defp ensure_plan_adoption_safe(:skip, _item), do: :ok

  defp ensure_plan_adoption_safe(_action, item),
    do: Persistence.ensure_adoption_safe_locked(Repo, item)

  defp durable_resume_state(%RepositoryItem{} = item) do
    case RepositoryPublisher.durable_proof_state(item) do
      {:ok, state} -> {:ok, state}
      {:error, :inconsistent} -> {:error, :stale}
    end
  end

  defp clean_create?(%RepositoryItem{
         state: :queued,
         wait_reason: nil,
         conflict_action: nil,
         replacement_repository_id: nil,
         replacement_owner_id: nil,
         replacement_storage_path: nil,
         replacement_generation: nil,
         replacement_write_version: nil,
         replacement_updated_at: nil,
         replacement_last_pushed_at: nil,
         destination_slug: slug
       }),
       do: ForgeRepos.Repository.canonical_slug?(slug)

  defp clean_create?(_item), do: false

  defp prelock_replacement_targets(items) do
    repository_ids =
      items
      |> Enum.filter(&(&1.conflict_action == :replace))
      |> Enum.map(& &1.replacement_repository_id)
      |> Enum.uniq()
      |> Enum.sort()

    if postgres?() and repository_ids != [] do
      locked_ids =
        ForgeRepos.Repository
        |> where([repository], repository.id in ^repository_ids)
        |> order_by([repository], asc: repository.id)
        |> lock("FOR UPDATE")
        |> select([repository], repository.id)
        |> Repo.all()

      if locked_ids == repository_ids, do: :ok, else: {:error, :stale}
    else
      :ok
    end
  end

  defp record_start_audits(audit, actor, run, plans, request_metadata) do
    counts = Enum.frequencies_by(plans, & &1.action)

    started_metadata = %{
      "repository_count" => length(plans),
      "queued_count" => length(plans) - Map.get(counts, :skip, 0),
      "skipped_count" => Map.get(counts, :skip, 0)
    }

    with :ok <- record_conflicts_frozen(audit, actor, run, plans, request_metadata),
         {:ok, _started_audit} <-
           audit.record(
             actor,
             "github_import.started",
             "github_import_run",
             run.id,
             started_metadata,
             request_metadata: request_metadata
           ) do
      :ok
    else
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp record_conflicts_frozen(audit, actor, run, plans, request_metadata) do
    counts = Enum.frequencies_by(plans, & &1.action)

    metadata = %{
      "repository_count" => length(plans),
      "create_count" => Map.get(counts, :create, 0),
      "skip_count" => Map.get(counts, :skip, 0),
      "rename_count" => Map.get(counts, :rename, 0),
      "replace_count" => Map.get(counts, :replace, 0)
    }

    case audit.record(
           actor,
           "github_import.conflicts_frozen",
           "github_import_run",
           run.id,
           metadata,
           request_metadata: request_metadata
         ) do
      {:ok, _audit} -> :ok
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp with_actor_run(actor, run_id, callback) do
    with {:ok, active_actor} <- locked_actor(actor),
         %ImportRun{} = run <- locked_run(active_actor.id, run_id) do
      callback.(active_actor, run, DateTime.utc_now(:second))
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked_actor(%User{id: actor_id}) do
    query =
      from user in User,
        where: user.id == ^actor_id and user.kind == :user and user.state == :active

    case query |> maybe_lock() |> Repo.one() do
      %User{} = actor -> {:ok, actor}
      nil -> {:error, :forbidden}
    end
  end

  defp locked_run(actor_id, run_id) do
    query =
      from run in ImportRun,
        where: run.id == ^run_id and run.actor_user_id == ^actor_id

    query |> maybe_lock() |> Repo.one()
  end

  defp run_items(run_id) do
    RepositoryItem
    |> where([item], item.import_run_id == ^run_id)
    |> order_by([item], asc: item.id)
    |> Repo.all()
  end

  defp active_lease?(%{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp active_lease?(_row, _now), do: false

  defp start_options(opts) when is_list(opts) do
    dispatch = Keyword.get(opts, :dispatch, :async)
    reconciler = Keyword.get(opts, :reconciler, Reconciler)
    audit = Keyword.get(opts, :audit, Audit)

    valid_dispatch? =
      dispatch in [:async, :manual] or
        (@allow_test_options and is_function(dispatch, 1))

    if valid_dispatch? and (is_atom(reconciler) or is_pid(reconciler)) and is_atom(audit) and
         Code.ensure_loaded?(audit) and function_exported?(audit, :record, 6) do
      {:ok, %{dispatch: dispatch, reconciler: reconciler, audit: audit}}
    else
      {:error, :invalid_selection}
    end
  end

  defp dispatch(_run_id, %{dispatch: :manual}), do: :ok

  defp dispatch(_run_id, %{dispatch: :async, reconciler: reconciler}) do
    Reconciler.kick(reconciler)
    :ok
  end

  defp dispatch(run_id, %{dispatch: dispatch}) when is_function(dispatch, 1) do
    case dispatch.(run_id) do
      :ok -> :ok
      _failure -> {:error, :recovery_unavailable}
    end
  rescue
    _error -> {:error, :recovery_unavailable}
  catch
    _kind, _reason -> {:error, :recovery_unavailable}
  end

  defp maybe_lock(query) do
    if postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp transact(callback) do
    transaction = fn ->
      Repo.transaction(fn ->
        case callback.() do
          {:ok, value} -> {:ok, value}
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
