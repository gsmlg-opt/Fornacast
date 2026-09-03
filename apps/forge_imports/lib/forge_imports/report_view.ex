defmodule ForgeImports.ReportView do
  @moduledoc "Safe presentation projection for a finalized import report."

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.{ImportRun, ReportEntry, RepositoryItem, RunView}
  alias Fornacast.Repo

  @derive {Inspect,
           only: [
             :id,
             :state,
             :terminal_at,
             :report_finalized_at,
             :counts,
             :repositories,
             :entries,
             :summary,
             :inserted_at,
             :updated_at
           ]}
  defstruct [
    :id,
    :state,
    :terminal_at,
    :report_finalized_at,
    :counts,
    :repositories,
    :entries,
    :summary,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{}

  @spec load(User.t(), pos_integer()) :: {:ok, t()} | {:error, :not_found}
  def load(%User{} = actor, run_id) when is_integer(run_id) and run_id > 0 do
    with %ImportRun{} = run <- actor_run(actor.id, run_id),
         items <- run_items(run.id),
         entries <- run_entries(run.id) do
      {:ok, from_run(run, items, entries)}
    else
      _ -> {:error, :not_found}
    end
  end

  def load(_actor, _run_id), do: {:error, :not_found}

  defp from_run(%ImportRun{} = run, items, entries) do
    base = RunView.from_run(run, items, entries)

    %__MODULE__{
      id: base.id,
      state: base.state,
      terminal_at: base.terminal_at,
      report_finalized_at: base.report_finalized_at,
      counts: base.counts,
      repositories: repository_reports(items, entries),
      entries: Enum.map(entries, &entry_summary/1),
      summary: run_summary_entry(entries),
      inserted_at: base.inserted_at,
      updated_at: base.updated_at
    }
  end

  defp repository_reports(items, entries) do
    entries_by_item =
      entries
      |> Enum.filter(& &1.repository_item_id)
      |> Enum.group_by(& &1.repository_item_id)

    Enum.map(items, fn item ->
      item_entries = Map.get(entries_by_item, item.id, [])
      primary = List.last(item_entries)

      %{
        id: item.id,
        source_full_name: item.source_full_name,
        source_name: item.source_name,
        selected: item.selected,
        state: item.state,
        outcome: primary && primary.outcome,
        classification: primary && primary.classification,
        summary: primary && primary.summary,
        metadata: primary && primary.metadata,
        source_count: primary && primary.source_count
      }
    end)
  end

  defp run_summary_entry(entries) do
    case Enum.find(entries, &(&1.idempotency_key == ForgeImports.Report.run_summary_key())) do
      %ReportEntry{} = entry -> entry_summary(entry)
      nil -> nil
    end
  end

  defp entry_summary(%ReportEntry{} = entry) do
    %{
      repository_item_id: entry.repository_item_id,
      scope: entry.scope,
      outcome: entry.outcome,
      classification: entry.classification,
      summary: entry.summary,
      metadata: entry.metadata,
      source_count: entry.source_count
    }
  end

  defp actor_run(actor_id, run_id) do
    Repo.one(
      from run in ImportRun,
        join: actor in User,
        on: actor.id == run.actor_user_id,
        where:
          run.id == ^run_id and run.actor_user_id == ^actor_id and actor.kind == :user and
            actor.state == :active
    )
  end

  defp run_items(run_id) do
    RepositoryItem
    |> where([item], item.import_run_id == ^run_id)
    |> order_by([item], asc: item.id)
    |> Repo.all()
  end

  defp run_entries(run_id) do
    ReportEntry
    |> where([entry], entry.import_run_id == ^run_id)
    |> order_by([entry], asc: entry.id)
    |> Repo.all()
  end
end
