defmodule ForgeImports.TestSupport.ImportReset do
  @moduledoc false

  alias Fornacast.Repo

  @tables ~w(
    github_import_repository_cleanups
    github_import_report_entries
    github_import_page_checkpoints
    github_import_object_mappings
    github_import_attempts
    github_import_repository_items
    github_import_runs
    github_credentials
    github_identities
    audit_events
    repository_collaborators
    repositories
    organization_members
    organizations
    api_keys
    ssh_keys
    users
  )

  @spec reset!() :: :ok
  def reset! do
    for table <- @tables do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table}", [])
    end

    :ok
  end

  @spec postgres?() :: boolean()
  def postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
