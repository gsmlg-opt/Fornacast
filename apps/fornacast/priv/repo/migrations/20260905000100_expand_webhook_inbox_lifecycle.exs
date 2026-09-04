defmodule Fornacast.Repo.Migrations.ExpandWebhookInboxLifecycle do
  use Ecto.Migration

  def up do
    unless turso?() do
      alter table(:mirror_webhook_deliveries) do
        add(:internal_failure_count, :integer, null: false, default: 0)
      end

      create(
        constraint(
          :mirror_webhook_deliveries,
          :mirror_webhook_deliveries_internal_failure_count_check,
          check: "internal_failure_count >= 0"
        )
      )

      execute("alter table mirror_webhook_deliveries alter column installation_id drop not null")

      execute(
        "alter table mirror_webhook_deliveries drop constraint mirror_webhook_deliveries_state_check"
      )

      execute("""
      alter table mirror_webhook_deliveries
      add constraint mirror_webhook_deliveries_state_check
      check (state in ('pending', 'pending_unsupported', 'processing', 'completed', 'failed', 'ignored'))
      """)

      execute(
        "alter table mirror_webhook_deliveries drop constraint mirror_webhook_deliveries_processed_at_check"
      )

      execute("""
      update mirror_webhook_deliveries
      set processed_at = coalesce(processed_at, updated_at, timezone('UTC', clock_timestamp())),
          failure_class = coalesce(nullif(failure_class, ''), 'migration_unknown')
      where state = 'failed'
      """)

      execute("""
      alter table mirror_webhook_deliveries
      add constraint mirror_webhook_deliveries_processed_at_check
      check (
        (state in ('completed', 'failed', 'ignored') and processed_at is not null)
        or (state not in ('completed', 'failed', 'ignored') and processed_at is null)
      )
      """)

      execute("""
      alter table mirror_webhook_deliveries
      add constraint mirror_webhook_deliveries_installation_routing_check
      check (installation_id is not null or state = 'ignored')
      """)

      execute("""
      alter table mirror_webhook_deliveries
      add constraint mirror_webhook_deliveries_failure_class_check
      check (
        state <> 'failed'
        or (failure_class is not null and octet_length(failure_class) between 1 and 255)
      )
      """)
    end
  end

  def down do
    unless turso?() do
      execute(
        "alter table mirror_webhook_deliveries drop constraint if exists mirror_webhook_deliveries_failure_class_check"
      )

      execute(
        "alter table mirror_webhook_deliveries drop constraint if exists mirror_webhook_deliveries_installation_routing_check"
      )

      execute(
        "alter table mirror_webhook_deliveries drop constraint mirror_webhook_deliveries_processed_at_check"
      )

      execute("""
      update mirror_webhook_deliveries
      set state = 'ignored',
          processed_at = coalesce(processed_at, timezone('UTC', clock_timestamp())),
          updated_at = timezone('UTC', clock_timestamp())
      where state = 'pending_unsupported'
      """)

      execute("""
      update mirror_webhook_deliveries
      set processed_at = null,
          updated_at = timezone('UTC', clock_timestamp())
      where state = 'failed'
      """)

      execute("""
      alter table mirror_webhook_deliveries
      add constraint mirror_webhook_deliveries_processed_at_check
      check (
        (state in ('completed', 'ignored') and processed_at is not null)
        or (state not in ('completed', 'ignored') and processed_at is null)
      )
      """)

      execute(
        "alter table mirror_webhook_deliveries drop constraint mirror_webhook_deliveries_state_check"
      )

      execute("""
      alter table mirror_webhook_deliveries
      add constraint mirror_webhook_deliveries_state_check
      check (state in ('pending', 'processing', 'completed', 'failed', 'ignored'))
      """)

      execute("delete from mirror_webhook_deliveries where installation_id is null")
      execute("alter table mirror_webhook_deliveries alter column installation_id set not null")

      execute(
        "alter table mirror_webhook_deliveries drop constraint if exists mirror_webhook_deliveries_internal_failure_count_check"
      )

      execute(
        "alter table mirror_webhook_deliveries drop column if exists internal_failure_count"
      )
    end
  end

  defp turso?, do: repo().__adapter__() == Ecto.Adapters.Turso
end
