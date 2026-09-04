defmodule ForgeMirrors.WebhookMigrationRepo do
  @moduledoc false

  @adapter Application.compile_env(:fornacast, :repo_adapter, Ecto.Adapters.Turso)
  use Ecto.Repo, otp_app: :fornacast, adapter: @adapter
end

defmodule ForgeMirrors.WebhookMigrationTest do
  use ExUnit.Case, async: false

  alias ForgeMirrors.WebhookMigrationRepo
  alias Fornacast.Repo

  @version 20_260_905_000_100

  test "lifecycle migration rolls failed and deferred rows down and back up exactly" do
    if Repo.__adapter__() == Ecto.Adapters.Postgres do
      repo = start_migration_repo!()
      path = Application.app_dir(:fornacast, "priv/repo/migrations")
      prefix = "webhook-migration-#{System.unique_integer([:positive])}"
      failed_guid = "#{prefix}-failed"
      deferred_guid = "#{prefix}-deferred"

      insert_delivery!(repo, failed_guid, "failed", DateTime.utc_now(:second))
      insert_delivery!(repo, deferred_guid, "pending_unsupported", nil)

      try do
        rolled_versions = Ecto.Migrator.run(repo, path, :down, to: @version, log: false)
        assert @version in rolled_versions

        assert %{rows: [["failed", nil]]} =
                 Ecto.Adapters.SQL.query!(
                   repo,
                   "select state, processed_at from mirror_webhook_deliveries where delivery_guid = $1",
                   [failed_guid]
                 )

        assert %{rows: [["ignored", processed_at]]} =
                 Ecto.Adapters.SQL.query!(
                   repo,
                   "select state, processed_at from mirror_webhook_deliveries where delivery_guid = $1",
                   [deferred_guid]
                 )

        assert processed_at

        Ecto.Adapters.SQL.query!(
          repo,
          "update mirror_webhook_deliveries set failure_class = null where delivery_guid = $1",
          [failed_guid]
        )

        assert [@version] = Ecto.Migrator.run(repo, path, :up, to: @version, log: false)

        assert %{rows: [["failed", processed_at, "migration_unknown"]]} =
                 Ecto.Adapters.SQL.query!(
                   repo,
                   "select state, processed_at, failure_class from mirror_webhook_deliveries where delivery_guid = $1",
                   [failed_guid]
                 )

        assert processed_at

        assert_raise Postgrex.Error, ~r/mirror_webhook_deliveries_failure_class_check/, fn ->
          Ecto.Adapters.SQL.query!(
            repo,
            "update mirror_webhook_deliveries set failure_class = null where delivery_guid = $1",
            [failed_guid]
          )
        end

        assert_raise Postgrex.Error,
                     ~r/mirror_webhook_deliveries_internal_failure_count_check/,
                     fn ->
                       Ecto.Adapters.SQL.query!(
                         repo,
                         "update mirror_webhook_deliveries set internal_failure_count = -1 where delivery_guid = $1",
                         [failed_guid]
                       )
                     end
      after
        Ecto.Migrator.run(repo, path, :up, all: true, log: false)

        Ecto.Adapters.SQL.query!(
          repo,
          "delete from mirror_webhook_deliveries where delivery_guid like $1",
          [prefix <> "%"]
        )
      end
    end
  end

  defp insert_delivery!(repo, guid, state, processed_at) do
    now = DateTime.utc_now(:second)
    failure_class = if state == "failed", do: "seed_failure", else: nil

    Ecto.Adapters.SQL.query!(
      repo,
      """
      insert into mirror_webhook_deliveries
        (delivery_guid, hook_id, event, action, installation_id, signature_version,
         raw_payload, state, attempt_count, next_attempt_at, received_at, processed_at,
         failure_class, lock_version, inserted_at, updated_at)
      values ($1, 9001, 'installation', 'created', 44, 'sha256', $2, $3, 1, $4, $4, $5, $6, 1, $4, $4)
      """,
      [
        guid,
        ~s({"action":"created","installation":{"id":44}}),
        state,
        now,
        processed_at,
        failure_class
      ]
    )
  end

  defp start_migration_repo! do
    config =
      Repo.config()
      |> Keyword.delete(:name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({WebhookMigrationRepo, config})
    WebhookMigrationRepo
  end
end
