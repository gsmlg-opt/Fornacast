defmodule Fornacast.Repo.Migrations.AddRepositoryWriteVersion do
  use Ecto.Migration

  @repository_check "write_version >= 0"
  @replacement_check "replacement_write_version is null or replacement_write_version >= 0"

  def up do
    alter table(:repositories) do
      add(
        :write_version,
        :bigint,
        column_options(
          [null: false, default: 0],
          :repositories_write_version_nonnegative_check,
          @repository_check
        )
      )
    end

    alter table(:github_import_repository_items) do
      add(
        :replacement_write_version,
        :bigint,
        column_options(
          [],
          :github_import_items_replacement_write_version_nonnegative_check,
          @replacement_check
        )
      )
    end

    create_postgres_check(
      :repositories,
      :repositories_write_version_nonnegative_check,
      @repository_check
    )

    create_postgres_check(
      :github_import_repository_items,
      :github_import_items_replacement_write_version_nonnegative_check,
      @replacement_check
    )
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    drop(
      constraint(
        :github_import_repository_items,
        :github_import_items_replacement_write_version_nonnegative_check
      )
    )

    drop(constraint(:repositories, :repositories_write_version_nonnegative_check))

    alter table(:github_import_repository_items) do
      remove(:replacement_write_version)
    end

    alter table(:repositories) do
      remove(:write_version)
    end
  end

  defp column_options(options, name, expression) do
    if turso?(),
      do: Keyword.put(options, :check, name: to_string(name), expr: expression),
      else: options
  end

  defp create_postgres_check(table, name, expression) do
    unless turso?(), do: create(constraint(table, name, check: expression))
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
