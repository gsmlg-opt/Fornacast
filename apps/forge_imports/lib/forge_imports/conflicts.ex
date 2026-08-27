defmodule ForgeImports.Conflicts do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{Namespace, User}

  alias ForgeImports.{
    ImportAttempt,
    ImportRun,
    PageCheckpoint,
    Persistence,
    Reconciler,
    RepositoryItem
  }

  alias Fornacast.{Audit, Repo}

  @allow_test_options Mix.env() == :test
  @max_id 9_223_372_036_854_775_807
  @max_decisions 10_000

  @spec resolve(User.t(), pos_integer(), map(), map()) ::
          {:ok, ForgeImports.RunView.t()} | {:error, atom()}
  def resolve(%User{} = actor, run_id, decisions, request_metadata)
      when is_integer(run_id) and run_id > 0 and is_map(request_metadata) do
    with {:ok, normalized_decisions} <- normalize_decisions(decisions),
         {:ok, safe_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, result} <-
           transact(fn ->
             resolve_transaction(actor, run_id, normalized_decisions, safe_metadata)
           end),
         :ok <- dispatch_resolution(result) do
      ForgeImports.get_run(actor, run_id)
    end
  end

  def resolve(_actor, _run_id, _decisions, _request_metadata),
    do: {:error, :invalid_selection}

  @spec start(User.t(), pos_integer(), map(), keyword()) ::
          {:ok, ForgeImports.RunView.t()} | {:error, atom()}
  def start(%User{} = actor, run_id, request_metadata, opts)
      when is_integer(run_id) and run_id > 0 and is_map(request_metadata) and is_list(opts) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, options} <- start_options(opts),
         {:ok, %{run: running}} <-
           transact(fn -> start_transaction(actor, run_id, safe_metadata, options) end),
         :ok <- dispatch(running.id, options) do
      ForgeImports.get_run(actor, run_id)
    end
  end

  def start(_actor, _run_id, _request_metadata, _opts), do: {:error, :invalid_selection}

  @spec destination_changed(
          User.t(),
          pos_integer(),
          pos_integer() | RepositoryItem.t(),
          map()
        ) ::
          {:ok, ForgeImports.RunView.t()} | {:error, atom()}
  def destination_changed(%User{} = actor, run_id, item_reference, request_metadata)
      when is_integer(run_id) and run_id > 0 and is_map(request_metadata) do
    with {:ok, item_id, capability} <- normalize_drift_item(item_reference),
         {:ok, _safe_metadata} <-
           ForgeAccounts.validate_github_request_metadata(request_metadata),
         {:ok, _updated} <-
           transact(fn ->
             destination_changed_transaction(actor, run_id, item_id, capability)
           end) do
      ForgeImports.get_run(actor, run_id)
    end
  end

  def destination_changed(_actor, _run_id, _item_id, _request_metadata),
    do: {:error, :invalid_selection}

  @doc false
  def reopen_publication(capability) when is_map(capability) do
    transaction = fn ->
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        with %User{} <- locked_persisted_actor(capability.actor_id),
             %ImportRun{} = run <- locked_publication_run(capability),
             %RepositoryItem{} = item <- locked_publication_item(capability),
             %ImportAttempt{} = attempt <- locked_publication_attempt(capability),
             true <- valid_publication_capability?(capability, item, attempt, now),
             {:ok, action} <- running_decision_action(attempt),
             {:ok, updated_run} <- touch_publication_run(run, now),
             :ok <- close_publication_attempt(attempt, now),
             {:ok, reopened} <- reopen_publication_item(item, action, now) do
          %{run: updated_run, item: reopened}
        else
          _stale -> Repo.rollback(:stale)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, %{item: item}} -> {:ok, item}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :persistence_unavailable}
  end

  def reopen_publication(_capability), do: {:error, :stale}

  defp resolve_transaction(actor, run_id, decisions, request_metadata) do
    with_actor_run(actor, run_id, fn active_actor, run, now ->
      with :ok <- resolvable_run(run, now),
           items <- run_items(run.id) do
        case run.state do
          :awaiting_resolution ->
            resolve_initial_plan(active_actor, run, items, decisions, now)

          :running ->
            resolve_running_items(
              active_actor,
              run,
              items,
              decisions,
              request_metadata,
              now
            )
        end
      end
    end)
  end

  defp resolve_initial_plan(actor, run, items, decisions, now) do
    with :ok <- validate_decision_items(items, decisions),
         {:ok, expanded_decisions} <- expand_similar_decisions(items, decisions),
         {:ok, planned_items} <- plan_items(actor, run, items, expanded_decisions),
         {:ok, _updated_items} <- persist_plans(planned_items, now),
         {:ok, updated_run} <- touch_run(run, [], now) do
      {:ok, %{run: updated_run, dispatch?: false}}
    end
  end

  defp resolve_running_items(actor, run, items, decisions, request_metadata, now) do
    with false <- map_size(decisions) == 0,
         {:ok, _explicit_items} <- running_resolution_candidates(items, decisions, now),
         candidates <-
           Enum.filter(items, &(&1.selected and &1.state == :awaiting_resolution)),
         {:ok, expanded_decisions} <- expand_similar_decisions(candidates, decisions),
         {:ok, targets} <- running_resolution_candidates(candidates, expanded_decisions, now),
         {:ok, planned_items} <- plan_items(actor, run, targets, expanded_decisions),
         :ok <- unique_resolution_slugs(items, planned_items),
         {:ok, resolved_items} <- persist_plans(planned_items, now),
         :ok <- prelock_replacement_targets(resolved_items),
         {:ok, frozen_plans} <- freeze_plans(actor, run, resolved_items),
         {:ok, frozen_items} <- persist_frozen_plans(frozen_plans, now),
         skip_count <- Enum.count(frozen_plans, &(&1.action == :skip)),
         {:ok, updated_run} <-
           touch_run(run, [skipped_count: run.skipped_count + skip_count], now),
         :ok <-
           record_conflicts_frozen(
             Audit,
             actor,
             updated_run,
             frozen_plans,
             request_metadata
           ) do
      {:ok, %{run: updated_run, items: frozen_items, dispatch?: true}}
    else
      true -> {:error, :invalid_selection}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_transaction(actor, run_id, request_metadata, options) do
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
           :ok <-
             record_start_audits(
               options.audit,
               active_actor,
               running,
               frozen_plans,
               request_metadata
             ) do
        {:ok, %{run: running, items: frozen_items}}
      end
    end)
  end

  defp destination_changed_transaction(actor, run_id, item_id, capability) do
    with_actor_run(actor, run_id, fn _active_actor, run, now ->
      with true <- run.state == :running,
           false <- active_lease?(run, now),
           {:ok, item} <- run_item(run.id, item_id),
           {:ok, drift_mode} <- validate_drift_capability(item, capability, now),
           true <- item.selected and item.attempt_count > 0,
           {:ok, attempt} <- running_attempt(item),
           {:ok, action} <- running_decision_action(attempt),
           {:ok, _closed_attempt} <-
             attempt
             |> ImportAttempt.transition_changeset(:destination_changed, %{
               terminal_at: now,
               failure_kind: "destination_changed"
             })
             |> Repo.update(),
           {:ok, updated_item} <- update_drift_item(item, action, drift_mode, now),
           {:ok, updated_run} <- touch_run(run, [], now) do
        {:ok, %{run: updated_run, item: updated_item}}
      else
        nil -> {:error, :not_found}
        true -> {:error, :stale}
        {:error, %Ecto.Changeset{}} -> {:error, :stale}
        {:error, reason} -> {:error, reason}
        _invalid -> {:error, :stale}
      end
    end)
  end

  defp startable_run(actor, %ImportRun{state: :awaiting_resolution} = run, now) do
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
           destination_organization_id: nil,
           destination_organization_slug: slug
         }
       ) do
    if slug == actor.username, do: :ok, else: {:error, :stale}
  end

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
        plan = %{item: item, decision: decision, action: action}
        {:cont, {:ok, [plan | plans]}}
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
    {:ok, replacement_decision(item), :replace}
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
    with :ok <- validate_destination_owner(actor, run, item.destination_owner_id),
         {:ok, target} <- exact_replacement_target(item.replacement_repository_id),
         :ok <- authorize_replacement(actor, target),
         true <- replacement_fingerprint_matches?(item, target),
         :ok <- guard_replacement_fingerprint(item) do
      :ok
    else
      false -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
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

  defp guard_replacement_fingerprint(item) do
    query =
      from repository in ForgeRepos.Repository,
        where:
          repository.id == ^item.replacement_repository_id and
            repository.owner_user_id == ^item.replacement_owner_id and
            repository.slug == ^item.destination_slug and
            repository.storage_path == ^item.replacement_storage_path and
            repository.generation == ^item.replacement_generation and
            repository.write_version == ^item.replacement_write_version and
            repository.updated_at == ^item.replacement_updated_at and
            repository.lifecycle == :ready and is_nil(repository.deleted_at)

    query =
      case item.replacement_last_pushed_at do
        nil -> where(query, [repository], is_nil(repository.last_pushed_at))
        pushed_at -> where(query, [repository], repository.last_pushed_at == ^pushed_at)
      end

    case Repo.update_all(query, set: [updated_at: item.replacement_updated_at]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :stale}
    end
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

      with {:ok, _attempt} <-
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

  defp durable_resume_state(%RepositoryItem{} = item) do
    hidden? = is_integer(item.hidden_repository_id) and item.hidden_repository_id > 0
    staged? = is_binary(item.staged_storage_path)
    git_evidence? = map_size(item.source_git || %{}) > 0 or map_size(item.checkpoint || %{}) > 0

    cond do
      not hidden? and not staged? and not git_evidence? ->
        {:ok, :queued}

      hidden? and staged? and reusable_git_proof?(item) ->
        if complete_terminal_metadata?(item.id),
          do: {:ok, :ready_to_publish},
          else: {:ok, :git_staged}

      true ->
        {:error, :stale}
    end
  end

  defp reusable_git_proof?(item) do
    checkpoint = item.checkpoint
    source = item.source_git

    with %ForgeRepos.Repository{} = shadow <-
           Repo.get(ForgeRepos.Repository, item.hidden_repository_id),
         true <- shadow.lifecycle == :importing and is_nil(shadow.deleted_at),
         true <- shadow.owner_user_id == item.destination_owner_id and shadow.write_version == 0,
         true <- ForgeRepos.absolute_storage_path(shadow) == item.staged_storage_path,
         true <- checkpoint["git_staged"] == true,
         true <- checkpoint["unsupported_scan"] in ["complete", "truncated"],
         true <- is_boolean(source["empty"]),
         true <- is_binary(source["default_branch"]) and source["default_branch"] != "",
         true <- is_integer(source["refs"]) and source["refs"] >= 0,
         true <- is_integer(source["bytes"]) and source["bytes"] >= 0,
         true <- is_boolean(source["lfs_detected"]),
         true <- is_boolean(source["submodules_detected"]),
         true <- is_boolean(source["scan_truncated"]) do
      true
    else
      _invalid -> false
    end
  rescue
    _error -> false
  end

  defp complete_terminal_metadata?(item_id) do
    resources = ~w(labels issues comments pull_requests number_sequence)

    rows =
      Repo.all(
        from checkpoint in PageCheckpoint,
          where:
            checkpoint.repository_item_id == ^item_id and
              checkpoint.page_key == "__terminal_v1__",
          select: {checkpoint.resource_kind, checkpoint.committed_at}
      )

    length(rows) == length(resources) and
      Enum.sort(Enum.map(rows, &elem(&1, 0))) == Enum.sort(resources) and
      Enum.all?(rows, &match?({_kind, %DateTime{}}, &1))
  end

  defp locked_persisted_actor(actor_id) do
    User
    |> where([actor], actor.id == ^actor_id and actor.kind == :user)
    |> maybe_lock()
    |> Repo.one()
  end

  defp locked_publication_run(capability) do
    ImportRun
    |> where(
      [run],
      run.id == ^capability.run_id and run.actor_user_id == ^capability.actor_id and
        run.lock_version == ^capability.run_lock_version and
        run.state in [:running, :cancel_requested, :awaiting_credential]
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp locked_publication_item(capability) do
    RepositoryItem
    |> where(
      [item],
      item.id == ^capability.item_id and item.import_run_id == ^capability.run_id and
        item.lock_version == ^capability.item_lock_version and item.state == :publishing and
        item.lease_owner == ^capability.lease_owner
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp locked_publication_attempt(capability) do
    ImportAttempt
    |> where(
      [attempt],
      attempt.repository_item_id == ^capability.item_id and
        attempt.attempt_number == ^capability.attempt_number and attempt.state == :running
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp valid_publication_capability?(capability, item, attempt, now) do
    (item.lease_expires_at && DateTime.compare(item.lease_expires_at, now) == :gt) and
      item.publication_evidence == capability.intent and
      capability.operation_id == capability.intent["operation_id"] and
      capability.attempt_number == attempt.attempt_number and
      capability.intent["attempt_number"] == attempt.attempt_number and
      capability.intent["action"] == attempt.decision["action"]
  end

  defp touch_publication_run(run, now) do
    case Repo.update_all(
           from(candidate in ImportRun,
             where:
               candidate.id == ^run.id and candidate.lock_version == ^run.lock_version and
                 candidate.state == ^run.state
           ),
           set: [updated_at: now],
           inc: [lock_version: 1]
         ) do
      {1, _rows} -> {:ok, %{run | lock_version: run.lock_version + 1, updated_at: now}}
      {0, _rows} -> {:error, :stale}
    end
  end

  defp reopen_publication_item(item, action, now) do
    changeset = RepositoryItem.destination_drift_changeset(item, action)

    if changeset.valid? do
      updates =
        changeset.changes
        |> Map.drop([:lock_version])
        |> Map.put(:updated_at, now)
        |> Map.to_list()

      query =
        from candidate in RepositoryItem,
          where:
            candidate.id == ^item.id and candidate.import_run_id == ^item.import_run_id and
              candidate.lock_version == ^item.lock_version and candidate.state == :publishing and
              candidate.lease_owner == ^item.lease_owner and
              candidate.lease_expires_at == ^item.lease_expires_at and
              candidate.lease_expires_at > ^now

      case Repo.update_all(query, set: updates, inc: [lock_version: 1]) do
        {1, _rows} ->
          {:ok,
           changeset
           |> Ecto.Changeset.apply_changes()
           |> Map.put(:lock_version, item.lock_version + 1)
           |> Map.put(:updated_at, now)}

        {0, _rows} ->
          {:error, :stale}
      end
    else
      {:error, :stale}
    end
  end

  defp close_publication_attempt(attempt, now) do
    case Repo.update_all(
           from(candidate in ImportAttempt,
             where:
               candidate.id == ^attempt.id and
                 candidate.repository_item_id == ^attempt.repository_item_id and
                 candidate.attempt_number == ^attempt.attempt_number and
                 candidate.state == :running
           ),
           set: [
             state: :destination_changed,
             terminal_at: now,
             failure_kind: "destination_changed",
             updated_at: now
           ]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :stale}
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

  defp with_actor_run(actor, run_id, callback) when is_function(callback, 3) do
    with {:ok, active_actor} <- active_actor(actor),
         {:ok, run} <- actor_run(active_actor.id, run_id) do
      callback.(active_actor, run, DateTime.utc_now(:second))
    end
  end

  defp touch_run(run, changes, now) do
    Persistence.update_without_lease(
      run,
      [run.state],
      Ecto.Changeset.change(run, changes),
      now
    )
  end

  defp active_actor(%User{id: actor_id}) when is_integer(actor_id) and actor_id > 0 do
    query =
      from user in User,
        where: user.id == ^actor_id and user.kind == :user and user.state == :active

    case query |> maybe_lock() |> Repo.one() do
      %User{} = actor -> {:ok, actor}
      nil -> {:error, :forbidden}
    end
  end

  defp active_actor(_actor), do: {:error, :forbidden}

  defp actor_run(actor_id, run_id) do
    query =
      from run in ImportRun,
        where: run.id == ^run_id and run.actor_user_id == ^actor_id

    case query |> maybe_lock() |> Repo.one() do
      %ImportRun{} = run -> {:ok, run}
      nil -> {:error, :not_found}
    end
  end

  defp resolvable_run(%ImportRun{state: state} = run, now)
       when state in [:awaiting_resolution, :running] do
    if active_lease?(run, now), do: {:error, :busy}, else: :ok
  end

  defp resolvable_run(%ImportRun{}, _now), do: {:error, :stale}

  defp run_items(run_id) do
    RepositoryItem
    |> where([item], item.import_run_id == ^run_id)
    |> order_by([item], asc: item.id)
    |> maybe_lock()
    |> Repo.all()
  end

  defp run_item(run_id, item_id) do
    query =
      from item in RepositoryItem,
        where: item.id == ^item_id and item.import_run_id == ^run_id

    case query |> maybe_lock() |> Repo.one() do
      %RepositoryItem{} = item -> {:ok, item}
      nil -> {:error, :not_found}
    end
  end

  defp normalize_drift_item(item_id) when is_integer(item_id) and item_id in 1..@max_id,
    do: {:ok, item_id, nil}

  defp normalize_drift_item(
         %RepositoryItem{
           id: item_id,
           import_run_id: run_id,
           lock_version: lock_version,
           lease_owner: lease_owner,
           lease_expires_at: %DateTime{}
         } = capability
       )
       when is_integer(item_id) and item_id in 1..@max_id and is_integer(run_id) and run_id > 0 and
              is_integer(lock_version) and lock_version > 0 and is_binary(lease_owner) do
    if ForgeImports.SafeValue.safe_string?(lease_owner, 255,
         required?: true,
         classified?: true
       ),
       do: {:ok, item_id, capability},
       else: {:error, :invalid_selection}
  end

  defp normalize_drift_item(_item_reference), do: {:error, :invalid_selection}

  defp validate_drift_capability(item, nil, now) do
    cond do
      staging_owned?(item) -> {:error, :stale}
      active_lease?(item, now) -> {:error, :busy}
      true -> {:ok, :without_lease}
    end
  end

  defp validate_drift_capability(item, %RepositoryItem{} = capability, now) do
    cond do
      staging_owned?(item) -> {:error, :stale}
      capability.id != item.id -> {:error, :stale}
      capability.import_run_id != item.import_run_id -> {:error, :stale}
      capability.state != item.state -> {:error, :stale}
      capability.lock_version != item.lock_version -> {:error, :stale}
      capability.lease_owner != item.lease_owner -> {:error, :stale}
      not active_lease?(item, now) -> {:error, :stale}
      true -> {:ok, {:owned_lease, capability.lease_owner}}
    end
  end

  defp staging_owned?(item) do
    item.state == :staging_git or not is_nil(item.cleanup_state)
  end

  defp update_drift_item(item, action, :without_lease, now) do
    Persistence.update_without_lease(
      item,
      [item.state],
      RepositoryItem.destination_drift_changeset(item, action),
      now
    )
  end

  defp update_drift_item(item, action, {:owned_lease, lease_owner}, now) do
    changeset = RepositoryItem.destination_drift_changeset(item, action)

    if changeset.valid? do
      query =
        from candidate in RepositoryItem,
          where:
            candidate.id == ^item.id and candidate.import_run_id == ^item.import_run_id and
              candidate.lock_version == ^item.lock_version and candidate.state == ^item.state and
              candidate.lease_owner == ^lease_owner and candidate.lease_expires_at > ^now

      updates =
        changeset.changes
        |> Map.drop([:lock_version])
        |> Map.put(:updated_at, now)
        |> Map.to_list()

      case Repo.update_all(query, set: updates, inc: [lock_version: 1]) do
        {1, _rows} ->
          updated =
            changeset
            |> Ecto.Changeset.apply_changes()
            |> Map.put(:lock_version, item.lock_version + 1)
            |> Map.put(:updated_at, now)

          {:ok, updated}

        {0, _rows} ->
          {:error, :stale}
      end
    else
      {:error, :stale}
    end
  end

  defp running_attempt(item) do
    query =
      from attempt in ImportAttempt,
        where:
          attempt.repository_item_id == ^item.id and
            attempt.attempt_number == ^item.attempt_count and attempt.state == :running

    case query |> maybe_lock() |> Repo.one() do
      %ImportAttempt{} = attempt -> {:ok, attempt}
      nil -> {:error, :stale}
    end
  end

  defp running_decision_action(%ImportAttempt{decision: %{"action" => action}})
       when action in ["create", "rename", "replace"],
       do: {:ok, String.to_existing_atom(action)}

  defp running_decision_action(_attempt), do: {:error, :stale}

  defp validate_decision_items(items, decisions) do
    items_by_id = Map.new(items, &{&1.id, &1})

    if Enum.all?(decisions, fn {item_id, _decision} ->
         match?(%RepositoryItem{selected: true}, Map.get(items_by_id, item_id))
       end) do
      :ok
    else
      {:error, :invalid_selection}
    end
  end

  defp running_resolution_candidates(items, decisions, now) do
    items_by_id = Map.new(items, &{&1.id, &1})

    decisions
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn item_id, {:ok, candidates} ->
      case Map.get(items_by_id, item_id) do
        %RepositoryItem{selected: true, state: :awaiting_resolution} = item ->
          if active_lease?(item, now),
            do: {:halt, {:error, :busy}},
            else: {:cont, {:ok, [item | candidates]}}

        %RepositoryItem{} ->
          {:halt, {:error, :invalid_selection}}

        nil ->
          {:halt, {:error, :invalid_selection}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      error -> error
    end
  end

  defp unique_resolution_slugs(items, planned_items) do
    planned_by_id = Map.new(planned_items, fn {item, attrs} -> {item.id, attrs} end)

    slugs =
      items
      |> Enum.filter(& &1.selected)
      |> Enum.reject(fn item ->
        attrs = Map.get(planned_by_id, item.id, %{})
        Map.get(attrs, :conflict_action, item.conflict_action) == :skip or item.state == :skipped
      end)
      |> Enum.map(fn item ->
        planned_by_id
        |> Map.get(item.id, %{})
        |> Map.get(:destination_slug, item.destination_slug)
      end)

    if length(slugs) == length(Enum.uniq(slugs)),
      do: :ok,
      else: {:error, :invalid_selection}
  end

  defp expand_similar_decisions(items, decisions) do
    items_by_id = Map.new(items, &{&1.id, &1})

    decisions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, decisions}, fn
      {item_id, %{action: :skip, apply_to_similar: true}}, {:ok, expanded} ->
        seed = Map.fetch!(items_by_id, item_id)

        if seed.state == :awaiting_resolution and is_binary(seed.wait_reason) do
          similar =
            Enum.filter(items, fn item ->
              item.selected and item.destination_owner_id == seed.destination_owner_id and
                item.wait_reason == seed.wait_reason
            end)

          expanded =
            Enum.reduce(similar, expanded, fn item, acc ->
              Map.put_new(acc, item.id, %{action: :skip, apply_to_similar: false})
            end)

          {:cont, {:ok, expanded}}
        else
          {:halt, {:error, :invalid_selection}}
        end

      {_item_id, _decision}, {:ok, expanded} ->
        {:cont, {:ok, expanded}}
    end)
  end

  defp plan_items(actor, run, items, decisions) do
    items
    |> Enum.filter(& &1.selected)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, planned} ->
      case plan_item(actor, run, item, Map.get(decisions, item.id)) do
        {:ok, attrs} -> {:cont, {:ok, [{item, attrs} | planned]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, planned} -> {:ok, Enum.reverse(planned)}
      error -> error
    end
  end

  defp plan_item(_actor, _run, %RepositoryItem{} = item, decision)
       when decision in [nil, %{action: :create}] do
    if clean_create?(item) do
      {:ok, resolution_attrs(item.destination_slug, :create)}
    else
      {:error, :invalid_selection}
    end
  end

  defp plan_item(_actor, _run, %RepositoryItem{} = item, %{action: :skip}) do
    {:ok, resolution_attrs(item.destination_slug, :skip)}
  end

  defp plan_item(actor, run, %RepositoryItem{} = item, %{action: :rename, slug: slug}) do
    with true <- ForgeRepos.Repository.canonical_slug?(slug),
         :ok <- validate_destination_owner(actor, run, item.destination_owner_id),
         false <- local_repository_conflict?(item.destination_owner_id, slug) do
      {:ok, resolution_attrs(slug, :rename)}
    else
      false -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plan_item(
         actor,
         run,
         %RepositoryItem{} = item,
         %{action: :replace, confirmation: confirmation}
       ) do
    with :ok <- validate_destination_owner(actor, run, item.destination_owner_id),
         true <- ForgeRepos.Repository.canonical_slug?(item.destination_slug),
         {:ok, target, owner} <- replacement_target(item),
         :ok <- authorize_replacement(actor, target),
         true <- confirmation == "#{owner.username}/#{target.slug}" do
      {:ok,
       resolution_attrs(
         target.slug,
         :replace,
         replacement_attrs(target)
       )}
    else
      false -> {:error, :invalid_selection}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plan_item(_actor, _run, _item, _decision), do: {:error, :invalid_selection}

  defp resolution_attrs(slug, action, fingerprint \\ %{}) do
    cleared_fingerprint()
    |> Map.merge(fingerprint)
    |> Map.merge(%{
      destination_slug: slug,
      conflict_action: if(action == :create, do: nil, else: action),
      state: :queued,
      wait_reason: nil
    })
  end

  defp cleared_fingerprint do
    %{
      replacement_repository_id: nil,
      replacement_owner_id: nil,
      replacement_storage_path: nil,
      replacement_generation: nil,
      replacement_write_version: nil,
      replacement_updated_at: nil,
      replacement_last_pushed_at: nil
    }
  end

  defp replacement_attrs(repository) do
    %{
      replacement_repository_id: repository.id,
      replacement_owner_id: repository.owner_user_id,
      replacement_storage_path: repository.storage_path,
      replacement_generation: repository.generation,
      replacement_write_version: repository.write_version,
      replacement_updated_at: repository.updated_at,
      replacement_last_pushed_at: repository.last_pushed_at
    }
  end

  defp replacement_decision(item) do
    %{
      "action" => "replace",
      "slug" => item.destination_slug,
      "replacement_repository_id" => item.replacement_repository_id,
      "replacement_owner_id" => item.replacement_owner_id,
      "replacement_storage_path" => item.replacement_storage_path,
      "replacement_generation" => item.replacement_generation,
      "replacement_write_version" => item.replacement_write_version,
      "replacement_updated_at" => item.replacement_updated_at,
      "replacement_last_pushed_at" => item.replacement_last_pushed_at
    }
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
           destination_organization_id: nil,
           destination_organization_slug: slug
         }
       ) do
    if slug == actor.username, do: {:ok, actor.id}, else: {:error, :stale}
  end

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
      %User{} -> {:ok, organization_id}
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

  defp replacement_target(%RepositoryItem{
         destination_owner_id: owner_id,
         destination_slug: slug
       })
       when is_integer(owner_id) and is_binary(slug) do
    query =
      from repository in ForgeRepos.Repository,
        join: owner in User,
        on: owner.id == repository.owner_user_id,
        where:
          repository.owner_user_id == ^owner_id and repository.slug == ^slug and
            repository.lifecycle == :ready and is_nil(repository.deleted_at) and
            owner.state == :active and owner.kind in [:user, :organization],
        select: {repository, owner}

    case Repo.one(query) do
      {%ForgeRepos.Repository{} = repository, %User{} = owner} ->
        {:ok, repository, owner}

      nil ->
        {:error, :stale}
    end
  end

  defp replacement_target(_item), do: {:error, :stale}

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

  defp authorize_replacement(actor, repository) do
    case Fornacast.Access.authorize(actor, :repository_admin, repository) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, :not_found}
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

  defp persist_plans(planned_items, now) do
    Enum.reduce_while(planned_items, {:ok, []}, fn {item, attrs}, {:ok, updated_items} ->
      changeset = RepositoryItem.conflict_resolution_changeset(item, attrs)

      case Persistence.update_without_lease(item, [item.state], changeset, now) do
        {:ok, updated} -> {:cont, {:ok, [updated | updated_items]}}
        {:error, %Ecto.Changeset{}} -> {:halt, {:error, :invalid_selection}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, updated_items} -> {:ok, Enum.reverse(updated_items)}
      error -> error
    end
  end

  defp normalize_decisions(decisions)
       when is_map(decisions) and map_size(decisions) <= @max_decisions do
    decisions
    |> Map.to_list()
    |> Enum.reduce_while({:ok, %{}}, fn {raw_id, raw_decision}, {:ok, normalized} ->
      with {:ok, item_id} <- normalize_id(raw_id),
           false <- Map.has_key?(normalized, item_id),
           {:ok, decision} <- normalize_decision(raw_decision) do
        {:cont, {:ok, Map.put(normalized, item_id, decision)}}
      else
        _invalid -> {:halt, {:error, :invalid_selection}}
      end
    end)
  end

  defp normalize_decisions(_decisions), do: {:error, :invalid_selection}

  defp normalize_decision(decision) when is_map(decision) do
    with {:ok, fields} <- normalize_fields(decision),
         {:ok, action} <- normalize_action(Map.get(fields, :action)),
         {:ok, normalized} <- normalize_action_fields(action, fields) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_selection}
    end
  end

  defp normalize_decision(_decision), do: {:error, :invalid_selection}

  defp normalize_action_fields(:create, %{action: _action} = fields) do
    if exact_fields?(fields, [:action]),
      do: {:ok, %{action: :create}},
      else: {:error, :invalid_selection}
  end

  defp normalize_action_fields(:skip, %{action: _action} = fields) do
    cond do
      exact_fields?(fields, [:action]) ->
        {:ok, %{action: :skip, apply_to_similar: false}}

      exact_fields?(fields, [:action, :apply_to_similar]) and
          Map.fetch!(fields, :apply_to_similar) in [true, "true"] ->
        {:ok, %{action: :skip, apply_to_similar: true}}

      true ->
        {:error, :invalid_selection}
    end
  end

  defp normalize_action_fields(:rename, %{action: _action, slug: slug} = fields) do
    if exact_fields?(fields, [:action, :slug]) and
         ForgeRepos.Repository.canonical_slug?(slug),
       do: {:ok, %{action: :rename, slug: slug}},
       else: {:error, :invalid_selection}
  end

  defp normalize_action_fields(
         :replace,
         %{action: _action, confirmation: confirmation} = fields
       ) do
    if exact_fields?(fields, [:action, :confirmation]) and is_binary(confirmation) and
         byte_size(confirmation) in 1..512 and String.valid?(confirmation) and
         :binary.match(confirmation, <<0>>) == :nomatch,
       do: {:ok, %{action: :replace, confirmation: confirmation}},
       else: {:error, :invalid_selection}
  end

  defp normalize_action_fields(_action, _fields), do: {:error, :invalid_selection}

  defp normalize_fields(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_field(raw_key),
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        _invalid -> {:halt, {:error, :invalid_selection}}
      end
    end)
  end

  defp normalize_field(:action), do: {:ok, :action}
  defp normalize_field("action"), do: {:ok, :action}
  defp normalize_field(:apply_to_similar), do: {:ok, :apply_to_similar}
  defp normalize_field("apply_to_similar"), do: {:ok, :apply_to_similar}
  defp normalize_field(:slug), do: {:ok, :slug}
  defp normalize_field("slug"), do: {:ok, :slug}
  defp normalize_field(:confirmation), do: {:ok, :confirmation}
  defp normalize_field("confirmation"), do: {:ok, :confirmation}
  defp normalize_field(_field), do: {:error, :invalid_selection}

  defp normalize_action(:create), do: {:ok, :create}
  defp normalize_action("create"), do: {:ok, :create}
  defp normalize_action(:skip), do: {:ok, :skip}
  defp normalize_action("skip"), do: {:ok, :skip}
  defp normalize_action(:rename), do: {:ok, :rename}
  defp normalize_action("rename"), do: {:ok, :rename}
  defp normalize_action(:replace), do: {:ok, :replace}
  defp normalize_action("replace"), do: {:ok, :replace}
  defp normalize_action(_action), do: {:error, :invalid_selection}

  defp normalize_id(id) when is_integer(id) and id in 1..@max_id, do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    with true <- String.valid?(id),
         true <- Regex.match?(~r/\A[1-9][0-9]{0,18}\z/, id),
         {parsed, ""} <- Integer.parse(id),
         true <- parsed <= @max_id do
      {:ok, parsed}
    else
      _invalid -> {:error, :invalid_selection}
    end
  end

  defp normalize_id(_id), do: {:error, :invalid_selection}

  defp exact_fields?(fields, expected),
    do: Map.keys(fields) |> Enum.sort() == Enum.sort(expected)

  defp active_lease?(%{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp active_lease?(_row, _now), do: false

  defp start_options(opts) do
    allowed =
      if @allow_test_options,
        do: [:audit, :dispatch, :reconciler],
        else: [:dispatch]

    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_selection}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :invalid_selection}

      Keyword.keys(opts) -- allowed != [] ->
        {:error, :invalid_selection}

      true ->
        build_start_options(opts)
    end
  end

  defp build_start_options(opts) do
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

  defp dispatch_resolution(%{dispatch?: false}), do: :ok

  defp dispatch_resolution(%{dispatch?: true}) do
    Reconciler.kick()
    :ok
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
