defmodule Fornacast.Repo.Migrations.AlignImportCleanupRepositorySlugs do
  use Ecto.Migration

  @table "github_import_repository_cleanups"
  @constraint "github_import_cleanups_evidence_check"
  @old_slug "^[a-z0-9][a-z0-9._-]{0,62}$"
  @canonical_slug "^[a-z0-9._-]{1,100}$"

  def up, do: update_slug_contract(:up)
  def down, do: update_slug_contract(:down)

  defp update_slug_contract(direction) do
    # The dormant Turso adapter is compile-only; PostgreSQL owns runtime constraints.
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      execute(fn ->
        %{rows: [[definition]]} =
          repo().query!("""
          SELECT pg_get_constraintdef(oid)
          FROM pg_constraint
          WHERE conrelid = '#{@table}'::regclass AND conname = '#{@constraint}'
          """)

        updated = rewrite_slug_contract(definition, direction)
        repo().query!("ALTER TABLE #{@table} DROP CONSTRAINT #{@constraint}")
        # Keep validation and the default migration transaction: incompatible rows
        # abort rollback and restore the current constraint instead of losing evidence.
        repo().query!("ALTER TABLE #{@table} ADD CONSTRAINT #{@constraint} #{updated}")
      end)
    end
  end

  defp rewrite_slug_contract(definition, :up) do
    definition
    |> replace_exact!(@old_slug, @canonical_slug, 4)
    |> replace_exact!(trailing_dot_clause("attempt_decision"), "", 3)
    |> replace_exact!(trailing_dot_clause("publication_marker"), "", 1)
  end

  defp rewrite_slug_contract(definition, :down) do
    definition = replace_exact!(definition, @canonical_slug, @old_slug, 4)

    Enum.reduce([{"attempt_decision", 3}, {"publication_marker", 1}], definition, fn
      {object, count}, expression ->
        git_suffix = " AND ((evidence #>> '{#{object},slug}'::text[]) !~~ '%.git'::text)"
        replace_exact!(expression, git_suffix, trailing_dot_clause(object) <> git_suffix, count)
    end)
  end

  defp trailing_dot_clause(object),
    do: " AND ((evidence #>> '{#{object},slug}'::text[]) !~~ '%.'::text)"

  defp replace_exact!(definition, old, new, count) do
    unless length(String.split(definition, old)) == count + 1 do
      raise "unexpected cleanup evidence slug constraint; refusing to replace #{@constraint}"
    end

    String.replace(definition, old, new)
  end
end
