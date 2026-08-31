defmodule Fornacast.Repo.Migrations.AddRepositoryImportLifecycle do
  use Ecto.Migration

  @lifecycle_check "lifecycle in ('importing', 'ready', 'tombstoned')"
  @generation_check "generation > 0"

  def up do
    alter table(:repositories) do
      add(
        :lifecycle,
        :string,
        column_options(
          [null: false, default: "ready"],
          :repositories_lifecycle_check,
          @lifecycle_check
        )
      )

      add(
        :generation,
        :integer,
        column_options(
          [null: false, default: 1],
          :repositories_generation_positive_check,
          @generation_check
        )
      )

      add(:storage_reclaimed_at, :utc_datetime)
    end

    create_postgres_check(
      :repositories,
      :repositories_lifecycle_check,
      @lifecycle_check
    )

    create_postgres_check(
      :repositories,
      :repositories_generation_positive_check,
      @generation_check
    )

    create(
      index(:repositories, [:lifecycle, :deleted_at, :storage_reclaimed_at, :id],
        name: :repositories_import_cleanup_index
      )
    )
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    drop(
      index(:repositories, [:lifecycle, :deleted_at, :storage_reclaimed_at, :id],
        name: :repositories_import_cleanup_index
      )
    )

    drop(constraint(:repositories, :repositories_generation_positive_check))
    drop(constraint(:repositories, :repositories_lifecycle_check))

    alter table(:repositories) do
      remove(:storage_reclaimed_at)
      remove(:generation)
      remove(:lifecycle)
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
