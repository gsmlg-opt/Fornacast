defmodule ForgeImports.RepositoryPublisher do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts.User

  alias ForgeImports.{
    Conflicts,
    ImportAttempt,
    ImportRun,
    PageCheckpoint,
    Persistence,
    RepositoryItem
  }

  alias ForgeRepos.Repository
  alias Fornacast.{Audit, AuditEvent, Repo}

  @lease_seconds 60
  @retry_seconds 5
  @terminal_page_key "__terminal_v1__"
  @terminal_resources ~w(labels issues comments pull_requests number_sequence)
  @intent_keys ~w(version state attempt_number action hidden_repository_id operation_id request_metadata)
  @committed_keys @intent_keys ++
                    ~w(repository_id owner_user_id slug generation replaced_repository_id run_id published_count_after run_lock_version_after)
  @allowed_recovery_run_states [:running, :cancel_requested, :awaiting_credential]

  @type publication_error ::
          :metadata_not_ready
          | :busy
          | :destination_changed
          | :cancelled
          | :not_found
          | :publication_unavailable
          | :persistence_unavailable
          | :publication_inconsistent
          | :invalid_request_metadata

  @spec publish(term(), term(), term()) ::
          {:ok, %{repository: Repository.t(), replaced: Repository.t() | nil}}
          | {:error, publication_error()}
  def publish(actor, item_id, request_metadata) do
    with {:ok, safe_metadata} <- ForgeAccounts.validate_github_request_metadata(request_metadata) do
      safe_metadata = Map.delete(safe_metadata, "operation_id")

      case publication_scope(actor, item_id) do
        {:ok, %{state: state}} when state in [:published, :completed] ->
          replay(actor, item_id)

        {:ok, %{state: :publishing}} ->
          {:error, :busy}

        {:ok, _scope} ->
          with {:ok, capability} <- admit(actor, item_id, safe_metadata),
               :ok <- after_admission(capability) do
            finish(capability)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    _error -> {:error, :persistence_unavailable}
  end

  @doc false
  @spec recover(pos_integer()) ::
          {:ok, %{repository: Repository.t(), replaced: Repository.t() | nil}}
          | {:error, publication_error()}
  def recover(item_id) when is_integer(item_id) and item_id > 0 do
    with {:ok, capability} <- reclaim(item_id) do
      finish(capability)
    end
  rescue
    _error -> {:error, :persistence_unavailable}
  end

  def recover(_item_id), do: {:error, :not_found}

  if Mix.env() == :test do
    @after_admission_hook_key {__MODULE__, :after_admission_hook}
    @after_commit_hook_key {__MODULE__, :after_commit_hook}

    @doc false
    def with_test_after_admission_hook(hook, fun)
        when is_function(hook, 1) and is_function(fun, 0) do
      previous = Process.get(@after_admission_hook_key)
      Process.put(@after_admission_hook_key, hook)

      try do
        fun.()
      after
        if is_nil(previous),
          do: Process.delete(@after_admission_hook_key),
          else: Process.put(@after_admission_hook_key, previous)
      end
    end

    @doc false
    def with_test_after_commit_hook(hook, fun)
        when is_function(hook, 1) and is_function(fun, 0) do
      previous = Process.get(@after_commit_hook_key)
      Process.put(@after_commit_hook_key, hook)

      try do
        fun.()
      after
        if is_nil(previous),
          do: Process.delete(@after_commit_hook_key),
          else: Process.put(@after_commit_hook_key, previous)
      end
    end

    defp after_admission(capability) do
      case Process.get(@after_admission_hook_key) do
        hook when is_function(hook, 1) -> hook.(capability)
        nil -> :ok
      end
    end

    defp after_commit(result) do
      case Process.get(@after_commit_hook_key) do
        hook when is_function(hook, 1) -> hook.(result)
        nil -> :ok
      end
    end
  else
    defp after_admission(_capability), do: :ok
    defp after_commit(_result), do: :ok
  end

  defp publication_scope(%User{id: actor_id}, item_id)
       when is_integer(actor_id) and actor_id > 0 and is_integer(item_id) and item_id > 0 do
    with %User{} <-
           Repo.one(
             from actor in User,
               where: actor.id == ^actor_id and actor.kind == :user and actor.state == :active
           ),
         %{run_id: run_id} <-
           Repo.one(
             from item in RepositoryItem,
               join: run in ImportRun,
               on: run.id == item.import_run_id,
               where: item.id == ^item_id and run.actor_user_id == ^actor_id,
               select: %{run_id: run.id}
           ),
         %{id: ^item_id, state: state} <-
           Repo.one(
             from item in RepositoryItem,
               where: item.id == ^item_id and item.import_run_id == ^run_id,
               select: %{id: item.id, state: item.state}
           ) do
      {:ok, %{run_id: run_id, state: state}}
    else
      _masked -> {:error, :not_found}
    end
  end

  defp publication_scope(_actor, _item_id), do: {:error, :not_found}

  defp admit(%User{id: actor_id}, item_id, safe_metadata)
       when is_integer(actor_id) and actor_id > 0 and is_integer(item_id) and item_id > 0 do
    transaction = fn ->
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        with %User{} = actor <- locked_active_actor(actor_id),
             run_id when is_integer(run_id) <- actor_owned_run_id(actor.id, item_id),
             %ImportRun{} = run <- locked_run(run_id),
             %RepositoryItem{} = item <- locked_run_item(run.id, item_id),
             %ImportAttempt{} = attempt <- locked_current_attempt(item),
             :ok <- validate_fresh_run(run, now),
             :ok <- validate_publication_gate(actor, run, item, attempt, now),
             {:ok, intent} <- publication_intent(item, attempt, safe_metadata),
             {:ok, claimed} <- persist_intent(item, intent, now) do
          capability(actor, run, claimed, attempt, intent)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
          _invalid -> Repo.rollback(:not_found)
        end
      end)
    end

    map_transaction(Persistence.with_retry(transaction))
  rescue
    _error -> {:error, :persistence_unavailable}
  end

  defp admit(_actor, _item_id, _safe_metadata), do: {:error, :not_found}

  defp reclaim(item_id) do
    transaction = fn ->
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        with run_id when is_integer(run_id) <- item_run_id(item_id),
             actor_id when is_integer(actor_id) <- run_actor_id(run_id),
             %User{} = actor <- locked_persisted_actor(actor_id),
             %ImportRun{} = run <- locked_run(run_id),
             %RepositoryItem{} = item <- locked_run_item(run.id, item_id),
             %ImportAttempt{} = attempt <- locked_current_attempt(item),
             :ok <- validate_recovery_run(run),
             :ok <- validate_recovery_item(item, attempt, now),
             {:ok, claimed} <- persist_recovery_claim(item, now) do
          capability(actor, run, claimed, attempt, item.publication_evidence)
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
          _invalid -> Repo.rollback(:publication_inconsistent)
        end
      end)
    end

    map_transaction(Persistence.with_retry(transaction))
  rescue
    _error -> {:error, :persistence_unavailable}
  end

  defp finish(capability) do
    with {:ok, context} <- publication_context(capability) do
      result =
        case context.expected_replacement do
          nil -> commit_publication(context)
          expected -> fenced_replacement(context, expected)
        end

      settle_finish_result(result, context.capability)
    else
      {:error, :destination_changed} -> reopen_drift(capability)
      {:error, reason} -> settle_finish_result({:error, reason}, capability)
    end
  end

  defp fenced_replacement(context, expected) do
    target = %Repository{id: expected.repository_id, generation: expected.generation}

    case ForgeRepos.with_import_publication_fence(target, :content, fn _path, _remaining ->
           commit_publication(context)
         end) do
      {:error, :destination_changed} -> {:error, :destination_changed}
      {:error, {:unavailable, _reason}} -> {:error, :publication_unavailable}
      other -> other
    end
  end

  defp commit_publication(context) do
    transaction = fn -> Repo.transaction(publication_multi(context)) end

    case Persistence.with_retry(transaction) do
      {:ok, changes} ->
        repository_result = changes.repository

        {:ok, %{repository: repository_result.repository, replaced: repository_result.replaced}}

      {:error, step, :destination_changed, _changes}
      when step in [:repository, {:repository, :authorization}] ->
        {:error, :destination_changed}

      {:error, _step, :publication_unavailable, _changes} ->
        {:error, :publication_unavailable}

      {:error, _step, _reason, _changes} ->
        {:error, :persistence_unavailable}
    end
  rescue
    _error -> {:error, :persistence_unavailable}
  end

  defp publication_multi(context) do
    Multi.new()
    |> ForgeRepos.publish_import_shadow(
      :repository,
      context.capability.actor,
      context.publication_spec,
      context.expected_replacement
    )
    |> Multi.run(:run, fn repo, _changes -> update_run_count(repo, context) end)
    |> Multi.run(:item, fn repo, changes -> commit_item(repo, context, changes) end)
    |> Audit.record_multi(
      :audit,
      context.capability.actor,
      context.audit_action,
      "repository",
      fn %{repository: result} -> result.repository.id end,
      fn changes -> audit_metadata(context, changes) end,
      request_metadata: context.capability.intent["request_metadata"],
      operation_id: context.capability.intent["operation_id"]
    )
    |> Multi.run(:audit_verifier, fn repo, changes -> verify_audit(repo, context, changes) end)
  end

  defp update_run_count(repo, context) do
    capability = context.capability
    now = context.publication_spec.timestamp

    run =
      ImportRun
      |> where(
        [run],
        run.id == ^capability.run_id and run.actor_user_id == ^capability.actor.id and
          run.state in ^@allowed_recovery_run_states
      )
      |> publication_lock()
      |> repo.one()

    with %ImportRun{} = run <- run,
         {1, _rows} <-
           repo.update_all(
             from(candidate in ImportRun,
               where:
                 candidate.id == ^run.id and candidate.lock_version == ^run.lock_version and
                   candidate.state == ^run.state
             ),
             set: [updated_at: now],
             inc: [published_count: 1, lock_version: 1]
           ),
         %ImportRun{} = updated <-
           repo.get_by(ImportRun, id: run.id, lock_version: run.lock_version + 1) do
      {:ok, updated}
    else
      _stale -> {:error, :persistence_unavailable}
    end
  end

  defp commit_item(repo, context, %{repository: repository_result, run: updated_run}) do
    capability = context.capability
    now = context.publication_spec.timestamp

    item =
      RepositoryItem
      |> where(
        [item],
        item.id == ^capability.item_id and item.import_run_id == ^capability.run_id and
          item.lock_version == ^capability.item_lock_version and item.state == :publishing and
          item.lease_owner == ^capability.lease_owner and item.lease_expires_at > ^now
      )
      |> publication_lock()
      |> repo.one()

    attempt =
      ImportAttempt
      |> where(
        [attempt],
        attempt.repository_item_id == ^capability.item_id and
          attempt.attempt_number == ^capability.attempt_number and attempt.state == :running
      )
      |> publication_lock()
      |> repo.one()

    with %RepositoryItem{} = item <- item,
         true <- item.publication_evidence == capability.intent,
         %ImportAttempt{} = attempt <- attempt,
         evidence <- committed_evidence(capability.intent, repository_result, updated_run),
         :ok <- close_publication_attempt(repo, attempt, now),
         {:ok, published_item} <- publish_owned_item(repo, item, evidence, now) do
      {:ok, published_item}
    else
      _stale -> {:error, :persistence_unavailable}
    end
  end

  defp close_publication_attempt(repo, attempt, now) do
    case repo.update_all(
           from(candidate in ImportAttempt,
             where:
               candidate.id == ^attempt.id and
                 candidate.repository_item_id == ^attempt.repository_item_id and
                 candidate.attempt_number == ^attempt.attempt_number and
                 candidate.state == :running
           ),
           set: [state: :completed, terminal_at: now, failure_kind: nil, updated_at: now]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :persistence_unavailable}
    end
  end

  defp publish_owned_item(repo, item, evidence, now) do
    changeset = RepositoryItem.publication_commit_changeset(item, evidence)

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

      case repo.update_all(query, set: updates, inc: [lock_version: 1]) do
        {1, _rows} ->
          {:ok,
           changeset
           |> Ecto.Changeset.apply_changes()
           |> Map.put(:lock_version, item.lock_version + 1)
           |> Map.put(:updated_at, now)}

        {0, _rows} ->
          {:error, :persistence_unavailable}
      end
    else
      {:error, :persistence_unavailable}
    end
  end

  defp verify_audit(repo, context, %{repository: repository_result, run: run, audit: audit}) do
    expected_metadata = audit_metadata(context, %{repository: repository_result, run: run})
    operation_id = context.capability.intent["operation_id"]
    actor_id = context.capability.actor.id
    target_id = Integer.to_string(repository_result.repository.id)

    rows =
      repo.all(
        from event in AuditEvent,
          where: event.operation_id == ^operation_id and event.action == ^context.audit_action
      )

    case rows do
      [%AuditEvent{} = event] ->
        if event.id == audit.id and event.actor_user_id == actor_id and
             event.target_type == "repository" and event.target_id == target_id and
             event.metadata == expected_metadata and
             audit_request_fields_match?(event, context.capability.intent["request_metadata"]) do
          {:ok, event}
        else
          {:error, :persistence_unavailable}
        end

      _collision ->
        {:error, :persistence_unavailable}
    end
  end

  defp audit_metadata(context, %{repository: result, run: run}) do
    core = %{
      "item_id" => context.capability.item_id,
      "attempt_number" => context.capability.attempt_number,
      "run_id" => run.id,
      "published_count_after" => run.published_count,
      "run_lock_version_after" => run.lock_version,
      "new_repository_id" => result.repository.id
    }

    core =
      if result.replaced, do: Map.put(core, "old_repository_id", result.replaced.id), else: core

    Map.merge(core, context.capability.intent["request_metadata"])
  end

  defp committed_evidence(intent, result, run) do
    intent
    |> Map.put("state", "committed")
    |> Map.merge(%{
      "repository_id" => result.repository.id,
      "owner_user_id" => result.repository.owner_user_id,
      "slug" => result.repository.slug,
      "generation" => result.repository.generation,
      "replaced_repository_id" => result.replaced && result.replaced.id,
      "run_id" => run.id,
      "published_count_after" => run.published_count,
      "run_lock_version_after" => run.lock_version
    })
  end

  defp publication_context(capability) do
    case Repo.get(ImportRun, capability.run_id) do
      %ImportRun{state: state}
      when state in [:completed, :completed_with_warnings, :canceled, :failed] ->
        {:error, :publication_inconsistent}

      %ImportRun{} = run ->
        do_publication_context(capability, run)

      nil ->
        {:error, :destination_changed}
    end
  end

  defp do_publication_context(capability, run) do
    with true <- run.state in @allowed_recovery_run_states,
         %RepositoryItem{} = item <- Repo.get(RepositoryItem, capability.item_id),
         true <-
           item.state == :publishing and item.lease_owner == capability.lease_owner and
             item.lock_version == capability.item_lock_version and
             item.publication_evidence == capability.intent,
         %ImportAttempt{} = attempt <-
           Repo.get_by(ImportAttempt,
             repository_item_id: item.id,
             attempt_number: capability.attempt_number,
             state: :running
           ),
         {:ok, owner} <- destination_owner(run, item),
         {:ok, shadow} <- exact_shadow(item, attempt),
         {:ok, expected_replacement} <- expected_replacement(attempt),
         {:ok, settings} <- final_settings(item),
         generation <- publication_generation(expected_replacement),
         true <- is_integer(generation) and generation > 0 do
      timestamp = DateTime.utc_now(:second)
      capability = Map.put(capability, :run_lock_version, run.lock_version)

      publication_spec = %{
        hidden_repository_id: shadow.id,
        expected_internal_slug: shadow.slug,
        storage_path: shadow.storage_path,
        shadow_write_version: shadow.write_version,
        owner_user_id: owner.id,
        slug: attempt.decision["slug"],
        name: item.source_name,
        description: settings.description,
        visibility: item.destination_visibility,
        default_branch: settings.default_branch,
        has_issues: settings.has_issues,
        allow_merge_commit: settings.allow_merge_commit,
        generation: generation,
        timestamp: timestamp
      }

      {:ok,
       %{
         capability: capability,
         publication_spec: publication_spec,
         expected_replacement: expected_replacement,
         audit_action:
           if(expected_replacement, do: "repository.replaced", else: "repository.imported")
       }}
    else
      false -> {:error, :destination_changed}
      nil -> {:error, :destination_changed}
      {:error, reason} -> {:error, reason}
      _changed -> {:error, :destination_changed}
    end
  end

  defp destination_owner(run, item) do
    owner = Repo.get(User, item.destination_owner_id)

    cond do
      not match?(%User{state: :active}, owner) ->
        {:error, :destination_changed}

      run.destination_organization_id == nil and run.destination_organization_action == :existing and
        owner.id == run.actor_user_id and owner.kind == :user and
          owner.username == run.destination_organization_slug ->
        {:ok, owner}

      is_integer(run.destination_organization_id) and
        owner.id == run.destination_organization_id and owner.kind == :organization and
          owner.username == run.destination_organization_slug ->
        {:ok, owner}

      true ->
        {:error, :destination_changed}
    end
  end

  defp exact_shadow(item, _attempt) do
    case Repo.get(Repository, item.hidden_repository_id) do
      %Repository{} = shadow ->
        path = safe_absolute_storage_path(shadow)

        if shadow.owner_user_id == item.destination_owner_id and shadow.lifecycle == :importing and
             is_nil(shadow.deleted_at) and shadow.visibility == :private and
             shadow.write_version == 0 and
             shadow.generation > 0 and item.staged_storage_path == path and
             canonical_shadow?(shadow, item.id) do
          {:ok, shadow}
        else
          {:error, :destination_changed}
        end

      nil ->
        {:error, :destination_changed}
    end
  end

  defp canonical_shadow?(shadow, item_id) do
    Regex.match?(~r/\Aimport-#{item_id}-[0-9a-f]{24}\z/, shadow.slug) and
      shadow.name == "GitHub import #{item_id}" and shadow.description == nil and
      shadow.default_branch == "main" and shadow.has_issues == true and
      shadow.allow_merge_commit == true and is_nil(shadow.last_pushed_at)
  end

  defp expected_replacement(%ImportAttempt{decision: %{"action" => action}})
       when action in ["create", "rename"],
       do: {:ok, nil}

  defp expected_replacement(%ImportAttempt{decision: %{"action" => "replace"} = decision}) do
    with {:ok, updated_at} <- parse_timestamp(decision["replacement_updated_at"]),
         {:ok, last_pushed_at} <- parse_optional_timestamp(decision["replacement_last_pushed_at"]) do
      {:ok,
       %{
         repository_id: decision["replacement_repository_id"],
         owner_user_id: decision["replacement_owner_id"],
         slug: decision["slug"],
         storage_path: decision["replacement_storage_path"],
         generation: decision["replacement_generation"],
         write_version: decision["replacement_write_version"],
         updated_at: updated_at,
         last_pushed_at: last_pushed_at
       }}
    else
      _invalid -> {:error, :destination_changed}
    end
  end

  defp expected_replacement(_attempt), do: {:error, :destination_changed}

  defp final_settings(item) do
    source = item.source_metadata
    default_branch = item.source_git["default_branch"]

    if (is_nil(source["description"]) or is_binary(source["description"])) and
         is_binary(default_branch) and default_branch != "" and
         is_boolean(source["has_issues"]) and is_boolean(source["allow_merge_commit"]) and
         item.destination_visibility in [:private, :public] do
      {:ok,
       %{
         description: source["description"],
         default_branch: default_branch,
         has_issues: source["has_issues"],
         allow_merge_commit: source["allow_merge_commit"]
       }}
    else
      {:error, :destination_changed}
    end
  end

  defp validate_fresh_run(%ImportRun{state: :cancel_requested}, _now), do: {:error, :cancelled}

  defp validate_fresh_run(%ImportRun{state: :running} = run, now) do
    if live_lease?(run, now), do: {:error, :busy}, else: :ok
  end

  defp validate_fresh_run(_run, _now), do: {:error, :not_found}

  defp validate_publication_gate(actor, run, item, attempt, now) do
    cond do
      item.state in [:git_staged, :staging_metadata] ->
        {:error, :metadata_not_ready}

      item.state != :ready_to_publish or not item.selected or item.attempt_count <= 0 ->
        {:error, :not_found}

      live_lease?(item, now) ->
        {:error, :busy}

      not is_nil(item.cleanup_state) or not is_nil(item.cleanup_eligible_at) or
        not is_nil(item.cleanup_error) or item.cleanup_attempt_count != 0 or
          Map.has_key?(item.checkpoint || %{}, "cleanup_identity") ->
        {:error, :metadata_not_ready}

      attempt.state != :running or attempt.attempt_number != item.attempt_count ->
        {:error, :metadata_not_ready}

      run.actor_user_id != actor.id ->
        {:error, :not_found}

      not valid_git_proof?(item) ->
        {:error, :metadata_not_ready}

      not terminal_metadata?(item.id) ->
        {:error, :metadata_not_ready}

      true ->
        :ok
    end
  end

  defp valid_git_proof?(item) do
    source = item.source_git
    checkpoint = item.checkpoint

    with true <- checkpoint["git_staged"] == true,
         true <- checkpoint["unsupported_scan"] in ["complete", "truncated"],
         true <- is_boolean(source["empty"]),
         true <- is_binary(source["default_branch"]) and source["default_branch"] != "",
         true <- is_integer(source["refs"]) and source["refs"] >= 0,
         true <- is_integer(source["bytes"]) and source["bytes"] >= 0,
         true <- is_boolean(source["lfs_detected"]),
         true <- is_boolean(source["submodules_detected"]),
         true <- is_boolean(source["scan_truncated"]),
         %Repository{} = shadow <- Repo.get(Repository, item.hidden_repository_id),
         true <- shadow.lifecycle == :importing and is_nil(shadow.deleted_at),
         true <- shadow.owner_user_id == item.destination_owner_id,
         true <- shadow.visibility == :private and shadow.write_version == 0,
         true <- shadow.generation > 0 and canonical_shadow?(shadow, item.id),
         true <- safe_absolute_storage_path(shadow) == item.staged_storage_path do
      true
    else
      _invalid -> false
    end
  end

  defp terminal_metadata?(item_id) do
    rows =
      Repo.all(
        from checkpoint in PageCheckpoint,
          where:
            checkpoint.repository_item_id == ^item_id and
              checkpoint.page_key == ^@terminal_page_key,
          select: {checkpoint.resource_kind, checkpoint.committed_at}
      )

    length(rows) == length(@terminal_resources) and
      Enum.sort(Enum.map(rows, &elem(&1, 0))) == Enum.sort(@terminal_resources) and
      Enum.all?(rows, &match?({_kind, %DateTime{}}, &1))
  end

  defp publication_intent(item, attempt, safe_metadata) do
    action = attempt.decision["action"]

    if action in ["create", "rename", "replace"] do
      {:ok,
       %{
         "version" => 1,
         "state" => "intent",
         "attempt_number" => attempt.attempt_number,
         "action" => action,
         "hidden_repository_id" => item.hidden_repository_id,
         "operation_id" => "github-import-publication-#{item.id}-#{attempt.attempt_number}",
         "request_metadata" => safe_metadata
       }}
    else
      {:error, :metadata_not_ready}
    end
  end

  defp persist_intent(item, intent, now) do
    owner = lease_owner(item.id)
    expires_at = DateTime.add(now, @lease_seconds, :second)
    changeset = RepositoryItem.publication_intent_changeset(item, intent, owner, expires_at)

    if changeset.valid? do
      updates =
        changeset.changes
        |> Map.drop([:lock_version])
        |> Map.put(:updated_at, now)
        |> Map.to_list()

      query =
        from candidate in RepositoryItem,
          where:
            candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
              candidate.state == :ready_to_publish and candidate.selected == true and
              is_nil(candidate.cleanup_state) and
              (is_nil(candidate.lease_expires_at) or candidate.lease_expires_at <= ^now)

      case Repo.update_all(query, set: updates, inc: [lock_version: 1]) do
        {1, _rows} ->
          {:ok,
           changeset
           |> Ecto.Changeset.apply_changes()
           |> Map.put(:lock_version, item.lock_version + 1)
           |> Map.put(:updated_at, now)}

        {0, _rows} ->
          {:error, :busy}
      end
    else
      {:error, :metadata_not_ready}
    end
  end

  defp validate_recovery_run(%ImportRun{state: state}) when state in @allowed_recovery_run_states,
    do: :ok

  defp validate_recovery_run(%ImportRun{state: state})
       when state in [:completed, :completed_with_warnings, :canceled, :failed],
       do: {:error, :publication_inconsistent}

  defp validate_recovery_run(_run), do: {:error, :publication_inconsistent}

  defp validate_recovery_item(item, attempt, now) do
    intent = item.publication_evidence

    cond do
      item.state != :publishing or item.attempt_count != attempt.attempt_number or
          attempt.state != :running ->
        {:error, :publication_inconsistent}

      not valid_intent?(intent, item, attempt) ->
        {:error, :publication_inconsistent}

      live_lease?(item, now) ->
        {:error, :busy}

      not is_nil(item.next_attempt_at) and DateTime.compare(item.next_attempt_at, now) == :gt ->
        {:error, :busy}

      true ->
        :ok
    end
  end

  defp persist_recovery_claim(item, now) do
    owner = lease_owner(item.id)
    expires_at = DateTime.add(now, @lease_seconds, :second)

    query =
      from candidate in RepositoryItem,
        where:
          candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
            candidate.state == :publishing and
            (is_nil(candidate.lease_expires_at) or candidate.lease_expires_at <= ^now) and
            (is_nil(candidate.next_attempt_at) or candidate.next_attempt_at <= ^now)

    case Repo.update_all(query,
           set: [
             lease_owner: owner,
             lease_expires_at: expires_at,
             next_attempt_at: nil,
             updated_at: now
           ],
           inc: [lock_version: 1]
         ) do
      {1, _rows} ->
        {:ok,
         %{
           item
           | lease_owner: owner,
             lease_expires_at: expires_at,
             next_attempt_at: nil,
             lock_version: item.lock_version + 1,
             updated_at: now
         }}

      {0, _rows} ->
        {:error, :busy}
    end
  end

  defp valid_intent?(intent, item, attempt) do
    is_map(intent) and Enum.sort(Map.keys(intent)) == Enum.sort(@intent_keys) and
      intent["version"] == 1 and intent["state"] == "intent" and
      intent["attempt_number"] == attempt.attempt_number and
      intent["action"] == attempt.decision["action"] and
      intent["hidden_repository_id"] == item.hidden_repository_id and
      intent["operation_id"] ==
        "github-import-publication-#{item.id}-#{attempt.attempt_number}" and
      is_map(intent["request_metadata"]) and
      not Map.has_key?(intent["request_metadata"], "operation_id")
  end

  defp replay(actor, item_id) do
    with {:ok, %{run_id: run_id}} <- publication_scope(actor, item_id),
         %ImportRun{} = run <- Repo.get(ImportRun, run_id),
         %RepositoryItem{} = item <-
           Repo.get_by(RepositoryItem, id: item_id, import_run_id: run_id),
         true <- item.state in [:published, :completed],
         evidence when is_map(evidence) <- item.publication_evidence,
         true <- Enum.sort(Map.keys(evidence)) == Enum.sort(@committed_keys),
         true <- evidence["state"] == "committed" and evidence["version"] == 1,
         %ImportAttempt{} = attempt <-
           Repo.get_by(ImportAttempt,
             repository_item_id: item.id,
             attempt_number: evidence["attempt_number"],
             state: :completed
           ),
         true <- replay_intent_matches?(item, attempt, evidence),
         %Repository{} = repository <- Repo.get(Repository, evidence["repository_id"]),
         {:ok, replaced} <- replay_replacement(evidence, attempt),
         :ok <- verify_replay_repository(repository, item, attempt, evidence),
         :ok <- verify_replay_audit(actor, item, repository, replaced, evidence),
         true <- evidence["run_id"] == run.id,
         true <-
           run.published_count >= evidence["published_count_after"] and
             run.lock_version >= evidence["run_lock_version_after"] do
      {:ok, %{repository: repository, replaced: replaced}}
    else
      _corrupt -> {:error, :publication_inconsistent}
    end
  end

  defp replay_intent_matches?(item, attempt, evidence) do
    evidence["attempt_number"] == attempt.attempt_number and
      evidence["action"] == attempt.decision["action"] and
      evidence["hidden_repository_id"] == item.hidden_repository_id and
      evidence["operation_id"] ==
        "github-import-publication-#{item.id}-#{attempt.attempt_number}" and
      is_map(evidence["request_metadata"]) and
      not Map.has_key?(evidence["request_metadata"], "operation_id")
  end

  defp replay_replacement(%{"replaced_repository_id" => nil}, %ImportAttempt{
         decision: %{"action" => action}
       })
       when action in ["create", "rename"],
       do: {:ok, nil}

  defp replay_replacement(%{"replaced_repository_id" => id}, %ImportAttempt{
         decision:
           %{
             "action" => "replace",
             "replacement_repository_id" => id
           } = decision
       }) do
    with %Repository{lifecycle: :tombstoned, deleted_at: %DateTime{}} = repository <-
           Repo.get(Repository, id),
         {:ok, updated_at} <- parse_timestamp(decision["replacement_updated_at"]),
         {:ok, last_pushed_at} <-
           parse_optional_timestamp(decision["replacement_last_pushed_at"]),
         true <- repository.owner_user_id == decision["replacement_owner_id"],
         true <- repository.slug == decision["slug"],
         true <- repository.storage_path == decision["replacement_storage_path"],
         true <- repository.generation == decision["replacement_generation"],
         true <- repository.write_version == decision["replacement_write_version"],
         true <- repository.updated_at == updated_at,
         true <- repository.last_pushed_at == last_pushed_at do
      {:ok, repository}
    else
      _corrupt -> {:error, :publication_inconsistent}
    end
  end

  defp replay_replacement(_evidence, _attempt), do: {:error, :publication_inconsistent}

  defp verify_replay_repository(repository, item, attempt, evidence) do
    with {:ok, settings} <- final_settings(item),
         true <- repository.id == item.hidden_repository_id,
         true <- repository.id == evidence["repository_id"],
         true <- repository.owner_user_id == evidence["owner_user_id"],
         true <-
           repository.slug == evidence["slug"] and repository.slug == attempt.decision["slug"],
         true <- repository.generation == evidence["generation"],
         true <- repository.lifecycle == :ready and is_nil(repository.deleted_at),
         true <-
           repository.name == item.source_name and repository.description == settings.description,
         true <- repository.visibility == item.destination_visibility,
         true <- repository.default_branch == settings.default_branch,
         true <- repository.has_issues == settings.has_issues,
         true <- repository.allow_merge_commit == settings.allow_merge_commit do
      :ok
    else
      _corrupt -> {:error, :publication_inconsistent}
    end
  end

  defp verify_replay_audit(actor, item, repository, replaced, evidence) do
    action = if replaced, do: "repository.replaced", else: "repository.imported"

    core = %{
      "item_id" => item.id,
      "attempt_number" => evidence["attempt_number"],
      "run_id" => evidence["run_id"],
      "published_count_after" => evidence["published_count_after"],
      "run_lock_version_after" => evidence["run_lock_version_after"],
      "new_repository_id" => repository.id
    }

    core = if replaced, do: Map.put(core, "old_repository_id", replaced.id), else: core
    metadata = Map.merge(core, evidence["request_metadata"])
    actor_id = actor.id
    target_id = Integer.to_string(repository.id)

    case Repo.all(
           from event in AuditEvent,
             where: event.operation_id == ^evidence["operation_id"] and event.action == ^action
         ) do
      [%AuditEvent{} = event] ->
        if event.actor_user_id == actor_id and event.target_type == "repository" and
             event.target_id == target_id and event.metadata == metadata and
             audit_request_fields_match?(event, evidence["request_metadata"]) do
          :ok
        else
          {:error, :publication_inconsistent}
        end

      _corrupt ->
        {:error, :publication_inconsistent}
    end
  end

  defp audit_request_fields_match?(event, metadata) do
    event.request_id == metadata["request_id"] and
      event.ip_address == metadata["ip_address"] and
      event.user_agent == metadata["user_agent"]
  end

  defp settle_finish_result({:ok, result}, _capability) do
    :ok = after_commit(result)
    {:ok, result}
  end

  defp settle_finish_result({:error, :destination_changed}, capability),
    do: reopen_drift(capability)

  defp settle_finish_result({:error, :publication_unavailable}, capability) do
    case release_for_retry(capability) do
      :ok -> {:error, :publication_unavailable}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp settle_finish_result({:error, :persistence_unavailable}, capability) do
    _release = release_for_retry(capability)
    {:error, :persistence_unavailable}
  end

  defp settle_finish_result({:error, reason}, _capability), do: {:error, reason}

  defp reopen_drift(capability) do
    case Conflicts.reopen_publication(capability) do
      {:ok, _item} -> {:error, :destination_changed}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp release_for_retry(capability) do
    transaction = fn ->
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        query =
          from item in RepositoryItem,
            where:
              item.id == ^capability.item_id and item.state == :publishing and
                item.lock_version == ^capability.item_lock_version and
                item.lease_owner == ^capability.lease_owner

        case Repo.update_all(query,
               set: [
                 lease_owner: nil,
                 lease_expires_at: nil,
                 next_attempt_at: DateTime.add(now, @retry_seconds, :second),
                 updated_at: now
               ],
               inc: [lock_version: 1]
             ) do
          {1, _rows} ->
            :ok

          {0, _rows} ->
            Repo.rollback(:lost_lease)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, :ok} -> :ok
      _error -> {:error, :persistence_unavailable}
    end
  rescue
    _error -> {:error, :persistence_unavailable}
  end

  defp capability(actor, run, item, attempt, intent) do
    {:ok,
     %{
       actor: actor,
       actor_id: actor.id,
       run_id: run.id,
       run_lock_version: run.lock_version,
       item_id: item.id,
       item_lock_version: item.lock_version,
       attempt_number: attempt.attempt_number,
       lease_owner: item.lease_owner,
       operation_id: intent["operation_id"],
       intent: intent
     }}
  end

  defp locked_active_actor(actor_id) do
    User
    |> where([actor], actor.id == ^actor_id and actor.kind == :user and actor.state == :active)
    |> publication_lock()
    |> Repo.one()
  end

  defp locked_persisted_actor(actor_id) do
    User
    |> where([actor], actor.id == ^actor_id and actor.kind == :user)
    |> publication_lock()
    |> Repo.one()
  end

  defp actor_owned_run_id(actor_id, item_id) do
    Repo.one(
      from run in ImportRun,
        join: item in RepositoryItem,
        on: item.import_run_id == run.id,
        where: run.actor_user_id == ^actor_id and item.id == ^item_id,
        select: run.id
    )
  end

  defp locked_run(run_id) do
    ImportRun
    |> where([run], run.id == ^run_id)
    |> publication_lock()
    |> Repo.one()
  end

  defp locked_run_item(run_id, item_id) do
    RepositoryItem
    |> where([item], item.id == ^item_id and item.import_run_id == ^run_id)
    |> publication_lock()
    |> Repo.one()
  end

  defp item_run_id(item_id) do
    Repo.one(
      from item in RepositoryItem,
        where: item.id == ^item_id,
        select: item.import_run_id
    )
  end

  defp run_actor_id(run_id) do
    Repo.one(
      from run in ImportRun,
        where: run.id == ^run_id,
        select: run.actor_user_id
    )
  end

  defp locked_current_attempt(item) do
    ImportAttempt
    |> where(
      [attempt],
      attempt.repository_item_id == ^item.id and attempt.attempt_number == ^item.attempt_count
    )
    |> publication_lock()
    |> Repo.one()
  end

  defp publication_lock(query) do
    if postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  defp live_lease?(%{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp live_lease?(_record, _now), do: false

  defp lease_owner(item_id) do
    "github-import-publication-#{item_id}-" <>
      Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp publication_generation(nil), do: 1
  defp publication_generation(expected), do: expected.generation + 1

  defp parse_optional_timestamp(nil), do: {:ok, nil}
  defp parse_optional_timestamp(value), do: parse_timestamp(value)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      _invalid -> {:error, :invalid}
    end
  end

  defp parse_timestamp(_value), do: {:error, :invalid}

  defp safe_absolute_storage_path(repository) do
    ForgeRepos.absolute_storage_path(repository)
  rescue
    File.Error -> nil
    ArgumentError -> nil
  end

  defp map_transaction({:ok, {:ok, capability}}), do: {:ok, capability}
  defp map_transaction({:ok, capability}) when is_map(capability), do: {:ok, capability}
  defp map_transaction({:error, reason}), do: {:error, reason}
  defp map_transaction(_other), do: {:error, :persistence_unavailable}

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
