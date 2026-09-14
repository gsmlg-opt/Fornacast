defmodule Fornacast.Repo.Migrations.LinkImportRunsToMirrorOperations do
  use Ecto.Migration

  def change do
    alter table(:github_import_runs) do
      add(
        :mirror_operation_id,
        references(:mirror_operations, on_delete: :restrict, type: :bigint)
      )
    end

    create(
      unique_index(:github_import_runs, [:mirror_operation_id],
        where:
          "mirror_operation_id IS NOT NULL AND NOT (state = 'failed' AND failure_kind IN (" <>
            "'credential_service_unavailable', 'github_primary_rate_limit', " <>
            "'github_secondary_rate_limit', " <>
            "'github_upstream_unavailable', 'github_unexpected_status', 'github_transport', " <>
            "'github_timeout', 'github_host_unavailable', 'github_request_gate_busy'))",
        name: :github_import_runs_mirror_operation_id_unique_index
      )
    )
  end
end
