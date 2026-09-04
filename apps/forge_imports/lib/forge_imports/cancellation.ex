defmodule ForgeImports.Cancellation do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.{ImportAttempt, ImportRun, Persistence, RepositoryItem, Telemetry}
  alias Fornacast.{Audit, OperationLease, Repo}

  @cancellable_run_states [
    :discovering,
    :awaiting_resolution,
    :ready,
    :running,
    :awaiting_credential
  ]
  @intent_run_states [:running, :awaiting_credential]
  @immediate_terminal_run_states [:discovering, :awaiting_resolution, :ready]

  @item_cancel_intent_states [
    :queued,
    :awaiting_resolution,
    :staging_git,
    :git_staged,
    :staging_metadata,
    :ready_to_publish,
    :awaiting_credential
  ]

  @non_interruptible_item_states [
    :publishing,
    :published,
    :completed,
    :skipped,
    :failed,
    :canceled
  ]

  @spec request(User.t(), ImportRun.t(), map(), keyword()) ::
          {:ok, ImportRun.t()} | {:error, atom()}
  def request(actor, run, request_metadata, opts \\ [])

  def request(%User{} = actor, %ImportRun{} = expected_run, request_metadata, opts)
      when is_map(request_metadata) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))

    transaction = fn ->
      Repo.transaction(fn ->
        with {:ok, active_actor} <- active_actor(actor),
             %ImportRun{} = run <- locked_run(active_actor.id, expected_run.id),
             :ok <- validate_cancellable(run),
             {:ok, safe_metadata} <- safe_request_metadata(request_metadata),
             {:ok, {target_state, run_attrs}} <- cancel_target(run, now),
             {:ok, requested_run} <- persist_run_cancel(run, target_state, run_attrs, now),
             :ok <- persist_item_intents(requested_run, target_state, now),
             :ok <- record_cancel_audit(active_actor, requested_run, safe_metadata) do
          kick_reconcilers()
          requested_run
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, %ImportRun{id: run_id} = run} ->
        Telemetry.execute([:cancel, :requested], %{count: 1}, %{run_id: run_id, canceled: true})
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def request(_actor, _run, _request_metadata, _opts), do: {:error, :not_found}

  @spec check(RepositoryItem.t()) :: boolean()
  def check(%RepositoryItem{state: :publishing}), do: false

  def check(%RepositoryItem{} = item) do
    case Repo.get(ImportRun, item.import_run_id) do
      %ImportRun{state: :cancel_requested} -> true
      %ImportRun{state: state} when state in @immediate_terminal_run_states -> false
      _ -> item.state in [:cancel_requested, :canceled]
    end
  end

  @spec check(pos_integer(), String.t()) :: boolean()
  def check(item_id, owner) when is_integer(item_id) and item_id > 0 and is_binary(owner) do
    case Repo.one(
           from item in RepositoryItem,
             join: run in ImportRun,
             on: run.id == item.import_run_id,
             where: item.id == ^item_id and item.lease_owner == ^owner,
             select: {item.state, run.state}
         ) do
      {:publishing, _} -> false
      {state, :running} when state in [:staging_git, :git_staged, :staging_metadata] -> false
      _ -> true
    end
  rescue
    _error -> true
  end

  @doc false
  @spec cancellable_run?(ImportRun.t()) :: boolean()
  def cancellable_run?(%ImportRun{state: state}), do: state in @cancellable_run_states

  defp validate_cancellable(%ImportRun{state: state}) when state in @cancellable_run_states,
    do: :ok

  defp validate_cancellable(_run), do: {:error, :invalid_transition}

  defp cancel_target(%ImportRun{state: state}, now) when state in @intent_run_states do
    {:ok, {:cancel_requested, %{cancellation_requested_at: now}}}
  end

  defp cancel_target(%ImportRun{state: state}, now)
       when state in @immediate_terminal_run_states do
    {:ok, {:canceled, %{cancellation_requested_at: now, terminal_at: now}}}
  end

  defp persist_run_cancel(run, target_state, attrs, now) do
    allowed = [run.state]

    changeset = ImportRun.transition_changeset(run, target_state, attrs)

    Persistence.update_without_lease(run, allowed, changeset, now)
  end

  defp persist_item_intents(%ImportRun{id: run_id, state: :canceled}, _target_state, now) do
    run_id
    |> run_items_for_cancel()
    |> settle_items(:canceled, now)
  end

  defp persist_item_intents(
         %ImportRun{id: run_id, state: :cancel_requested},
         :cancel_requested,
         now
       ) do
    run_id
    |> run_items_for_cancel()
    |> settle_items(:cancel_requested, now)
  end

  defp persist_item_intents(_run, _target_state, _now), do: {:error, :invalid_transition}

  defp settle_items(items, target_state, now) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case settle_item(item, target_state, now) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp settle_item(%RepositoryItem{state: state}, _target, _now)
       when state in @non_interruptible_item_states,
       do: :ok

  defp settle_item(%RepositoryItem{state: state} = item, target_state, now)
       when state in @item_cancel_intent_states do
    with {:ok, _updated} <- transition_item(item, target_state, now),
         :ok <- terminalize_attempt(item, target_state, now) do
      :ok
    end
  end

  defp settle_item(_item, _target_state, _now), do: :ok

  defp transition_item(%RepositoryItem{lease_owner: nil} = item, target_state, now) do
    Persistence.update_without_lease(
      item,
      [item.state],
      RepositoryItem.transition_changeset(item, target_state, %{
        wait_reason:
          if(target_state == :cancel_requested, do: "cancellation_requested", else: nil),
        next_attempt_at: nil
      }),
      now
    )
  end

  defp transition_item(%RepositoryItem{} = item, target_state, now) do
    with :ok <- OperationLease.release(RepositoryItem, item),
         %RepositoryItem{} = released <- Repo.get!(RepositoryItem, item.id) do
      transition_item(%{released | lease_owner: nil, lease_expires_at: nil}, target_state, now)
    else
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp terminalize_attempt(_item, :cancel_requested, _now), do: :ok

  defp terminalize_attempt(
         %RepositoryItem{id: item_id, attempt_count: attempt_count},
         :canceled,
         now
       ) do
    case Repo.one(
           from attempt in ImportAttempt,
             where:
               attempt.repository_item_id == ^item_id and
                 attempt.attempt_number == ^attempt_count and attempt.state == :running
         ) do
      %ImportAttempt{} = attempt ->
        attempt
        |> ImportAttempt.transition_changeset(:canceled, %{terminal_at: now})
        |> Repo.update()
        |> case do
          {:ok, _attempt} -> :ok
          {:error, _changeset} -> {:error, :persistence_unavailable}
        end

      nil ->
        :ok
    end
  end

  defp run_items_for_cancel(run_id) when is_integer(run_id) do
    Repo.all(
      from item in RepositoryItem,
        where: item.import_run_id == ^run_id and item.selected == true,
        order_by: [asc: item.id]
    )
  end

  defp record_cancel_audit(actor, run, request_metadata) do
    metadata = %{
      "source_kind" => Atom.to_string(run.source_kind),
      "state" => Atom.to_string(run.state)
    }

    audit_metadata =
      request_metadata
      |> Map.put("operation_id", "github-import-cancel-#{run.id}")

    case Audit.record(
           actor,
           "github_import.cancel_requested",
           "github_import_run",
           run.id,
           metadata,
           request_metadata: audit_metadata
         ) do
      {:ok, _event} -> :ok
      {:error, _reason} -> {:error, :persistence_unavailable}
    end
  end

  defp kick_reconcilers do
    if Process.whereis(ForgeImports.Reconciler), do: ForgeImports.Reconciler.kick(), else: :ok

    if Process.whereis(ForgeImports.CleanupReconciler),
      do: ForgeImports.CleanupReconciler.kick(),
      else: :ok
  end

  defp locked_run(actor_id, run_id) do
    ImportRun
    |> where([run], run.id == ^run_id and run.actor_user_id == ^actor_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp active_actor(%User{id: actor_id}) do
    case Repo.one(
           from user in User,
             where: user.id == ^actor_id and user.kind == :user and user.state == :active
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
