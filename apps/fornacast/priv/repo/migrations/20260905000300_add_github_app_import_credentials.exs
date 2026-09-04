defmodule Fornacast.Repo.Migrations.AddGitHubAppImportCredentials do
  use Ecto.Migration

  @source_constraint :github_import_runs_credential_source_check
  @identity_constraint :github_import_runs_credential_identity_check
  @consistency_constraint :github_import_runs_credential_consistency_check

  def up do
    unless turso?() do
      drop(constraint(:github_import_runs, @source_constraint))
      drop(constraint(:github_import_runs, @consistency_constraint))

      alter table(:github_import_runs) do
        modify(:github_identity_id, :bigint, null: true)
      end

      create(
        constraint(:github_import_runs, @source_constraint,
          check: "credential_source in ('saved', 'one_time', 'github_app')"
        )
      )

      create(
        constraint(:github_import_runs, @identity_constraint,
          check:
            "(credential_source in ('saved', 'one_time') and github_identity_id is not null) or " <>
              "(credential_source = 'github_app' and github_identity_id is null)"
        )
      )

      create(
        constraint(:github_import_runs, @consistency_constraint,
          check: credential_consistency_check(true)
        )
      )
    end
  end

  def down do
    unless turso?() do
      drop(constraint(:github_import_runs, @consistency_constraint))
      drop(constraint(:github_import_runs, @identity_constraint))
      drop(constraint(:github_import_runs, @source_constraint))

      alter table(:github_import_runs) do
        modify(:github_identity_id, :bigint, null: false)
      end

      create(
        constraint(:github_import_runs, @source_constraint,
          check: "credential_source in ('saved', 'one_time')"
        )
      )

      create(
        constraint(:github_import_runs, @consistency_constraint,
          check: credential_consistency_check(false)
        )
      )
    end
  end

  defp credential_consistency_check(include_github_app?) do
    base =
      "(credential_source = 'saved' and (github_credential_id is not null or state in ('awaiting_credential', 'completed', 'completed_with_warnings', 'canceled', 'failed')) and credential_ciphertext is null and credential_nonce is null and credential_tag is null and credential_key_id is null) or " <>
        "(credential_source = 'one_time' and github_credential_id is null and ((credential_ciphertext is null and credential_nonce is null and credential_tag is null and credential_key_id is null) or " <>
        "(credential_ciphertext is not null and credential_nonce is not null and credential_tag is not null and credential_key_id is not null)))"

    if include_github_app? do
      base <>
        " or (credential_source = 'github_app' and github_credential_id is null and credential_ciphertext is null and credential_nonce is null and credential_tag is null and credential_key_id is null)"
    else
      base
    end
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
