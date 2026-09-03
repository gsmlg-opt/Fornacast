defmodule ForgeImports.Report do
  @moduledoc false

  import Ecto.Query

  alias ForgeImports.{ImportRun, ReportEntry, RepositoryItem}
  alias Fornacast.Repo

  @run_summary_key "run-summary"
  @repository_outcome_prefix "repository-outcome-"
  @not_selected_prefix "not-selected-"

  @published_states [:published, :completed]

  @spec record(term(), map()) :: {:ok, ReportEntry.t()} | {:error, term()}
  def record(repo, attrs) when is_map(attrs) do
    changeset = ReportEntry.create_changeset(%ReportEntry{}, attrs)

    if changeset.valid? do
      repo.insert(changeset,
        on_conflict: :nothing,
        conflict_target: [:import_run_id, :idempotency_key],
        returning: true
      )
      |> normalize_insert_result(repo, attrs)
    else
      {:error, changeset}
    end
  end

  @spec finalize(pos_integer(), map(), keyword()) ::
          {:ok, ImportRun.t()} | {:error, term()}
  def finalize(run_id, snapshot, opts \\ [])
      when is_integer(run_id) and run_id > 0 and is_map(snapshot) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    repo = Keyword.get(opts, :repo, Repo)

    with %ImportRun{} = run <- repo.get(ImportRun, run_id),
         {:ok, run} <- maybe_short_circuit(run, repo) do
      with :ok <- record_repository_outcomes(repo, run, snapshot),
           :ok <- record_not_selected(repo, run, snapshot),
           {:ok, summarized} <- insert_run_summary(repo, run, snapshot, now),
           {:ok, updated} <- update_run_counts(repo, summarized, snapshot, now) do
        {:ok, updated}
      end
    else
      {:ok, %ImportRun{} = run} -> {:ok, run}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def run_summary_key, do: @run_summary_key

  defp maybe_short_circuit(
         %ImportRun{report_finalized_at: %DateTime{} = finalized_at} = run,
         _repo
       )
       when not is_nil(finalized_at),
       do: {:ok, run}

  defp maybe_short_circuit(run, _repo), do: {:ok, run}

  defp normalize_insert_result({:ok, %ReportEntry{id: id} = entry}, _repo, _attrs)
       when is_integer(id),
       do: {:ok, entry}

  defp normalize_insert_result({:ok, %ReportEntry{id: nil}}, repo, attrs) do
    case repo.one(
           from entry in ReportEntry,
             where:
               entry.import_run_id == ^attrs.import_run_id and
                 entry.idempotency_key == ^attrs.idempotency_key
         ) do
      %ReportEntry{} = entry -> {:ok, entry}
      nil -> {:error, :persistence_unavailable}
    end
  end

  defp normalize_insert_result({:error, changeset}, _repo, _attrs), do: {:error, changeset}

  defp record_repository_outcomes(repo, run, snapshot) do
    Enum.reduce_while(snapshot.selected_items, :ok, fn item, :ok ->
      case record_repository_outcome(repo, run, item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_repository_outcome(repo, run, item) do
    {outcome, classification, summary} = repository_outcome(item)

    case __MODULE__.record(repo, %{
           import_run_id: run.id,
           repository_item_id: item.id,
           idempotency_key: repository_outcome_key(item.id),
           scope: :repository,
           outcome: outcome,
           classification: classification,
           summary: summary,
           metadata: repository_metadata(item),
           source_count: repository_source_count(item)
         }) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_not_selected(repo, run, snapshot) do
    Enum.reduce_while(snapshot.not_selected_items, :ok, fn item, :ok ->
      case __MODULE__.record(repo, %{
             import_run_id: run.id,
             repository_item_id: item.id,
             idempotency_key: not_selected_key(item.id),
             scope: :repository,
             outcome: :not_selected,
             classification: "not_selected",
             summary: "Repository was excluded from the import plan",
             metadata: %{},
             source_count: 0
           }) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_run_summary(repo, run, snapshot, now) do
    {outcome, classification, summary} = run_summary(snapshot)

    case __MODULE__.record(repo, %{
           import_run_id: run.id,
           idempotency_key: @run_summary_key,
           scope: :run,
           outcome: outcome,
           classification: classification,
           summary: summary,
           metadata: run_summary_metadata(snapshot),
           source_count: snapshot.selected_count
         }) do
      {:ok, _entry} ->
        run
        |> Ecto.Changeset.change(report_finalized_at: now)
        |> repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_run_counts(repo, run, snapshot, now) do
    run
    |> Ecto.Changeset.change(
      published_count: snapshot.published,
      skipped_count: snapshot.skipped,
      warning_count: snapshot.warnings,
      failure_count: snapshot.failures,
      selected_count: snapshot.selected_count,
      updated_at: now
    )
    |> repo.update()
  end

  defp repository_outcome(%RepositoryItem{state: state}) when state in @published_states do
    {:imported, "imported", "Repository imported successfully"}
  end

  defp repository_outcome(%RepositoryItem{state: :skipped}) do
    {:skipped, "skipped", "Repository intentionally skipped"}
  end

  defp repository_outcome(%RepositoryItem{state: :failed}) do
    {:failed, "failed", "Repository import failed"}
  end

  defp repository_outcome(%RepositoryItem{state: :canceled}) do
    {:canceled, "canceled", "Repository import canceled"}
  end

  defp repository_outcome(%RepositoryItem{state: state}) do
    {:failed, Atom.to_string(state), "Repository import did not complete"}
  end

  defp repository_metadata(item) do
    %{
      "state" => Atom.to_string(item.state),
      "count" =>
        item.imported_count + item.skipped_count + item.warning_count + item.failure_count
    }
  end

  defp repository_source_count(%RepositoryItem{state: state, imported_count: count})
       when state in @published_states,
       do: max(count, 1)

  defp repository_source_count(%RepositoryItem{imported_count: count}), do: max(count, 0)

  defp run_summary(%{target_state: :completed, warnings: 0}),
    do: {:imported, "completed", "Import completed successfully"}

  defp run_summary(%{target_state: :completed}),
    do: {:warning, "completed_with_warnings", "Import completed with warnings"}

  defp run_summary(%{target_state: :completed_with_warnings}),
    do: {:warning, "completed_with_warnings", "Import completed with warnings"}

  defp run_summary(%{target_state: :canceled}),
    do: {:canceled, "canceled", "Import canceled before completion"}

  defp run_summary(%{target_state: :failed}),
    do: {:failed, "failed", "Import failed without publishing repositories"}

  defp run_summary_metadata(snapshot) do
    %{
      "published" => snapshot.published,
      "skipped" => snapshot.skipped,
      "warnings" => snapshot.warnings,
      "failures" => snapshot.failures,
      "selected" => snapshot.selected_count
    }
  end

  defp repository_outcome_key(item_id),
    do: @repository_outcome_prefix <> Integer.to_string(item_id)

  defp not_selected_key(item_id), do: @not_selected_prefix <> Integer.to_string(item_id)
end
