defmodule ForgeImports.RunAggregator do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User

  alias ForgeImports.{ImportRun, Persistence, Report, RepositoryItem}
  alias Fornacast.{Audit, Repo}

  @aggregatable_run_states [:running, :cancel_requested]
  @terminal_run_states [:completed, :completed_with_warnings, :canceled, :failed]
  @selected_terminal_states [:published, :completed, :skipped, :canceled, :failed]
  @published_states [:published, :completed]
  @active_item_states [
    :queued,
    :awaiting_resolution,
    :staging_git,
    :git_staged,
    :staging_metadata,
    :ready_to_publish,
    :publishing,
    :cancel_requested,
    :awaiting_credential
  ]

  @spec finish_if_terminal(pos_integer(), keyword()) ::
          :pending | {:ok, ImportRun.t()} | {:error, term()}
  def finish_if_terminal(run_id, opts \\ []) when is_integer(run_id) and run_id > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))

    transaction = fn ->
      Repo.transaction(fn ->
        case locked_run(run_id) do
          nil ->
            Repo.rollback(:not_found)

          %ImportRun{state: state} = run when state in @terminal_run_states ->
            run

          %ImportRun{} = run when run.state not in @aggregatable_run_states ->
            Repo.rollback(:pending)

          %ImportRun{} = run ->
            if blocking_item?(run.id) do
              Repo.rollback(:pending)
            else
              case finalize_run(run, now) do
                {:ok, terminal} -> terminal
                {:error, reason} -> Repo.rollback(reason)
              end
            end
        end
      end)
    end

    case Persistence.with_retry(transaction) do
      {:ok, %ImportRun{} = run} -> {:ok, run}
      {:error, :pending} -> :pending
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec terminal_state(map()) :: atom()
  def terminal_state(snapshot) do
    cond do
      snapshot.all_published? and snapshot.warnings == 0 ->
        :completed

      snapshot.all_skipped? ->
        :completed

      snapshot.published > 0 and snapshot.all_terminal? ->
        :completed_with_warnings

      snapshot.cancel_requested? and snapshot.unpublished > 0 and snapshot.published == 0 ->
        :canceled

      snapshot.cancel_requested? and snapshot.unpublished > 0 ->
        :completed_with_warnings

      snapshot.published == 0 and snapshot.runnable_failed? ->
        :failed

      snapshot.all_terminal? ->
        :completed_with_warnings

      true ->
        :failed
    end
  end

  defp finalize_run(%ImportRun{} = run, now) do
    snapshot = build_snapshot(run)
    target_state = terminal_state(snapshot)

    with {:ok, reported} <-
           Report.finalize(run.id, Map.put(snapshot, :target_state, target_state),
             now: now,
             repo: Repo
           ),
         {:ok, terminal} <- persist_terminal_run(reported, target_state, now),
         :ok <- record_completion_audit(terminal, snapshot, now) do
      {:ok, terminal}
    end
  end

  defp blocking_item?(run_id) do
    Repo.exists?(
      from item in RepositoryItem,
        where:
          item.import_run_id == ^run_id and item.selected == true and
            item.state in ^@active_item_states
    )
  end

  defp build_snapshot(%ImportRun{} = run) do
    items = Repo.all(from item in RepositoryItem, where: item.import_run_id == ^run.id)
    selected_items = Enum.filter(items, & &1.selected)
    not_selected_items = Enum.reject(items, & &1.selected)

    published = Enum.count(selected_items, &(&1.state in @published_states))
    skipped = Enum.count(selected_items, &(&1.state == :skipped))

    failures =
      Enum.reduce(selected_items, 0, fn item, acc -> acc + max(item.failure_count, 0) end)

    warnings =
      Enum.reduce(selected_items, 0, fn item, acc -> acc + item.warning_count end)

    all_terminal? =
      Enum.all?(selected_items, &(&1.state in @selected_terminal_states))

    all_published? =
      selected_items != [] and
        Enum.all?(selected_items, &(&1.state in @published_states))

    all_skipped? =
      selected_items != [] and Enum.all?(selected_items, &(&1.state == :skipped))

    unpublished = length(selected_items) - published

    runnable_failed? =
      published == 0 and Enum.any?(selected_items, &(&1.state == :failed))

    cancel_requested? =
      run.state == :cancel_requested or not is_nil(run.cancellation_requested_at)

    %{
      run: run,
      selected_items: selected_items,
      not_selected_items: not_selected_items,
      selected_count: length(selected_items),
      published: published,
      skipped: skipped,
      failures: failures,
      warnings: warnings,
      all_terminal?: all_terminal?,
      all_published?: all_published?,
      all_skipped?: all_skipped?,
      unpublished: unpublished,
      runnable_failed?: runnable_failed?,
      cancel_requested?: cancel_requested?
    }
  end

  defp persist_terminal_run(%ImportRun{state: state} = run, target_state, _now)
       when state in @terminal_run_states and state == target_state do
    {:ok, run}
  end

  defp persist_terminal_run(%ImportRun{} = run, target_state, now) do
    changeset =
      ImportRun.transition_changeset(run, target_state, %{terminal_at: now})

    if changeset.valid? do
      Repo.update(changeset)
    else
      {:error, :invalid_transition}
    end
  end

  defp record_completion_audit(%ImportRun{} = run, snapshot, now) do
    if completion_audit_exists?(run.id) do
      :ok
    else
      insert_completion_audit(run, snapshot, now)
    end
  end

  defp insert_completion_audit(%ImportRun{} = run, snapshot, now) do
    case Repo.get(User, run.actor_user_id) do
      %User{} = actor ->
        action = completion_action(run.state)

        case Audit.record(
               actor,
               action,
               "github_import_run",
               run.id,
               audit_metadata(snapshot),
               request_metadata: run.request_metadata,
               operation_id: "github-import-complete-#{run.id}-#{DateTime.to_unix(now)}"
             ) do
          {:ok, _event} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp completion_audit_exists?(run_id) do
    Repo.exists?(
      from event in Fornacast.AuditEvent,
        where:
          event.target_type == "github_import_run" and event.target_id == ^to_string(run_id) and
            event.action in [
              "github_import.completed",
              "github_import.completed_with_warnings",
              "github_import.canceled",
              "github_import.failed"
            ]
    )
  end

  defp completion_action(:completed), do: "github_import.completed"
  defp completion_action(:completed_with_warnings), do: "github_import.completed_with_warnings"
  defp completion_action(:canceled), do: "github_import.canceled"
  defp completion_action(:failed), do: "github_import.failed"

  defp audit_metadata(snapshot) do
    %{
      "published" => snapshot.published,
      "skipped" => snapshot.skipped,
      "warnings" => snapshot.warnings,
      "failures" => snapshot.failures,
      "selected" => snapshot.selected_count
    }
  end

  defp locked_run(run_id) do
    query =
      if postgres?(),
        do: lock(ImportRun, "FOR UPDATE"),
        else: ImportRun

    query
    |> where([run], run.id == ^run_id)
    |> Repo.one()
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
