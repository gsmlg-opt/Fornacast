defmodule Fornacast.Repo.Migrations.AddGitHubImportDestinationStatus do
  use Ecto.Migration

  @disable_ddl_transaction true

  @reserved_names MapSet.new(~w(
                    assets health setup login logout issues pulls ssh-keys settings
                    organizations repos imports api .well-known
                  ))
  @account_slug ~r/^[a-z0-9][a-z0-9_-]{1,38}[a-z0-9]$/
  @destination_evidence %{
    "reserved_namespace" => {"invalid", "reserved_namespace"},
    "namespace_conflict" => {"conflict", "namespace_conflict"},
    "invalid_namespace" => {"invalid", "invalid_namespace"}
  }

  @status_check "destination_organization_status in ('clean', 'conflict', 'invalid')"
  @classification_check "destination_organization_classification is null or " <>
                          "(length(destination_organization_classification) between 1 and 120 and " <>
                          "length(trim(destination_organization_classification)) > 0)"
  @coherence_check "(destination_organization_status = 'clean' and " <>
                     "destination_organization_classification is null) or " <>
                     "(destination_organization_status in ('conflict', 'invalid') and " <>
                     "destination_organization_classification is not null)"

  def up do
    add_provisional_columns()
    flush()
    backfill_destination_statuses()
    finalize_columns()
  end

  def down do
    # TODO(upstream): gsmlg-dev/concord#81
    if turso?() do
      raise "Turso rollback is disabled until gsmlg-dev/concord#81 is resolved"
    end

    drop(constraint(:github_import_runs, :github_import_runs_destination_status_coherence_check))

    drop(constraint(:github_import_runs, :github_import_runs_destination_classification_check))

    drop(constraint(:github_import_runs, :github_import_runs_destination_status_check))

    alter table(:github_import_runs) do
      remove(:destination_organization_classification)
      remove(:destination_organization_status)
    end
  end

  defp add_provisional_columns do
    if turso?() do
      execute(
        "ALTER TABLE github_import_runs " <>
          "ADD COLUMN destination_organization_status TEXT"
      )

      execute(
        "ALTER TABLE github_import_runs " <>
          "ADD COLUMN destination_organization_classification TEXT"
      )
    else
      alter table(:github_import_runs) do
        add(:destination_organization_status, :string)
        add(:destination_organization_classification, :string)
      end
    end
  end

  defp finalize_columns do
    if turso?(), do: rebuild_turso_runs(), else: finalize_postgres_columns()
  end

  defp finalize_postgres_columns do
    execute("""
    ALTER TABLE github_import_runs
      ALTER COLUMN destination_organization_status SET NOT NULL,
      ALTER COLUMN destination_organization_status SET DEFAULT 'clean',
      ADD CONSTRAINT github_import_runs_destination_status_check CHECK (#{@status_check}),
      ADD CONSTRAINT github_import_runs_destination_classification_check
        CHECK (#{@classification_check}),
      ADD CONSTRAINT github_import_runs_destination_status_coherence_check
        CHECK (#{@coherence_check})
    """)
  end

  defp rebuild_turso_runs do
    migration_repo = repo()

    migration_repo.checkout(
      fn ->
        query!(migration_repo, "PRAGMA foreign_keys = OFF")

        try do
          create_sql = turso_runs_create_sql!(migration_repo)

          query!(migration_repo, create_sql)

          query!(
            migration_repo,
            "INSERT INTO github_import_runs_new SELECT * FROM github_import_runs"
          )

          query!(migration_repo, "DROP TABLE github_import_runs")

          query!(
            migration_repo,
            "ALTER TABLE github_import_runs_new RENAME TO github_import_runs"
          )

          query!(
            migration_repo,
            "CREATE INDEX github_import_runs_actor_user_id_inserted_at_index " <>
              "ON github_import_runs (actor_user_id, inserted_at)"
          )

          query!(
            migration_repo,
            "CREATE INDEX github_import_runs_recovery_index " <>
              "ON github_import_runs (state, next_attempt_at, lease_expires_at, id)"
          )

          query!(
            migration_repo,
            "CREATE INDEX github_import_runs_github_credential_id_index " <>
              "ON github_import_runs (github_credential_id)"
          )

          query!(
            migration_repo,
            "CREATE INDEX github_import_runs_predecessor_run_id_index " <>
              "ON github_import_runs (predecessor_run_id)"
          )
        after
          query!(migration_repo, "PRAGMA foreign_keys = ON")
        end
      end,
      timeout: :infinity
    )
  end

  defp turso_runs_create_sql!(migration_repo) do
    migration_repo
    |> query!("select sql from sqlite_schema where type = 'table' and name = ?", [
      "github_import_runs"
    ])
    |> Map.fetch!(:rows)
    |> then(fn
      [[sql]] when is_binary(sql) -> sql
      _unexpected -> raise "github_import_runs schema is unavailable"
    end)
    |> replace_once!(
      "CREATE TABLE github_import_runs",
      "CREATE TABLE github_import_runs_new"
    )
    |> replace_once!(
      "destination_organization_status TEXT",
      "destination_organization_status TEXT NOT NULL DEFAULT 'clean' " <>
        "CONSTRAINT github_import_runs_destination_status_check " <>
        "CHECK (#{@status_check})"
    )
    |> replace_once!(
      "destination_organization_classification TEXT",
      "destination_organization_classification TEXT " <>
        "CONSTRAINT github_import_runs_destination_classification_check " <>
        "CHECK (#{@classification_check}) " <>
        "CONSTRAINT github_import_runs_destination_status_coherence_check " <>
        "CHECK (#{@coherence_check})"
    )
  end

  defp replace_once!(source, pattern, replacement) do
    if length(:binary.matches(source, pattern)) == 1 do
      String.replace(source, pattern, replacement, global: false)
    else
      raise "github_import_runs schema does not match the expected provisional shape"
    end
  end

  defp backfill_destination_statuses do
    usernames =
      repo()
      |> query!("select username from users")
      |> Map.fetch!(:rows)
      |> MapSet.new(fn [username] -> normalize_slug(username) end)

    evidence =
      repo()
      |> query!(
        "select import_run_id, wait_reason from github_import_repository_items " <>
          "where wait_reason is not null order by id"
      )
      |> Map.fetch!(:rows)
      |> Enum.reduce(%{}, fn [run_id, reason], acc ->
        if Map.has_key?(@destination_evidence, reason),
          do: Map.put_new(acc, run_id, Map.fetch!(@destination_evidence, reason)),
          else: acc
      end)

    rows =
      repo()
      |> query!(
        "select id, source_kind, destination_organization_action, " <>
          "destination_organization_slug from github_import_runs"
      )
      |> Map.fetch!(:rows)

    Enum.each(rows, fn [id, source_kind, action, slug] ->
      {status, classification} =
        destination_status(id, source_kind, action, slug, usernames, evidence)

      [status_placeholder, classification_placeholder, id_placeholder] = placeholders(3)

      query!(
        repo(),
        "update github_import_runs set destination_organization_status = " <>
          "#{status_placeholder}, destination_organization_classification = " <>
          "#{classification_placeholder} where id = #{id_placeholder}",
        [status, classification, id]
      )
    end)
  end

  defp destination_status(_id, "repository", _action, _slug, _usernames, _evidence),
    do: {"clean", nil}

  defp destination_status(_id, "organization", "existing", _slug, _usernames, _evidence),
    do: {"clean", nil}

  defp destination_status(id, "organization", "new", slug, usernames, evidence) do
    case Map.get(evidence, id) do
      nil -> destination_slug_status(slug, usernames)
      persisted_evidence -> persisted_evidence
    end
  end

  defp destination_status(_id, _source_kind, _action, _slug, _usernames, _evidence),
    do: {"invalid", "invalid_namespace"}

  defp destination_slug_status(slug, usernames) when is_binary(slug) do
    normalized = normalize_slug(slug)

    cond do
      MapSet.member?(@reserved_names, normalized) ->
        {"invalid", "reserved_namespace"}

      not String.valid?(normalized) or not Regex.match?(@account_slug, normalized) ->
        {"invalid", "invalid_namespace"}

      MapSet.member?(usernames, normalized) ->
        {"conflict", "namespace_conflict"}

      true ->
        {"clean", nil}
    end
  end

  defp destination_slug_status(_slug, _usernames), do: {"invalid", "invalid_namespace"}

  defp normalize_slug(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_slug(_value), do: ""

  defp placeholders(count) do
    if turso?(), do: List.duplicate("?", count), else: Enum.map(1..count, &"$#{&1}")
  end

  defp query!(repo, sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(repo, sql, params, log: false)

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
