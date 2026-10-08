defmodule ForgeImports.Retry do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}

  alias ForgeImports.{
    ImportRun,
    ImportAttempt,
    ObjectMapping,
    PageCheckpoint,
    Persistence,
    ReportEntry,
    RepositoryItem,
    RepositoryPublisher,
    Telemetry
  }

  alias ForgeRepos.Repository
  alias Fornacast.{Audit, Repo}

  @retryable_run_states [:failed, :canceled, :completed_with_warnings]
  @retryable_item_states [:failed, :canceled]

  def restart(actor, predecessor, credential_source, request_metadata, opts \\ []) do
    Persistence.with_retry(fn ->
      Repo.transaction(fn ->
        with {:ok, active_actor} <- active_actor(actor),
             %ImportRun{} = current <- locked_predecessor(active_actor.id, predecessor.id),
             true <- current.state in [:running, :awaiting_credential, :cancel_requested],
             items <-
               Repo.all(
                 from i in RepositoryItem,
                   where: i.import_run_id == ^current.id and i.selected == true,
                   order_by: i.id,
                   lock: "FOR UPDATE"
               ),
             :ok <- restart_safe(items),
             :ok <- release_run_lease(current),
             {:ok, canceled} <-
               request_restart_cancel(
                 active_actor,
                 Repo.get!(ImportRun, current.id),
                 request_metadata,
                 opts
               ),
             :ok <- settle_restart_items(items),
             {:ok, terminal} <-
               canceled
               |> ImportRun.transition_changeset(:canceled, %{
                 terminal_at: DateTime.utc_now(:second)
               })
               |> Repo.update(),
             {:ok, successor} <-
               create_successor(active_actor, terminal, credential_source, request_metadata, opts) do
          successor
        else
          nil -> Repo.rollback(:not_found)
          false -> Repo.rollback(:invalid_predecessor)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  defp restart_safe(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      cond do
        item.state == :publishing ->
          {:halt, {:error, :busy}}

        item.state in [:published, :completed, :skipped] ->
          {:cont, :ok}

        item.publication_evidence != %{} ->
          {:halt, {:error, :invalid_predecessor}}

        item.state == :staging_git ->
          {:halt, {:error, :busy}}

        not is_nil(item.cleanup_state) ->
          {:halt, {:error, :cleanup_conflict}}

        true ->
          with :ok <- Persistence.ensure_adoption_safe_locked(Repo, item),
               {:ok, phase} <- RepositoryPublisher.durable_proof_state(item),
               true <- phase in [:queued, :git_staged, :ready_to_publish],
               true <- phase != :queued or is_nil(item.lease_owner) do
            {:cont, :ok}
          else
            false -> {:halt, {:error, :busy}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp release_run_lease(%ImportRun{lease_owner: nil}), do: :ok
  defp release_run_lease(run), do: Fornacast.OperationLease.release(ImportRun, run)

  defp request_restart_cancel(
         _actor,
         %ImportRun{state: :cancel_requested} = run,
         _metadata,
         _opts
       ),
       do: {:ok, run}

  defp request_restart_cancel(actor, run, metadata, opts),
    do: ForgeImports.Cancellation.request(actor, run, metadata, opts)

  defp settle_restart_items(items) do
    Enum.reduce_while(items, :ok, fn previous, :ok ->
      item = Repo.get!(RepositoryItem, previous.id)

      if item.state == :cancel_requested do
        with {:ok, _} <-
               item
               |> RepositoryItem.transition_changeset(:canceled, %{
                 wait_reason: nil,
                 next_attempt_at: nil
               })
               |> Repo.update(),
             :ok <- settle_restart_attempt(item) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp settle_restart_attempt(item) do
    case Repo.one(
           from a in ImportAttempt,
             where:
               a.repository_item_id == ^item.id and a.attempt_number == ^item.attempt_count and
                 a.state == :running,
             lock: "FOR UPDATE"
         ) do
      nil ->
        :ok

      attempt ->
        case attempt |> ImportAttempt.transition_changeset(:canceled) |> Repo.update() do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :persistence_unavailable}
        end
    end
  end

  @spec create_successor(User.t(), ImportRun.t(), term(), map(), keyword()) ::
          {:ok, ImportRun.t()} | {:error, atom()}
  def create_successor(actor, predecessor, credential_source, request_metadata, opts \\ [])

  def create_successor(
        %User{} = actor,
        %ImportRun{} = expected_predecessor,
        credential_source,
        request_metadata,
        opts
      )
      when is_map(request_metadata) and is_list(opts) do
    transaction = fn ->
      Repo.transaction(fn ->
        with {:ok, active_actor} <- active_actor(actor),
             %ImportRun{} = predecessor <-
               locked_predecessor(active_actor.id, expected_predecessor.id),
             :ok <- validate_retryable_predecessor(predecessor),
             false <- successor_exists?(predecessor.id),
             {:ok, normalized_source} <-
               normalize_credential_source(active_actor, credential_source, opts),
             {:ok, safe_metadata} <- safe_request_metadata(request_metadata),
             retryable_items <- retryable_items(predecessor.id),
             true <- retryable_items != [],
             {:ok, successor} <-
               insert_successor_run(
                 active_actor,
                 predecessor,
                 normalized_source,
                 safe_metadata,
                 retryable_items
               ),
             :ok <- insert_successor_items(active_actor, predecessor, successor, retryable_items),
             :ok <- record_retry_audit(active_actor, predecessor, successor, safe_metadata) do
          kick_reconciler()
          successor
        else
          nil -> Repo.rollback(:not_found)
          true -> Repo.rollback(:invalid_predecessor)
          false -> Repo.rollback(:invalid_predecessor)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, %ImportRun{id: run_id, predecessor_run_id: predecessor_run_id} = run} ->
        Telemetry.execute([:retry, :created], %{count: 1}, %{
          run_id: run_id,
          predecessor_run_id: predecessor_run_id,
          retry: true
        })

        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_successor(_actor, _predecessor, _credential_source, _request_metadata, _opts),
    do: {:error, :not_found}

  @spec adopt_staging(term(), RepositoryItem.t(), RepositoryItem.t()) ::
          {:ok, RepositoryItem.t()} | {:error, atom()}
  def adopt_staging(repo, predecessor_item, successor_item)

  def adopt_staging(
        repo,
        %RepositoryItem{} = predecessor_item,
        %RepositoryItem{} = successor_item
      )
      when is_atom(repo) do
    with :ok <- Persistence.ensure_adoption_safe_locked(repo, predecessor_item),
         {:ok, phase} <- RepositoryPublisher.durable_proof_state(predecessor_item) do
      case phase do
        :queued ->
          {:ok, successor_item}

        phase when phase in [:git_staged, :ready_to_publish] ->
          adopt_proven_staging(repo, predecessor_item, successor_item, phase)
      end
    else
      {:error, :inconsistent} -> {:error, :invalid_predecessor}
      {:error, reason} -> {:error, reason}
    end
  end

  def adopt_staging(_repo, _predecessor_item, _successor_item), do: {:error, :invalid_predecessor}

  defp adopt_proven_staging(repo, predecessor_item, successor_item, phase) do
    shadow_id = predecessor_item.hidden_repository_id

    with true <-
           predecessor_item.github_repository_id == successor_item.github_repository_id and
             predecessor_item.source_full_name == successor_item.source_full_name and
             predecessor_item.destination_owner_id == successor_item.destination_owner_id,
         %Repository{} = shadow <- repo.get(Repository, shadow_id),
         {:ok, shadow} <- adopt_shadow(repo, shadow, successor_item.id),
         {:ok, updated_item} <-
           attach_staging(repo, predecessor_item, successor_item, shadow, phase),
         :ok <- relink_mappings(repo, predecessor_item.id, updated_item.id),
         :ok <- relink_checkpoints(repo, predecessor_item.id, updated_item.id),
         :ok <- copy_pull_candidates(repo, predecessor_item, updated_item) do
      {:ok, updated_item}
    else
      nil -> {:error, :invalid_predecessor}
      false -> {:error, :invalid_predecessor}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_pull_candidates(repo, predecessor, successor) do
    repo.all(
      from entry in ReportEntry,
        where:
          entry.import_run_id == ^predecessor.import_run_id and
            entry.repository_item_id == ^predecessor.id and
            entry.classification == "pull_candidate",
        order_by: entry.id,
        lock: "FOR UPDATE"
    )
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      attrs =
        entry
        |> Map.take([
          :scope,
          :object_kind,
          :source_object_id,
          :outcome,
          :classification,
          :summary,
          :metadata,
          :source_count
        ])
        |> Map.merge(%{
          import_run_id: successor.import_run_id,
          repository_item_id: successor.id,
          idempotency_key: "pull-candidate-#{successor.id}-#{entry.source_object_id}"
        })

      case repo.insert(ReportEntry.create_changeset(%ReportEntry{}, attrs)) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, {:error, :invalid_predecessor}}
      end
    end)
  end

  defp adopt_shadow(repo, %Repository{} = shadow, successor_item_id) do
    changeset = Repository.import_adoption_changeset(shadow, successor_item_id)

    if changeset.valid? do
      case repo.update(changeset) do
        {:ok, updated} -> {:ok, updated}
        {:error, %Ecto.Changeset{}} -> {:error, :invalid_predecessor}
      end
    else
      {:error, :invalid_predecessor}
    end
  end

  defp attach_staging(repo, predecessor_item, successor_item, shadow, phase) do
    staged_path = ForgeRepos.absolute_storage_path(shadow)
    target_state = phase

    if staged_path != predecessor_item.staged_storage_path do
      {:error, :invalid_predecessor}
    else
      query =
        from item in RepositoryItem,
          where:
            item.id == ^successor_item.id and item.import_run_id == ^successor_item.import_run_id and
              item.predecessor_item_id == ^predecessor_item.id

      updates = [
        hidden_repository_id: shadow.id,
        staged_storage_path: staged_path,
        checkpoint: predecessor_item.checkpoint,
        source_git: predecessor_item.source_git,
        state: target_state,
        updated_at: DateTime.utc_now(:second)
      ]

      case repo.update_all(query, set: updates) do
        {1, _} -> {:ok, repo.get!(RepositoryItem, successor_item.id)}
        {0, _} -> {:error, :invalid_predecessor}
      end
    end
  end

  defp relink_mappings(repo, predecessor_item_id, successor_item_id) do
    case repo.update_all(
           from(mapping in ObjectMapping,
             where: mapping.repository_item_id == ^predecessor_item_id
           ),
           set: [repository_item_id: successor_item_id, updated_at: DateTime.utc_now(:second)]
         ) do
      {_count, _} -> :ok
    end
  end

  defp relink_checkpoints(repo, predecessor_item_id, successor_item_id) do
    case repo.update_all(
           from(checkpoint in PageCheckpoint,
             where: checkpoint.repository_item_id == ^predecessor_item_id
           ),
           set: [repository_item_id: successor_item_id, updated_at: DateTime.utc_now(:second)]
         ) do
      {_count, _} -> :ok
    end
  end

  defp validate_retryable_predecessor(%ImportRun{state: state})
       when state in @retryable_run_states,
       do: :ok

  defp validate_retryable_predecessor(_predecessor), do: {:error, :invalid_predecessor}

  defp successor_exists?(predecessor_id) do
    Repo.exists?(from run in ImportRun, where: run.predecessor_run_id == ^predecessor_id)
  end

  defp retryable_items(predecessor_id) do
    RepositoryItem
    |> where([item], item.import_run_id == ^predecessor_id and item.selected == true)
    |> order_by([item], asc: item.id)
    |> Repo.all()
    |> Enum.filter(&retryable_item?/1)
  end

  defp retryable_item?(%RepositoryItem{
         state: state,
         publication_evidence: evidence,
         cleanup_state: nil
       })
       when state in @retryable_item_states and is_map(evidence) do
    map_size(evidence) == 0
  end

  defp retryable_item?(_item), do: false

  defp insert_successor_run(actor, predecessor, source, request_metadata, retryable_items) do
    attrs =
      predecessor
      |> successor_run_attrs(actor, source, request_metadata, retryable_items)
      |> Map.put(:state, :ready)

    %ImportRun{}
    |> ImportRun.persistence_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, map_insert_error(changeset)}
    end
  end

  defp successor_run_attrs(predecessor, actor, source, request_metadata, retryable_items) do
    %{
      actor_user_id: actor.id,
      predecessor_run_id: predecessor.id,
      source_kind: predecessor.source_kind,
      github_identity_id: source.github_identity_id,
      credential_source: source.credential_source,
      github_credential_id: Map.get(source, :github_credential_id),
      source_owner_github_id: predecessor.source_owner_github_id,
      source_owner_login: predecessor.source_owner_login,
      source_repository_github_id: predecessor.source_repository_github_id,
      source_repository_full_name: predecessor.source_repository_full_name,
      source_metadata: predecessor.source_metadata,
      destination_organization_action: predecessor.destination_organization_action,
      destination_organization_slug: predecessor.destination_organization_slug,
      destination_organization_id: predecessor.destination_organization_id,
      destination_organization_status: predecessor.destination_organization_status,
      destination_organization_classification:
        predecessor.destination_organization_classification,
      request_metadata: request_metadata,
      selected_count: length(retryable_items),
      published_count: 0,
      skipped_count: 0,
      warning_count: 0,
      failure_count: 0,
      lock_version: 1
    }
  end

  defp insert_successor_items(_actor, _predecessor, successor, retryable_items) do
    Enum.reduce_while(retryable_items, :ok, fn predecessor_item, :ok ->
      case insert_successor_item(successor, predecessor_item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_successor_item(successor, predecessor_item) do
    attrs = successor_item_attrs(successor, predecessor_item)

    with {:ok, successor_item} <-
           %RepositoryItem{}
           |> RepositoryItem.persistence_changeset(attrs)
           |> Repo.insert(),
         {:ok, _adopted} <- adopt_staging(Repo, predecessor_item, successor_item) do
      :ok
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, map_insert_error(changeset)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp successor_item_attrs(successor, predecessor_item) do
    %{
      import_run_id: successor.id,
      predecessor_item_id: predecessor_item.id,
      github_repository_id: predecessor_item.github_repository_id,
      source_full_name: predecessor_item.source_full_name,
      source_name: predecessor_item.source_name,
      source_metadata: predecessor_item.source_metadata,
      source_observed_at: predecessor_item.source_observed_at,
      selected: true,
      destination_owner_id: predecessor_item.destination_owner_id,
      destination_slug: predecessor_item.destination_slug,
      destination_visibility: predecessor_item.destination_visibility,
      conflict_action: predecessor_item.conflict_action,
      replacement_repository_id: predecessor_item.replacement_repository_id,
      replacement_owner_id: predecessor_item.replacement_owner_id,
      replacement_storage_path: predecessor_item.replacement_storage_path,
      replacement_generation: predecessor_item.replacement_generation,
      replacement_write_version: predecessor_item.replacement_write_version,
      replacement_updated_at: predecessor_item.replacement_updated_at,
      replacement_last_pushed_at: predecessor_item.replacement_last_pushed_at,
      state: initial_item_state(predecessor_item),
      attempt_count: 0,
      checkpoint: %{},
      source_git: %{},
      publication_evidence: %{},
      imported_count: 0,
      skipped_count: 0,
      warning_count: 0,
      failure_count: 0,
      cleanup_attempt_count: 0,
      lock_version: 1
    }
  end

  defp initial_item_state(predecessor_item) do
    case RepositoryPublisher.durable_proof_state(predecessor_item) do
      {:ok, :ready_to_publish} -> :ready_to_publish
      {:ok, :git_staged} -> :git_staged
      _ -> :queued
    end
  end

  defp normalize_credential_source(actor, {:saved, identity_id}, _opts)
       when is_integer(identity_id) and identity_id > 0 do
    case Repo.one(
           from credential in GitHubCredential,
             where:
               credential.local_user_id == ^actor.id and
                 credential.github_identity_id == ^identity_id and credential.status == :valid,
             limit: 1
         ) do
      %GitHubCredential{id: credential_id} ->
        normalize_credential_source(
          actor,
          %{
            credential_source: :saved,
            github_credential_id: credential_id,
            github_identity_id: identity_id
          },
          []
        )

      nil ->
        {:error, :forbidden}
    end
  end

  defp normalize_credential_source(actor, source, _opts) when is_map(source) do
    case Map.get(source, :credential_source) || Map.get(source, "credential_source") do
      :saved ->
        with {:ok, credential_id} <- positive_id(source, :github_credential_id),
             {:ok, identity_id} <- positive_id(source, :github_identity_id),
             :ok <- validate_saved_credential(actor, credential_id, identity_id) do
          {:ok,
           %{
             credential_source: :saved,
             github_credential_id: credential_id,
             github_identity_id: identity_id
           }}
        else
          _ -> {:error, :forbidden}
        end

      _ ->
        {:error, :forbidden}
    end
  end

  defp normalize_credential_source(_actor, _source, _opts), do: {:error, :forbidden}

  defp validate_saved_credential(_actor, credential_id, identity_id)
       when not is_integer(credential_id) or not is_integer(identity_id),
       do: {:error, :forbidden}

  defp validate_saved_credential(%User{id: actor_id}, credential_id, identity_id) do
    case Repo.one(
           from credential in GitHubCredential,
             join: identity in GitHubIdentity,
             on: identity.id == credential.github_identity_id,
             where:
               credential.id == ^credential_id and credential.status == :valid and
                 credential.local_user_id == ^actor_id and identity.id == ^identity_id and
                 identity.local_user_id == ^actor_id and identity.kind == :user and
                 identity.github_user_id > 0
         ) do
      %GitHubCredential{} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp positive_id(source, field) do
    value = Map.get(source, field) || Map.get(source, Atom.to_string(field))

    case Ecto.Type.cast(:integer, value) do
      {:ok, id} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp map_insert_error(%Ecto.Changeset{} = changeset) do
    if duplicate_predecessor?(changeset),
      do: :duplicate_successor,
      else: :invalid_predecessor
  end

  defp duplicate_predecessor?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.constraints, fn
      %{constraint: "github_import_runs_predecessor_run_id_unique_index"} -> true
      %{constraint: "github_import_items_predecessor_item_id_unique_index"} -> true
      _ -> false
    end) or
      Enum.any?(changeset.errors, fn
        {_field, {"has already been taken", _meta}} -> true
        _ -> false
      end)
  end

  defp record_retry_audit(actor, predecessor, successor, request_metadata) do
    metadata = %{
      "predecessor_run_id" => predecessor.id,
      "successor_run_id" => successor.id,
      "source_kind" => Atom.to_string(predecessor.source_kind)
    }

    audit_metadata =
      request_metadata
      |> Map.put("operation_id", "github-import-retry-#{successor.id}")

    case Audit.record(
           actor,
           "github_import.retry_created",
           "github_import_run",
           successor.id,
           metadata,
           request_metadata: audit_metadata
         ) do
      {:ok, _event} -> :ok
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp kick_reconciler do
    if Process.whereis(ForgeImports.Reconciler), do: ForgeImports.Reconciler.kick(), else: :ok
  end

  defp locked_predecessor(actor_id, run_id) do
    ImportRun
    |> where([run], run.id == ^run_id and run.actor_user_id == ^actor_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp active_actor(%User{id: actor_id}) do
    case Repo.one(
           from user in User,
             where: user.id == ^actor_id and user.kind == :user and user.state == :active,
             lock: "FOR UPDATE"
         ) do
      %User{} = active -> {:ok, active}
      nil -> {:error, :forbidden}
    end
  end

  defp safe_request_metadata(request_metadata) do
    case ForgeAccounts.validate_github_request_metadata(request_metadata) do
      {:ok, safe} -> {:ok, safe}
      {:error, _} = error -> error
    end
  end
end
