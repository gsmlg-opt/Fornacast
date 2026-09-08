defmodule Fornacast.Repo.Migrations.AddPullImportSourceEvidence do
  use Ecto.Migration

  def up do
    alter table(:github_import_object_mappings) do
      add(:source_evidence, :map)
    end

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      create(
        constraint(
          :github_import_object_mappings,
          :github_import_object_mappings_source_evidence_check,
          check:
            "source_evidence is null or (jsonb_typeof(source_evidence) = 'object' " <>
              "and octet_length(source_evidence::text) <= 16384)"
        )
      )
    end
  end

  def down do
    unless repo().__adapter__() == Ecto.Adapters.Turso do
      drop(
        constraint(
          :github_import_object_mappings,
          :github_import_object_mappings_source_evidence_check
        )
      )
    end

    alter table(:github_import_object_mappings) do
      remove(:source_evidence)
    end
  end
end
