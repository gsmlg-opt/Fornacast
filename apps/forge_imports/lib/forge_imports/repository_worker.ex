defmodule ForgeImports.RepositoryWorker do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{
    GitHubCredentialVerification,
    GitHubIdentity,
    Organization,
    OrganizationMember,
    User
  }

  alias ForgeImports.{
    CleanupOperation,
    ImportAttempt,
    Cancellation,
    ImportRun,
    OneTimeCredential,
    Persistence,
    ReportEntry,
    RepositoryItem,
    RepositoryStager,
    Telemetry
  }

  alias ForgeImports.GitHub.{Client, MetadataImporter}
  alias ForgeRepos.Repository
  alias Fornacast.{Audit, AuditEvent, OperationLease, Repo}
  alias GitCore.Remote

  @default_lease_seconds 120
  @max_lease_seconds 2_400
  @post_remote_lease_seconds 10
  @retry_backoff_seconds 30
  @allow_test_options Mix.env() == :test

  if Mix.env() == :test do
    @after_claim_locks_hook_key {__MODULE__, :after_claim_locks_hook}
    @after_settlement_locks_hook_key {__MODULE__, :after_settlement_locks_hook}

    @doc false
    def with_test_after_claim_locks_hook(hook, fun)
        when is_function(hook, 0) and is_function(fun, 0) do
      previous = Process.get(@after_claim_locks_hook_key)
      Process.put(@after_claim_locks_hook_key, hook)

      try do
        fun.()
      after
        if previous == nil,
          do: Process.delete(@after_claim_locks_hook_key),
          else: Process.put(@after_claim_locks_hook_key, previous)
      end
    end

    defp after_claim_locks do
      case Process.get(@after_claim_locks_hook_key) do
        hook when is_function(hook, 0) -> hook.()
        nil -> :ok
      end
    end

    @doc false
    def with_test_after_settlement_locks_hook(hook, fun)
        when is_function(hook, 1) and is_function(fun, 0) do
      previous = Process.get(@after_settlement_locks_hook_key)
      Process.put(@after_settlement_locks_hook_key, hook)

      try do
        fun.()
      after
        if previous == nil,
          do: Process.delete(@after_settlement_locks_hook_key),
          else: Process.put(@after_settlement_locks_hook_key, previous)
      end
    end

    defp after_settlement_locks(phase) do
      case Process.get(@after_settlement_locks_hook_key) do
        hook when is_function(hook, 1) -> hook.(phase)
        nil -> :ok
      end
    end
  else
    defp after_claim_locks, do: :ok
    defp after_settlement_locks(_phase), do: :ok
  end

  @spec stage(pos_integer(), keyword()) ::
          {:ok, RepositoryItem.t() | :busy | :ignored} | {:error, atom()}
  def stage(repository_item_id, opts \\ [])

  def stage(repository_item_id, opts)
      when is_integer(repository_item_id) and repository_item_id > 0 and is_list(opts) do
    with {:ok, options} <- options(opts),
         {:ok, mode} <- preflight_mode(repository_item_id, options) do
      stage_in_mode(repository_item_id, options, mode)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def stage(_repository_item_id, _opts), do: {:error, :invalid_request}

  defp stage_in_mode(repository_item_id, options, :normal) do
    case activate_destination(repository_item_id) do
      :ok ->
        case claim_item(repository_item_id, options, :normal) do
          {:ok, capability} -> stage_claimed(capability, options, :normal)
          :busy -> {:ok, :busy}
          :ignored -> {:ok, :ignored}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        defer_activation_failure(repository_item_id, reason)
    end
  end

  defp stage_in_mode(repository_item_id, options, :recovery) do
    case claim_item(repository_item_id, options, :recovery) do
      {:ok, capability} ->
        case activate_destination(repository_item_id) do
          :ok -> stage_claimed(capability, options, :normal)
          {:error, reason} -> release_with_error(capability, reason)
        end

      :busy ->
        {:ok, :busy}

      :ignored ->
        {:ok, :ignored}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stage_in_mode(repository_item_id, options, :cleanup_only) do
    case claim_item(repository_item_id, options, :cleanup_only) do
      {:ok, capability} -> stage_claimed(capability, options, :cleanup_only)
      :busy -> {:ok, :busy}
      :ignored -> {:ok, :ignored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage_in_mode(repository_item_id, options, :metadata) do
    case claim_item(repository_item_id, options, :normal) do
      {:ok, capability} -> stage_metadata_claimed(capability, options)
      :busy -> {:ok, :busy}
      :ignored -> {:ok, :ignored}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage_claimed(%RepositoryItem{state: state} = capability, options, _mode)
       when state in [:git_staged, :staging_metadata] do
    stage_metadata_claimed(capability, options)
  end

  defp stage_claimed(capability, options, mode) do
    case RepositoryStager.ensure_shadow(capability) do
      {:ok, {current, shadow}} -> stage_shadow(current, shadow, options, mode)
      {:error, reason} -> release_with_error(capability, reason)
    end
  end

  defp stage_metadata_claimed(capability, options) do
    with {:ok, %{actor: actor, run: run, item: item}} <-
           current_context(capability.id, capability.lease_owner),
         false <- Cancellation.check(capability.id, capability.lease_owner),
         {:ok, item} <- ensure_staging_metadata(item, capability),
         :ok <-
           MetadataImporter.stage(
             item,
             &metadata_checkout(actor, run, item, &1, options),
             metadata_importer_options(item, options)
           ),
         {:ok, updated} <- persist_ready_to_publish(item) do
      {:ok, updated}
    else
      true -> persist_cancellation(capability)
      {:error, :cancelled} -> persist_cancellation(capability)
      {:error, reason} -> release_with_error(capability, reason)
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] ->
      release_with_error(capability, :persistence_unavailable)
  end

  defp metadata_checkout(actor, run, item, callback, options) do
    reference = make_ref()
    parent = self()

    checkout =
      case run.credential_source do
        :one_time ->
          OneTimeCredential.with_item_credential(
            actor,
            item,
            fn pat ->
              send(parent, {reference, callback.(pat)})
              :ok
            end,
            options.keyring
          )

        :saved ->
          ForgeAccounts.with_github_import_credential(
            actor,
            run.github_identity_id,
            run.github_credential_id,
            fn pat, verification ->
              result =
                if saved_reference_matches?(run, verification),
                  do: callback.(pat),
                  else: {:error, :credential_changed}

              send(parent, {reference, result})
              :ok
            end
          )
      end

    receive_metadata_result(checkout, reference)
  end

  defp metadata_importer_options(item, options) do
    [
      gate_key: {:one_time_run, item.import_run_id},
      client: Map.get(options, :client, Client),
      client_options: Map.get(options, :client_options, [])
    ]
  end

  defp ensure_staging_metadata(%RepositoryItem{state: :staging_metadata} = item, _capability),
    do: {:ok, item}

  defp ensure_staging_metadata(item, capability) do
    now = DateTime.utc_now(:second)

    query =
      from candidate in RepositoryItem,
        where:
          candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
            candidate.lease_owner == ^capability.lease_owner and candidate.lease_expires_at > ^now and
            candidate.state == :git_staged and is_nil(candidate.cleanup_state)

    case Repo.update_all(query,
           set: [state: :staging_metadata, updated_at: now],
           inc: [lock_version: 1]
         ) do
      {1, _rows} -> {:ok, Repo.get!(RepositoryItem, item.id)}
      {0, _rows} -> {:error, :lost_lease}
    end
  end

  defp persist_ready_to_publish(item) do
    now = DateTime.utc_now(:second)

    query =
      from candidate in RepositoryItem,
        where:
          candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
            candidate.lease_owner == ^item.lease_owner and candidate.lease_expires_at > ^now and
            candidate.state == :staging_metadata and is_nil(candidate.cleanup_state)

    case Repo.update_all(query,
           set: [
             state: :ready_to_publish,
             lease_owner: nil,
             lease_expires_at: nil,
             next_attempt_at: nil,
             wait_reason: nil,
             updated_at: now
           ],
           inc: [lock_version: 1]
         ) do
      {1, _rows} -> {:ok, Repo.get!(RepositoryItem, item.id)}
      {0, _rows} -> {:error, :lost_lease}
    end
  end

  defp stage_shadow(capability, shadow, options, mode) do
    case staging_action(shadow, options) do
      {:ok, :no_cleanup} when mode == :normal ->
        cond do
          completed_remote_cleanup?(capability.id) ->
            settle_post_cleanup_terminal(capability)

          git_work_allowed?(capability.id, capability.lease_owner) ->
            case choose_staging_action(shadow, ForgeRepos.absolute_storage_path(shadow)) do
              {:ok, action} ->
                handle_remote_result(
                  capability,
                  shadow,
                  checkout_credential(capability, shadow, action, options),
                  options
                )

              {:error, reason} ->
                release_with_error(capability, reason)
            end

          cancel_requested?(capability.import_run_id) ->
            persist_cancellation(capability)

          true ->
            release_with_error(capability, :not_runnable)
        end

      {:ok, :no_cleanup} ->
        release_with_error(capability, :unsafe_cleanup_state)

      {:cleanup_pending, evidence} ->
        handle_remote_result(capability, shadow, {:cleanup_pending, evidence}, options)

      {:error, reason} ->
        release_with_error(capability, reason)
    end
  end

  defp handle_remote_result(capability, _shadow, {:ok, %Remote.Result{} = result}, options),
    do: persist_success(capability, result, options)

  defp handle_remote_result(capability, shadow, {:cleanup_pending, evidence}, _options) do
    case persist_cleanup_pending(capability, shadow, evidence) do
      {:ok, _item} -> {:error, :cleanup_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_remote_result(capability, _shadow, {:error, :cancelled}, _options),
    do: persist_cancellation(capability)

  defp handle_remote_result(capability, _shadow, {:error, reason}, _options)
       when reason in [
              :invalid_credential,
              :credential_changed,
              :credential_service_unavailable,
              :not_found,
              :forbidden
            ] do
    pause_for_credential(capability, reason)
  end

  defp handle_remote_result(capability, _shadow, {:error, reason}, _options),
    do: release_with_error(capability, reason)

  defp preflight_mode(item_id, options) do
    case Repo.get(RepositoryItem, item_id) do
      %RepositoryItem{} = item -> preflight_item_mode(item, options)
      nil -> {:error, :not_found}
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] -> {:error, :persistence_unavailable}
  end

  defp preflight_item_mode(%RepositoryItem{state: :queued}, _options), do: {:ok, :normal}

  defp preflight_item_mode(
         %RepositoryItem{
           state: :staging_git,
           hidden_repository_id: hidden_repository_id,
           destination_owner_id: destination_owner_id,
           staged_storage_path: staged_storage_path
         },
         options
       ) do
    with {:ok, %Repository{} = shadow} <-
           ForgeRepos.fetch_importing_repository(hidden_repository_id),
         true <- shadow.owner_user_id == destination_owner_id,
         true <- ForgeRepos.absolute_storage_path(shadow) == staged_storage_path do
      case staging_action(shadow, options) do
        {:cleanup_pending, %Remote.CleanupPending{}} -> {:ok, :cleanup_only}
        _absent_or_unsafe -> {:ok, :recovery}
      end
    else
      _mismatch -> {:ok, :recovery}
    end
  rescue
    _error in [File.Error, ArgumentError] -> {:ok, :recovery}
  end

  defp preflight_item_mode(%RepositoryItem{state: :git_staged} = item, _options) do
    if metadata_ready_item?(item), do: {:ok, :metadata}, else: {:ok, :recovery}
  end

  defp preflight_item_mode(%RepositoryItem{state: :staging_metadata} = item, _options) do
    if metadata_ready_item?(item), do: {:ok, :metadata}, else: {:ok, :recovery}
  end

  defp preflight_item_mode(%RepositoryItem{}, _options), do: {:ok, :recovery}

  defp activate_destination(item_id) do
    with %RepositoryItem{} = item <- Repo.get(RepositoryItem, item_id),
         %ImportRun{} = run <- Repo.get(ImportRun, item.import_run_id) do
      case {run.source_kind, run.destination_organization_action} do
        {:organization, :new} ->
          activate_new_organization(run, item_id)

        _other_destination ->
          :ok
      end
    else
      nil -> {:error, :not_found}
    end
  end

  defp defer_activation_failure(item_id, reason) do
    classification = activation_failure_classification(reason)

    transaction = fn ->
      Repo.transaction(fn ->
        case Repo.get(RepositoryItem, item_id) do
          nil ->
            Repo.rollback(:not_found)

          %RepositoryItem{} = observed ->
            with %ImportRun{} = run <- locked_run(observed.import_run_id),
                 %RepositoryItem{} = item <- locked_item(item_id),
                 %ImportAttempt{} = attempt <- current_attempt(item),
                 now <- DateTime.utc_now(:second),
                 :ok <- activation_backoff_runnable?(run, item, attempt, now),
                 changeset <-
                   RepositoryItem.lease_update_changeset(item,
                     next_attempt_at: DateTime.add(now, @retry_backoff_seconds, :second),
                     failure_kind: Atom.to_string(classification),
                     failure_detail: nil
                   ),
                 {:ok, _updated} <-
                   Persistence.update_without_lease(item, [:queued], changeset, now),
                 :ok <- bump_run_after_retry(run, now) do
              :deferred
            else
              nil -> Repo.rollback(:not_found)
              {:error, reason} -> Repo.rollback(reason)
              _not_runnable -> Repo.rollback(:not_runnable)
            end
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, :deferred} -> {:error, classification}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :not_runnable} -> {:ok, :ignored}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] -> {:error, :persistence_unavailable}
  end

  defp activation_backoff_runnable?(run, item, attempt, now) do
    cond do
      run.state != :running -> {:error, :not_runnable}
      live_lease?(run, now) -> {:error, :not_runnable}
      item.import_run_id != run.id -> {:error, :not_runnable}
      item.state != :queued or not item.selected -> {:error, :not_runnable}
      item.attempt_count < 1 or attempt.state != :running -> {:error, :not_runnable}
      not due?(item, now) or live_lease?(item, now) -> {:error, :not_runnable}
      not fresh_item?(item) or not is_nil(item.cleanup_state) -> {:error, :not_runnable}
      true -> :ok
    end
  end

  defp activation_failure_classification(reason)
       when reason in [:destination_changed, :not_found, :persistence_unavailable],
       do: reason

  defp activation_failure_classification(_reason), do: :staging_unavailable

  defp activate_new_organization(expected_run, item_id) do
    transaction = fn ->
      Repo.transaction(fn ->
        with %User{} = actor <- locked_actor(expected_run.actor_user_id),
             %ImportRun{} = run <- locked_run(expected_run.id),
             :ok <- activatable_organization_run(actor, run) do
          activate_or_replay_current_organization(actor, run, item_id)
        else
          nil -> Repo.rollback(:not_found)
          false -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, :activated} -> :ok
      {:ok, :replayed} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, :destination_changed} -> {:error, :destination_changed}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  rescue
    _error in Turso.Error -> {:error, :persistence_unavailable}
  end

  defp activate_or_replay_current_organization(
         actor,
         %ImportRun{destination_organization_id: nil} = run,
         item_id
       ) do
    items = locked_run_items(run.id)

    if items != [] and Enum.any?(items, &(&1.id == item_id)),
      do: activate_or_replay_organization(actor, run, items),
      else: Repo.rollback(:not_found)
  end

  defp activate_or_replay_current_organization(actor, %ImportRun{} = run, item_id) do
    case locked_item(item_id) do
      %RepositoryItem{import_run_id: run_id, destination_owner_id: organization_id} = item
      when run_id == run.id and organization_id == run.destination_organization_id ->
        activate_or_replay_organization(actor, run, [item])

      _missing_or_drifted ->
        Repo.rollback(:destination_changed)
    end
  end

  defp locked_run_items(run_id) do
    RepositoryItem
    |> where([item], item.import_run_id == ^run_id)
    |> order_by([item], asc: item.id)
    |> maybe_lock()
    |> Repo.all()
  end

  defp activatable_organization_run(actor, run) do
    cond do
      actor.kind != :user or actor.state != :active -> {:error, :destination_changed}
      run.actor_user_id != actor.id -> {:error, :destination_changed}
      run.source_kind != :organization -> {:error, :destination_changed}
      run.destination_organization_action != :new -> {:error, :destination_changed}
      run.destination_organization_status != :clean -> {:error, :destination_changed}
      run.state != :running -> {:error, :destination_changed}
      live_lease?(run, DateTime.utc_now(:second)) -> {:error, :destination_changed}
      true -> :ok
    end
  end

  defp activate_or_replay_organization(
         actor,
         %ImportRun{destination_organization_id: nil} = run,
         items
       ) do
    attrs = organization_attrs(run)
    operation_id = organization_operation_id(run.id)

    organization_multi =
      Ecto.Multi.new()
      |> ForgeAccounts.github_import_organization_multi(
        :organization,
        actor,
        attrs,
        run.request_metadata,
        operation_id
      )

    case Repo.transaction(organization_multi) do
      {:ok, %{organization: organization}} ->
        with {:ok, updated_run} <- propagate_organization(run, items, organization.id),
             {:ok, _audit} <-
               Audit.record(
                 actor,
                 "github_import.organization_activated",
                 "organization",
                 organization.id,
                 %{"github_import_run_id" => run.id, "result" => "success"},
                 request_metadata: run.request_metadata,
                 operation_id: operation_id
               ),
             true <- updated_run.destination_organization_id == organization.id,
             fresh_items <- locked_run_items(run.id),
             true <- exact_organization_replay?(actor, updated_run, fresh_items) do
          :activated
        else
          _failure -> Repo.rollback(:destination_changed)
        end

      {:error, _step, _reason, _changes} ->
        Repo.rollback(:destination_changed)
    end
  end

  defp activate_or_replay_organization(actor, %ImportRun{} = run, items) do
    if exact_organization_replay?(actor, run, items),
      do: :replayed,
      else: Repo.rollback(:destination_changed)
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

  defp exact_organization_replay?(actor, run, items) do
    organization_id = run.destination_organization_id
    operation_id = organization_operation_id(run.id)

    organization =
      Repo.get_by(Organization,
        id: organization_id,
        username: run.destination_organization_slug,
        kind: :organization,
        state: :active
      )

    memberships =
      OrganizationMember
      |> where([member], member.organization_id == ^organization_id)
      |> limit(2)
      |> Repo.all()

    audits =
      AuditEvent
      |> where([audit], audit.operation_id == ^operation_id)
      |> order_by([audit], asc: audit.action)
      |> limit(3)
      |> Repo.all()

    match?(%Organization{}, organization) and
      match?(
        [%OrganizationMember{user_id: actor_id, role: :owner}] when actor_id == actor.id,
        memberships
      ) and
      Enum.all?(items, &(&1.destination_owner_id == organization_id)) and
      exact_activation_audits?(audits, actor.id, organization_id)
  end

  defp exact_activation_audits?(audits, actor_id, organization_id) do
    target_id = Integer.to_string(organization_id)

    Enum.map(audits, & &1.action) == [
      "github_import.organization_activated",
      "organization.created"
    ] and
      Enum.all?(audits, fn audit ->
        audit.actor_user_id == actor_id and audit.target_type == "organization" and
          audit.target_id == target_id
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

  defp claim_item(item_id, options, mode) do
    transaction = fn ->
      Repo.transaction(fn -> claim_item_transaction(item_id, options, mode) end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, %RepositoryItem{} = item} -> {:ok, item}
      {:error, :busy} -> :busy
      {:error, :not_runnable} -> :ignored
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  rescue
    _error in Turso.Error -> {:error, :persistence_unavailable}
  end

  defp claim_item_transaction(item_id, options, mode) do
    case Repo.get(RepositoryItem, item_id) do
      nil ->
        Repo.rollback(:not_found)

      %RepositoryItem{} = observed ->
        with %ImportRun{} = observed_run <- Repo.get(ImportRun, observed.import_run_id),
             %User{} = actor <- locked_actor(observed_run.actor_user_id),
             %ImportRun{} = run <- locked_run(observed_run.id),
             %RepositoryItem{} = item <- locked_item(item_id),
             %ImportAttempt{} = attempt <- current_attempt(item),
             :ok <- after_claim_locks(),
             now <- DateTime.utc_now(:second),
             :ok <- runnable?(actor, run, item, attempt, now, mode),
             {:ok, claimed} <-
               claim_exact(item, options.owner, now, options.lease_seconds, mode) do
          claimed
        else
          :busy -> Repo.rollback(:busy)
          _not_runnable -> Repo.rollback(:not_runnable)
        end
    end
  end

  defp locked_run(run_id) do
    ImportRun
    |> where([run], run.id == ^run_id)
    |> maybe_lock()
    |> Repo.one()
  end

  defp locked_actor(actor_id) do
    User
    |> where([actor], actor.id == ^actor_id)
    |> maybe_lock()
    |> Repo.one()
  end

  defp locked_item(item_id) do
    RepositoryItem
    |> where([item], item.id == ^item_id)
    |> maybe_lock()
    |> Repo.one()
  end

  defp current_attempt(item) do
    ImportAttempt
    |> where(
      [attempt],
      attempt.repository_item_id == ^item.id and
        attempt.attempt_number == ^item.attempt_count
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp runnable?(actor, run, item, attempt, now, mode) do
    cleanup_recovery? =
      item.state == :staging_git and
        run.state in [
          :running,
          :cancel_requested,
          :canceled,
          :failed,
          :completed,
          :completed_with_warnings
        ] and (run.state != :running or actor.state != :active)

    cond do
      actor.kind != :user ->
        {:error, :not_runnable}

      not cleanup_recovery? and actor.state != :active ->
        {:error, :not_runnable}

      run.state != :running and not cleanup_recovery? ->
        {:error, :not_runnable}

      not cleanup_recovery? and live_lease?(run, now) ->
        {:error, :not_runnable}

      not cleanup_recovery? and attempt.state != :running ->
        {:error, :not_runnable}

      item.import_run_id != run.id ->
        {:error, :not_runnable}

      not item.selected ->
        {:error, :not_runnable}

      item.state not in [:queued, :staging_git, :git_staged, :staging_metadata] ->
        {:error, :not_runnable}

      item.attempt_count < 1 ->
        {:error, :not_runnable}

      mode != :cleanup_only and not due?(item, now) ->
        {:error, :not_runnable}

      not is_nil(item.cleanup_state) ->
        {:error, :not_runnable}

      live_lease?(item, now) ->
        :busy

      item.state == :queued and not fresh_item?(item) ->
        {:error, :not_runnable}

      item.state == :staging_git and not staged_item?(item) ->
        {:error, :not_runnable}

      item.state in [:git_staged, :staging_metadata] and not metadata_ready_item?(item) ->
        {:error, :not_runnable}

      true ->
        :ok
    end
  end

  defp claim_exact(item, owner, now, lease_seconds, mode) do
    expires_at = DateTime.add(now, lease_seconds, :second)

    query =
      from candidate in RepositoryItem,
        where:
          candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
            candidate.selected == true and candidate.state == ^item.state and
            is_nil(candidate.cleanup_state) and
            (is_nil(candidate.lease_expires_at) or candidate.lease_expires_at <= ^now)

    query =
      if mode == :cleanup_only,
        do: query,
        else:
          where(
            query,
            [candidate],
            is_nil(candidate.next_attempt_at) or candidate.next_attempt_at <= ^now
          )

    case Repo.update_all(query,
           set: [lease_owner: owner, lease_expires_at: expires_at],
           inc: [lock_version: 1]
         ) do
      {1, _rows} ->
        case Repo.get_by(RepositoryItem,
               id: item.id,
               lock_version: item.lock_version + 1,
               lease_owner: owner
             ) do
          %RepositoryItem{} = claimed -> {:ok, claimed}
          nil -> {:error, :lost_lease}
        end

      {0, _rows} ->
        :busy
    end
  end

  defp staging_action(%Repository{} = shadow, options) do
    destination = ForgeRepos.absolute_storage_path(shadow)

    case options.remote.cleanup_evidence(destination) do
      {:ok, %Remote.CleanupPending{} = evidence} ->
        {:cleanup_pending, evidence}

      {:error, %Remote.Error{kind: :cleanup_not_found}} ->
        {:ok, :no_cleanup}

      {:error, :cleanup_not_found} ->
        {:ok, :no_cleanup}

      _unsafe ->
        {:error, :unsafe_cleanup_state}
    end
  rescue
    _error in [File.Error, ArgumentError] -> {:error, :storage_unavailable}
  end

  defp choose_staging_action(shadow, destination) do
    case File.lstat(destination) do
      {:error, :enoent} ->
        case RepositoryStager.ensure_parent(shadow) do
          :ok -> {:ok, :mirror}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{type: :directory, mode: mode}}
      when Bitwise.band(mode, 0o777) == 0o700 ->
        case GitCore.is_bare_repository?(destination) do
          {:ok, true} -> {:ok, :refresh}
          _ambiguous -> {:error, :ambiguous_staging}
        end

      _ambiguous ->
        {:error, :ambiguous_staging}
    end
  end

  defp checkout_credential(capability, shadow, action, options) do
    with {:ok, %{actor: actor, run: run, item: current}} <-
           current_context(capability.id, capability.lease_owner),
         {:ok, result} <- credential_result(actor, run, current, shadow, action, options) do
      {:ok, result}
    end
  end

  defp credential_result(
         actor,
         %ImportRun{credential_source: :one_time},
         item,
         shadow,
         action,
         options
       ) do
    reference = make_ref()
    parent = self()

    checkout =
      OneTimeCredential.with_item_credential(
        actor,
        item,
        fn pat ->
          result = invoke_remote_fresh(item, shadow, action, pat, options)
          send(parent, {reference, result})
          :ok
        end,
        options.keyring
      )

    receive_checkout_result(checkout, reference)
  end

  defp credential_result(
         actor,
         %ImportRun{credential_source: :saved} = run,
         item,
         shadow,
         action,
         options
       ) do
    reference = make_ref()
    parent = self()

    checkout =
      ForgeAccounts.with_github_import_credential(
        actor,
        run.github_identity_id,
        run.github_credential_id,
        fn pat, %GitHubCredentialVerification{} = verification ->
          result =
            if saved_reference_matches?(run, verification) do
              invoke_remote_fresh(item, shadow, action, pat, options)
            else
              {:error, :credential_changed}
            end

          send(parent, {reference, result})
          :ok
        end
      )

    receive_checkout_result(checkout, reference)
  end

  defp invoke_remote_fresh(item, shadow, action, pat, options) do
    with {:ok, %{item: current, identity: identity}} <-
           current_context(item.id, item.lease_owner),
         true <- current.hidden_repository_id == shadow.id do
      invoke_remote(current, request(current, shadow, identity), action, pat, options)
    else
      false -> {:error, :lost_lease}
      {:error, :cancelled} -> {:error, :cancelled}
      {:error, :lost_lease} -> {:error, :lost_lease}
    end
  end

  defp receive_checkout_result({:ok, :acknowledged}, reference) do
    receive do
      {^reference, result} -> normalize_remote_result(result)
    after
      0 -> {:error, :credential_service_unavailable}
    end
  end

  defp receive_checkout_result({:ok, :ok}, reference),
    do: receive_checkout_result({:ok, :acknowledged}, reference)

  defp receive_checkout_result({:error, reason}, _reference),
    do: {:error, normalize_credential_error(reason)}

  defp receive_metadata_result({:ok, :acknowledged}, reference) do
    receive do
      {^reference, result} -> result
    after
      0 -> {:error, :credential_service_unavailable}
    end
  end

  defp receive_metadata_result({:ok, :ok}, reference),
    do: receive_metadata_result({:ok, :acknowledged}, reference)

  defp receive_metadata_result({:error, reason}, _reference),
    do: {:error, normalize_credential_error(reason)}

  defp invoke_remote(item, request, action, pat, options) do
    remote_options =
      options.remote_options ++
        [
          cancel?: fn -> Cancellation.check(item.id, item.lease_owner) end,
          heartbeat: fn -> heartbeat(item.id, item.lease_owner, options.lease_seconds) end
        ]

    apply(options.remote, action, [request, pat, remote_options])
  end

  defp normalize_remote_result({:ok, %Remote.Result{} = result}), do: {:ok, result}

  defp normalize_remote_result(
         {:error,
          %Remote.Error{
            kind: :cleanup_pending,
            detail: %Remote.CleanupPending{} = evidence
          }}
       ),
       do: {:cleanup_pending, evidence}

  defp normalize_remote_result({:error, %Remote.Error{kind: kind}}),
    do: {:error, remote_error(kind)}

  defp normalize_remote_result({:error, reason}) when is_atom(reason),
    do: {:error, remote_error(reason)}

  defp normalize_remote_result(_unsafe), do: {:error, :remote_unavailable}

  defp persist_success(capability, %Remote.Result{} = result, options) do
    with {:ok, %{item: current}} <- current_context(capability.id, capability.lease_owner),
         :ok <- validate_result(current, result),
         false <- Cancellation.check(current.id, current.lease_owner),
         {:ok, renewed} <- renew_for_post_remote(current, options.lease_seconds),
         {:ok, scan} <- scan_unsupported(renewed, result, options.scan_options),
         {:ok, post_scan} <- renew_for_post_remote(renewed, options.lease_seconds),
         {:ok, updated} <- persist_git_staged(post_scan, result, scan, options.persistence_hook) do
      {:ok, updated}
    else
      true -> persist_cancellation(capability)
      {:error, :cancelled} -> persist_cancellation(capability)
      {:error, reason} -> release_with_error(capability, reason)
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] ->
      release_with_error(capability, :persistence_unavailable)
  end

  defp renew_for_post_remote(item, configured_lease_seconds) do
    OperationLease.renew_owned(RepositoryItem, item,
      now: DateTime.utc_now(:second),
      lease_seconds: max(configured_lease_seconds, @post_remote_lease_seconds)
    )
  end

  defp scan_unsupported(_item, %Remote.Result{empty?: true}, _scan_options),
    do: {:ok, %{lfs?: false, submodules?: false, truncated?: false}}

  defp scan_unsupported(item, %Remote.Result{} = result, scan_options),
    do:
      RepositoryStager.scan_unsupported(
        item.staged_storage_path,
        result.default_branch,
        scan_options
      )

  defp persist_git_staged(capability, result, scan, persistence_hook) do
    warnings = scan_warnings(scan)

    transaction = fn ->
      Repo.transaction(fn ->
        with %ImportRun{state: :running} = run <- locked_run(capability.import_run_id),
             %RepositoryItem{} = item <- locked_owned_item_for_git(capability),
             now <- DateTime.utc_now(:second),
             true <- live_lease?(item, now),
             {:ok, inserted_warning_count} <- insert_scan_warnings(run, item, warnings),
             :ok <- bump_run_after_git_stage(run, inserted_warning_count, now),
             :ok <- run_persistence_hook(persistence_hook),
             final_now <- DateTime.utc_now(:second),
             true <- live_lease?(item, final_now),
             {:ok, updated} <-
               update_git_staged_item(item, result, scan, inserted_warning_count, final_now) do
          updated
        else
          nil -> Repo.rollback(:lost_lease)
          {:error, reason} -> Repo.rollback(reason)
          _stale -> Repo.rollback(:lost_lease)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, %RepositoryItem{} = item} -> {:ok, item}
      {:error, :lost_lease} -> {:error, :lost_lease}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp locked_owned_item_for_git(capability) do
    RepositoryItem
    |> where(
      [item],
      item.id == ^capability.id and item.import_run_id == ^capability.import_run_id and
        item.lock_version == ^capability.lock_version and
        item.lease_owner == ^capability.lease_owner and item.state == :staging_git and
        is_nil(item.cleanup_state)
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp insert_scan_warnings(run, item, warnings) do
    Enum.reduce_while(warnings, {:ok, 0}, fn classification, {:ok, inserted_count} ->
      changeset =
        ReportEntry.create_changeset(%ReportEntry{}, %{
          import_run_id: run.id,
          repository_item_id: item.id,
          idempotency_key: "git-warning-#{item.github_repository_id}-#{classification}",
          scope: :repository,
          outcome: :warning,
          classification: classification,
          summary: warning_summary(classification),
          metadata: %{"category" => classification},
          source_count: if(classification == "unsupported_scan_truncated", do: 0, else: 1)
        })

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:import_run_id, :idempotency_key],
             returning: [:id]
           ) do
        {:ok, %ReportEntry{id: id}} when is_integer(id) ->
          {:cont, {:ok, inserted_count + 1}}

        {:ok, %ReportEntry{id: nil}} ->
          {:cont, {:ok, inserted_count}}

        {:error, _changeset} ->
          {:halt, {:error, :persistence_unavailable}}
      end
    end)
  end

  defp bump_run_after_git_stage(run, warning_count, now) do
    case Repo.update_all(
           from(candidate in ImportRun,
             where:
               candidate.id == ^run.id and candidate.lock_version == ^run.lock_version and
                 candidate.state == :running and
                 (is_nil(candidate.lease_expires_at) or candidate.lease_expires_at <= ^now)
           ),
           set: [updated_at: now, lease_owner: nil, lease_expires_at: nil],
           inc: [lock_version: 1, warning_count: warning_count]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :lost_lease}
    end
  end

  defp update_git_staged_item(item, result, scan, new_warning_count, now) do
    changeset =
      RepositoryItem.lease_update_changeset(item,
        state: :git_staged,
        source_git: %{
          "empty" => result.empty?,
          "default_branch" => result.default_branch,
          "refs" => result.refs,
          "bytes" => result.bytes,
          "lfs_detected" => scan.lfs?,
          "submodules_detected" => scan.submodules?,
          "scan_truncated" => scan.truncated?
        },
        checkpoint: %{
          "git_staged" => true,
          "unsupported_scan" => if(scan.truncated?, do: "truncated", else: "complete")
        },
        warning_count: item.warning_count + new_warning_count,
        next_attempt_at: nil,
        wait_reason: nil,
        failure_kind: nil,
        failure_detail: nil,
        cleanup_state: nil,
        cleanup_eligible_at: nil,
        cleanup_attempt_count: 0,
        cleanup_error: nil
      )

    if changeset.valid? do
      updates =
        changeset.changes
        |> Map.drop([:lock_version, :lease_owner, :lease_expires_at])
        |> Map.put(:lease_owner, nil)
        |> Map.put(:lease_expires_at, nil)
        |> Map.put(:updated_at, now)
        |> Map.to_list()

      query =
        from candidate in RepositoryItem,
          where:
            candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
              candidate.lease_owner == ^item.lease_owner and candidate.lease_expires_at > ^now and
              candidate.state == :staging_git and is_nil(candidate.cleanup_state)

      case Repo.update_all(query, set: updates, inc: [lock_version: 1]) do
        {1, _rows} ->
          updated = Repo.get!(RepositoryItem, item.id)

          Telemetry.execute([:git, :staged], %{bytes: result.bytes}, %{
            run_id: updated.import_run_id,
            item_id: updated.id,
            bytes: result.bytes
          })

          {:ok, updated}

        {0, _rows} ->
          {:error, :lost_lease}
      end
    else
      {:error, :persistence_unavailable}
    end
  end

  defp scan_warnings(scan) do
    []
    |> maybe_warning(scan.lfs?, "unsupported_git_lfs")
    |> maybe_warning(scan.submodules?, "unsupported_submodules")
    |> maybe_warning(scan.truncated?, "unsupported_scan_truncated")
    |> Enum.reverse()
  end

  defp maybe_warning(warnings, true, classification), do: [classification | warnings]
  defp maybe_warning(warnings, false, _classification), do: warnings

  defp warning_summary("unsupported_git_lfs"), do: "Git LFS objects are not imported"
  defp warning_summary("unsupported_submodules"), do: "Git submodules are not imported"

  defp warning_summary("unsupported_scan_truncated"),
    do: "The unsupported Git feature scan was truncated"

  defp run_persistence_hook(nil), do: :ok

  defp run_persistence_hook(hook) when is_function(hook, 0) do
    case hook.() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :persistence_unavailable}
    end
  end

  defp persist_cleanup_pending(capability, shadow, evidence) do
    destination = ForgeRepos.absolute_storage_path(shadow)

    with {:ok, %Remote.CleanupPending{} = validated} <- Remote.cleanup_evidence(destination),
         true <- cleanup_evidence_matches?(evidence, validated),
         {:ok, classification} <- cleanup_classification(evidence.original_kind),
         {:ok, current} <- current_cleanup_item(capability.id, capability.lease_owner),
         {:ok, updated} <-
           persist_cleanup_pending_owned(current, validated, classification) do
      {:ok, updated}
    else
      _unsafe -> release_with_error(capability, :unsafe_cleanup_state)
    end
  rescue
    _error in [File.Error, ArgumentError] ->
      release_with_error(capability, :unsafe_cleanup_state)

    _error in [Turso.Error, DBConnection.ConnectionError] ->
      release_with_error(capability, :persistence_unavailable)
  end

  defp current_cleanup_item(item_id, owner) do
    now = DateTime.utc_now(:second)

    case Repo.one(
           from item in RepositoryItem,
             where:
               item.id == ^item_id and item.lease_owner == ^owner and
                 item.lease_expires_at > ^now and item.state == :staging_git and
                 not is_nil(item.hidden_repository_id) and not is_nil(item.staged_storage_path) and
                 is_nil(item.cleanup_state)
         ) do
      %RepositoryItem{} = item -> {:ok, item}
      nil -> {:error, :lost_lease}
    end
  end

  defp persist_cleanup_pending_owned(item, evidence, classification) do
    now = DateTime.utc_now(:second)

    identity = %{
      "mode" => evidence.identity.mode,
      "major_device" => evidence.identity.major_device,
      "minor_device" => evidence.identity.minor_device,
      "inode" => evidence.identity.inode
    }

    attrs = %{
      staged_storage_path: evidence.quarantine_path,
      checkpoint: Map.put(item.checkpoint, "cleanup_identity", identity),
      cleanup_state: "cleanup_pending",
      cleanup_eligible_at: now,
      cleanup_attempt_count: 0,
      cleanup_error: classification
    }

    changeset = RepositoryItem.cleanup_pending_changeset(item, attrs)

    if changeset.valid? do
      query =
        from candidate in RepositoryItem,
          where:
            candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
              candidate.lease_owner == ^item.lease_owner and candidate.lease_expires_at > ^now and
              candidate.state == :staging_git and is_nil(candidate.cleanup_state)

      updates =
        changeset.changes
        |> Map.drop([:lock_version, :lease_owner, :lease_expires_at])
        |> Map.put(:lease_owner, nil)
        |> Map.put(:lease_expires_at, nil)
        |> Map.put(:updated_at, now)
        |> Map.to_list()

      case Repo.update_all(query, set: updates, inc: [lock_version: 1]) do
        {1, _rows} -> {:ok, Repo.get!(RepositoryItem, item.id)}
        {0, _rows} -> {:error, :lost_lease}
      end
    else
      {:error, :unsafe_cleanup_state}
    end
  end

  defp cleanup_evidence_matches?(provided, validated) do
    provided.quarantine_path == validated.quarantine_path and
      normalize_identity(provided.identity) == normalize_identity(validated.identity)
  end

  defp normalize_identity(identity) when is_map(identity) do
    %{
      mode: Map.get(identity, :mode) || Map.get(identity, "mode"),
      major_device: Map.get(identity, :major_device) || Map.get(identity, "major_device"),
      minor_device: Map.get(identity, :minor_device) || Map.get(identity, "minor_device"),
      inode: Map.get(identity, :inode) || Map.get(identity, "inode")
    }
  end

  defp normalize_identity(_identity), do: %{}

  defp cleanup_classification(kind)
       when kind in [
              :cancelled,
              :heartbeat_failed,
              :owner_down,
              :timeout,
              :host_policy,
              :credential_unavailable,
              :disk_unavailable,
              :output_limit,
              :process_exit,
              :process_unavailable,
              :source_validation,
              :default_branch,
              :ref_limit,
              :repository_limit,
              :unsafe_config,
              :unsafe_credential_state,
              :previous_failure
            ],
       do: {:ok, Atom.to_string(kind)}

  defp cleanup_classification(_kind), do: {:error, :unsafe_cleanup_state}

  defp persist_cancellation(capability) do
    transaction = fn ->
      Repo.transaction(fn ->
        with %ImportRun{state: :cancel_requested} = run <- locked_run(capability.import_run_id),
             %RepositoryItem{} = item <-
               locked_owned_item_by_owner(capability.id, capability.lease_owner),
             :ok <- after_settlement_locks(:cancellation),
             now <- DateTime.utc_now(:second),
             true <- live_lease?(item, now),
             {:ok, canceled} <-
               OperationLease.update_owned(RepositoryItem, item,
                 state: :cancel_requested,
                 wait_reason: "cancellation_requested",
                 next_attempt_at: nil
               ),
             {1, _rows} <-
               Repo.update_all(
                 from(candidate in ImportRun,
                   where:
                     candidate.id == ^run.id and candidate.lock_version == ^run.lock_version and
                       candidate.state == :cancel_requested
                 ),
                 set: [updated_at: now],
                 inc: [lock_version: 1]
               ) do
          canceled
        else
          false -> Repo.rollback(:lost_lease)
          _lost -> Repo.rollback(:lost_lease)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, %RepositoryItem{state: :cancel_requested}} -> {:error, :cancelled}
      {:error, :lost_lease} -> {:error, :lost_lease}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  rescue
    _error in Turso.Error -> {:error, :persistence_unavailable}
  end

  defp locked_owned_item_by_owner(item_id, owner) do
    RepositoryItem
    |> where(
      [item],
      item.id == ^item_id and item.lease_owner == ^owner and item.state == :staging_git
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp pause_for_credential(capability, reason) do
    wait_reason = credential_wait_reason(reason)

    transaction = fn ->
      Repo.transaction(fn ->
        with %ImportRun{} = run <- locked_run(capability.import_run_id),
             %RepositoryItem{} = item <- locked_owned_item(capability),
             :ok <- after_settlement_locks(:credential_pause),
             now <- DateTime.utc_now(:second),
             true <- live_lease?(item, now),
             {:ok, _run} <- pause_run_for_credential(run, wait_reason, now),
             {:ok, _item} <-
               OperationLease.update_owned(RepositoryItem, item,
                 state: :awaiting_credential,
                 wait_reason: wait_reason,
                 next_attempt_at: nil
               ) do
          :awaiting_credential
        else
          nil -> Repo.rollback(:lost_lease)
          false -> Repo.rollback(:lost_lease)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, :awaiting_credential} -> {:error, :awaiting_credential}
      {:error, :lost_lease} -> {:error, :lost_lease}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  rescue
    _error in Turso.Error -> {:error, :persistence_unavailable}
  end

  defp locked_owned_item(capability) do
    RepositoryItem
    |> where(
      [item],
      item.id == ^capability.id and item.import_run_id == ^capability.import_run_id and
        item.lock_version == ^capability.lock_version and
        item.lease_owner == ^capability.lease_owner and
        item.state in [:staging_git, :git_staged, :staging_metadata]
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp pause_run_for_credential(%ImportRun{state: :running} = run, wait_reason, now) do
    changeset =
      ImportRun.transition_changeset(run, :awaiting_credential, %{
        wait_reason: wait_reason,
        next_attempt_at: nil
      })

    Persistence.update_without_lease(run, [:running], changeset, now)
  end

  defp pause_run_for_credential(%ImportRun{state: :awaiting_credential} = run, _reason, _now),
    do: {:ok, run}

  defp pause_run_for_credential(_run, _reason, _now), do: {:error, :lost_lease}

  defp credential_wait_reason(:invalid_credential), do: "credential_invalid"
  defp credential_wait_reason(:credential_changed), do: "credential_changed"
  defp credential_wait_reason(_reason), do: "credential_unavailable"

  defp validate_result(item, result) do
    default_branch = Map.get(item.source_metadata, "default_branch")

    if result.path == item.staged_storage_path and result.default_branch == default_branch and
         is_boolean(result.empty?) and is_integer(result.refs) and result.refs >= 0 and
         is_integer(result.bytes) and result.bytes >= 0,
       do: :ok,
       else: {:error, :invalid_remote_result}
  end

  defp current_context(item_id, owner) do
    now = DateTime.utc_now(:second)

    case Repo.one(
           from item in RepositoryItem,
             join: run in ImportRun,
             on: run.id == item.import_run_id,
             join: actor in User,
             on: actor.id == run.actor_user_id,
             join: identity in GitHubIdentity,
             on: identity.id == run.github_identity_id,
             join: attempt in ImportAttempt,
             on:
               attempt.repository_item_id == item.id and
                 attempt.attempt_number == item.attempt_count,
             where:
               item.id == ^item_id and item.lease_owner == ^owner and
                 item.lease_expires_at > ^now and item.selected == true and
                 item.state in [:staging_git, :git_staged, :staging_metadata] and
                 is_nil(item.cleanup_state) and
                 run.state in [:running, :cancel_requested] and actor.kind == :user and
                 actor.state == :active and
                 identity.kind == :user and not is_nil(identity.last_verified_at) and
                 attempt.state == :running,
             select: %{actor: actor, run: run, item: item, identity: identity}
         ) do
      %{run: %ImportRun{state: :running}, item: %RepositoryItem{}} = context -> {:ok, context}
      %{run: %ImportRun{state: :cancel_requested}} -> {:error, :cancelled}
      nil -> {:error, :lost_lease}
    end
  end

  defp git_work_allowed?(item_id, owner),
    do: match?({:ok, _context}, current_context(item_id, owner))

  defp completed_remote_cleanup?(item_id) do
    with %RepositoryItem{} = item <- Repo.get(RepositoryItem, item_id),
         true <- item.state == :staging_git and is_nil(item.cleanup_state),
         operation_id when is_binary(operation_id) and operation_id != "" <-
           item.checkpoint["remote_cleanup_operation_id"] do
      Repo.exists?(
        from operation in CleanupOperation,
          join: run in ImportRun,
          on: run.id == ^item.import_run_id,
          where:
            operation.operation_id == ^operation_id and
              operation.repository_item_id == ^item_id and
              operation.kind == :remote_quarantine and
              operation.state == :cleanup_complete and
              operation.repository_id == ^item.hidden_repository_id and
              run.state in [:completed, :completed_with_warnings, :canceled, :failed]
      )
    else
      _missing -> false
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] -> false
  end

  defp settle_post_cleanup_terminal(capability) do
    Repo.transaction(fn ->
      with %ImportRun{state: run_state} <- locked_run(capability.import_run_id),
           true <- run_state in [:completed, :completed_with_warnings, :canceled, :failed],
           %RepositoryItem{} = item <- locked_item(capability.id),
           true <-
             item.lease_owner == capability.lease_owner and
               item.lock_version == capability.lock_version and item.state == :staging_git and
               is_nil(item.cleanup_state),
           true <- completed_remote_cleanup?(item.id),
           %ImportAttempt{state: :running} = attempt <- current_attempt(item),
           target <- if(run_state == :canceled, do: :canceled, else: :failed),
           now <- DateTime.utc_now(:second),
           {:ok, _attempt} <-
             attempt
             |> ImportAttempt.transition_changeset(target, %{
               terminal_at: now,
               failure_kind: if(target == :failed, do: "remote_cleanup_failed", else: nil)
             })
             |> Repo.update(),
           {:ok, settled} <- settle_post_cleanup_item(item, target, now) do
        settled
      else
        _not_terminal -> Repo.rollback(:not_runnable)
      end
    end)
    |> case do
      {:ok, %RepositoryItem{} = item} -> {:ok, item}
      {:error, reason} -> release_with_error(capability, reason)
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] ->
      release_with_error(capability, :persistence_unavailable)
  end

  defp settle_post_cleanup_item(item, :canceled, now) do
    lease_seconds = max(DateTime.diff(item.lease_expires_at, now, :second), 1)
    checkpoint = Map.delete(item.checkpoint || %{}, "remote_cleanup_operation_id")

    with {:ok, cancel_requested} <-
           OperationLease.update_owned(
             RepositoryItem,
             item,
             [
               state: :cancel_requested,
               wait_reason: "cancellation_requested",
               next_attempt_at: nil,
               failure_kind: nil,
               failure_detail: nil
             ],
             now: now,
             lease_seconds: lease_seconds
           ) do
      OperationLease.update_owned(RepositoryItem, cancel_requested,
        state: :canceled,
        wait_reason: nil,
        next_attempt_at: nil,
        failure_kind: nil,
        failure_detail: nil,
        checkpoint: checkpoint
      )
    end
  end

  defp settle_post_cleanup_item(item, :failed, _now) do
    checkpoint = Map.delete(item.checkpoint || %{}, "remote_cleanup_operation_id")

    OperationLease.update_owned(RepositoryItem, item,
      state: :failed,
      next_attempt_at: nil,
      failure_kind: "remote_cleanup_failed",
      failure_detail: nil,
      checkpoint: checkpoint
    )
  end

  defp cancel_requested?(run_id) do
    Repo.exists?(
      from run in ImportRun, where: run.id == ^run_id and run.state == :cancel_requested
    )
  rescue
    _error -> true
  end

  defp heartbeat(item_id, owner, lease_seconds) do
    now = DateTime.utc_now(:second)

    with {:ok, %{item: item}} <- current_context(item_id, owner) do
      remaining = DateTime.diff(item.lease_expires_at, now, :second)

      if remaining <= div(lease_seconds, 2) do
        case OperationLease.renew_owned(RepositoryItem, item,
               now: now,
               lease_seconds: lease_seconds
             ) do
          {:ok, _renewed} -> :ok
          {:error, _reason} -> :error
        end
      else
        :ok
      end
    else
      {:error, _reason} -> :error
    end
  end

  defp request(item, shadow, identity) do
    [owner, repository] = String.split(item.source_full_name, "/", parts: 2)

    %Remote.Request{
      provider: :github,
      owner: owner,
      repository: repository,
      credential_login: identity.login,
      destination: ForgeRepos.absolute_storage_path(shadow),
      default_branch: Map.fetch!(item.source_metadata, "default_branch")
    }
  end

  defp saved_reference_matches?(run, reference) do
    reference.credential_id == run.github_credential_id and
      reference.identity_id == run.github_identity_id and
      reference.local_user_id == run.actor_user_id
  end

  defp release_with_error(%RepositoryItem{} = capability, reason) do
    normalized = normalize_worker_error(reason)

    if normalized == :lost_lease do
      _ = release_owned_capability(capability)
      {:error, :lost_lease}
    else
      case persist_retry_backoff(capability, normalized) do
        :ok -> {:error, normalized}
        {:error, :lost_lease} -> {:error, :lost_lease}
        {:error, :persistence_unavailable} -> {:error, :persistence_unavailable}
      end
    end
  end

  defp release_owned_capability(capability) do
    case Repo.get_by(RepositoryItem, id: capability.id, lease_owner: capability.lease_owner) do
      %RepositoryItem{} = current -> OperationLease.release(RepositoryItem, current)
      nil -> {:error, :lost_lease}
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] -> {:error, :lost_lease}
  end

  defp persist_retry_backoff(capability, classification) do
    transaction = fn ->
      Repo.transaction(fn ->
        with %ImportRun{} = run <- locked_run(capability.import_run_id),
             %RepositoryItem{} = item <- locked_error_item(capability),
             now <- DateTime.utc_now(:second),
             true <- live_lease?(item, now),
             {:ok, _released} <-
               OperationLease.update_owned(RepositoryItem, item,
                 next_attempt_at: DateTime.add(now, @retry_backoff_seconds, :second),
                 failure_kind: Atom.to_string(classification),
                 failure_detail: nil
               ),
             :ok <- bump_run_after_retry(run, now) do
          :ok
        else
          nil -> Repo.rollback(:lost_lease)
          false -> Repo.rollback(:lost_lease)
          {:error, :lost_lease} -> Repo.rollback(:lost_lease)
          _failure -> Repo.rollback(:persistence_unavailable)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, :ok} -> :ok
      {:error, :lost_lease} -> {:error, :lost_lease}
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  rescue
    _error in [Turso.Error, DBConnection.ConnectionError] ->
      {:error, :persistence_unavailable}
  end

  defp bump_run_after_retry(%ImportRun{state: state}, _now)
       when state in [:completed, :completed_with_warnings, :canceled, :failed],
       do: :ok

  defp bump_run_after_retry(run, now) do
    case Repo.update_all(
           from(candidate in ImportRun,
             where: candidate.id == ^run.id and candidate.lock_version == ^run.lock_version
           ),
           set: [updated_at: now],
           inc: [lock_version: 1]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :persistence_unavailable}
    end
  end

  defp locked_error_item(capability) do
    RepositoryItem
    |> where(
      [item],
      item.id == ^capability.id and item.import_run_id == ^capability.import_run_id and
        item.lease_owner == ^capability.lease_owner and
        item.state in [:queued, :staging_git, :git_staged, :staging_metadata] and
        is_nil(item.cleanup_state)
    )
    |> maybe_lock()
    |> Repo.one()
  end

  defp fresh_item?(item),
    do: is_nil(item.hidden_repository_id) and is_nil(item.staged_storage_path)

  defp staged_item?(item),
    do: is_integer(item.hidden_repository_id) and is_binary(item.staged_storage_path)

  defp metadata_ready_item?(item) do
    staged_item?(item) and get_in(item.checkpoint, ["git_staged"]) == true
  end

  defp due?(%RepositoryItem{next_attempt_at: nil}, _now), do: true
  defp due?(%RepositoryItem{next_attempt_at: next}, now), do: DateTime.compare(next, now) != :gt

  defp live_lease?(%{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp live_lease?(_row, _now), do: false

  defp maybe_lock(query) do
    if postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp options(opts) do
    allowed =
      if @allow_test_options,
        do:
          ~w(owner lease_seconds keyring remote remote_options scan_options persistence_hook client client_options)a,
        else: ~w(owner lease_seconds)a

    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_request}

      length(Keyword.keys(opts)) != length(Enum.uniq(Keyword.keys(opts))) ->
        {:error, :invalid_request}

      Keyword.keys(opts) -- allowed != [] ->
        {:error, :invalid_request}

      true ->
        build_options(opts)
    end
  end

  defp build_options(opts) do
    owner = Keyword.get(opts, :owner, generated_owner())
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)
    remote = Keyword.get(opts, :remote, Remote)
    remote_options = Keyword.get(opts, :remote_options, [])
    scan_options = Keyword.get(opts, :scan_options, [])
    persistence_hook = Keyword.get(opts, :persistence_hook)
    keyring = Keyword.get(opts, :keyring, Fornacast.Config.github_credential_keyring())
    client = Keyword.get(opts, :client, Client)
    client_options = Keyword.get(opts, :client_options, [])

    if is_binary(owner) and byte_size(owner) in 1..255 and String.valid?(owner) and
         is_integer(lease_seconds) and lease_seconds in 2..@max_lease_seconds and is_atom(remote) and
         Code.ensure_loaded?(remote) and function_exported?(remote, :mirror, 3) and
         function_exported?(remote, :refresh, 3) and
         function_exported?(remote, :cleanup_evidence, 1) and Keyword.keyword?(remote_options) and
         Keyword.keyword?(scan_options) and
         (is_nil(persistence_hook) or is_function(persistence_hook, 0)) and
         not Keyword.has_key?(remote_options, :cancel?) and
         not Keyword.has_key?(remote_options, :heartbeat) and
         is_atom(client) and Code.ensure_loaded?(client) and Keyword.keyword?(client_options) do
      {:ok,
       %{
         owner: owner,
         lease_seconds: lease_seconds,
         remote: remote,
         remote_options: remote_options,
         scan_options: scan_options,
         persistence_hook: persistence_hook,
         keyring: keyring,
         client: client,
         client_options: client_options
       }}
    else
      {:error, :invalid_request}
    end
  end

  defp generated_owner do
    "github-repository-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp normalize_credential_error(reason)
       when reason in [
              :not_found,
              :forbidden,
              :credential_invalid,
              :credential_service_unavailable
            ],
       do: if(reason == :credential_invalid, do: :invalid_credential, else: reason)

  defp normalize_credential_error(_reason), do: :credential_service_unavailable

  defp remote_error(kind)
       when kind in [
              :cancelled,
              :heartbeat_failed,
              :owner_down,
              :timeout,
              :remote_busy,
              :remote_unavailable,
              :lost_lease,
              :invalid_credential,
              :source_validation,
              :default_branch,
              :ref_limit,
              :repository_limit,
              :cleanup_pending,
              :unsafe_cleanup_state
            ],
       do: kind

  defp remote_error(_kind), do: :remote_unavailable

  defp normalize_worker_error(reason)
       when reason in [
              :cancelled,
              :lost_lease,
              :destination_changed,
              :ambiguous_staging,
              :unsafe_cleanup_state,
              :invalid_remote_result,
              :persistence_unavailable
            ],
       do: reason

  defp normalize_worker_error(_reason), do: :staging_unavailable
end
