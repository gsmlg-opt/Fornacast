defmodule ForgeImports.RunView do
  @moduledoc "Safe presentation projection for one actor-owned import run."

  alias ForgeImports.{ImportRun, RepositoryItem}

  @derive {Inspect,
           only: [
             :id,
             :actor_user_id,
             :predecessor_run_id,
             :source,
             :destination,
             :state,
             :resume_state,
             :wait_reason,
             :next_attempt_at,
             :terminal_at,
             :report_finalized_at,
             :counts,
             :repositories,
             :inserted_at,
             :updated_at
           ]}
  defstruct [
    :id,
    :actor_user_id,
    :predecessor_run_id,
    :source,
    :destination,
    :state,
    :resume_state,
    :wait_reason,
    :next_attempt_at,
    :terminal_at,
    :report_finalized_at,
    :counts,
    :repositories,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{}

  def from_run(%ImportRun{} = run, items) when is_list(items) do
    %__MODULE__{
      id: run.id,
      actor_user_id: run.actor_user_id,
      predecessor_run_id: run.predecessor_run_id,
      source: %{
        kind: run.source_kind,
        owner_github_id: run.source_owner_github_id,
        owner_login: run.source_owner_login,
        repository_github_id: run.source_repository_github_id,
        repository_full_name: run.source_repository_full_name
      },
      destination: %{
        organization_action: run.destination_organization_action,
        organization_slug: run.destination_organization_slug,
        organization_id: run.destination_organization_id
      },
      state: run.state,
      resume_state: run.resume_state,
      wait_reason: safe_classification(run.wait_reason),
      next_attempt_at: run.next_attempt_at,
      terminal_at: run.terminal_at,
      report_finalized_at: run.report_finalized_at,
      counts: %{
        selected: run.selected_count,
        published: run.published_count,
        skipped: run.skipped_count,
        warnings: run.warning_count,
        failures: run.failure_count
      },
      repositories: Enum.map(items, &repository_summary/1),
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  defp repository_summary(%RepositoryItem{} = item) do
    %{
      id: item.id,
      predecessor_item_id: item.predecessor_item_id,
      github_repository_id: item.github_repository_id,
      source_full_name: item.source_full_name,
      source_name: item.source_name,
      selected: item.selected,
      destination_owner_id: item.destination_owner_id,
      destination_slug: item.destination_slug,
      destination_visibility: item.destination_visibility,
      conflict_action: item.conflict_action,
      state: item.state,
      resume_state: item.resume_state,
      wait_reason: safe_classification(item.wait_reason),
      next_attempt_at: item.next_attempt_at,
      attempt_count: item.attempt_count,
      counts: %{
        imported: item.imported_count,
        skipped: item.skipped_count,
        warnings: item.warning_count,
        failures: item.failure_count
      }
    }
  end

  defp safe_classification(value), do: ForgeImports.SafeValue.classified_or_nil(value, 120)
end
