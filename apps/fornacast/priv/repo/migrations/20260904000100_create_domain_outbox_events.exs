defmodule Fornacast.Repo.Migrations.CreateDomainOutboxEvents do
  use Ecto.Migration

  @string_columns ~w(event_id aggregate_type aggregate_id event_type causation_id correlation_id lease_owner)a

  def change do
    create table(:domain_outbox_events) do
      add(:event_id, :string, null: false)
      add(:aggregate_type, :string, null: false)
      add(:aggregate_id, :string, null: false)
      add(:event_type, :string, null: false)
      add(:origin, :string, null: false)
      add(:causation_id, :string)
      add(:correlation_id, :string)
      add(:payload, :map, null: false, default: %{})
      add(:state, :string, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:available_at, :utc_datetime, null: false)
      add(:lease_owner, :string)
      add(:lease_expires_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:domain_outbox_events, [:event_id]))

    create(
      index(
        :domain_outbox_events,
        [:state, :available_at, :lease_expires_at, :id],
        name: :domain_outbox_events_claimable_index,
        where: "state in ('pending', 'processing')"
      )
    )

    create(
      index(
        :domain_outbox_events,
        [:state, :lease_expires_at, :id],
        name: :domain_outbox_events_stale_lease_index,
        where: "state = 'processing'"
      )
    )

    create(
      index(
        :domain_outbox_events,
        [:aggregate_type, :aggregate_id, :id],
        name: :domain_outbox_events_aggregate_order_index
      )
    )

    unless turso?() do
      for column <- @string_columns do
        optional =
          if column in [:causation_id, :correlation_id, :lease_owner],
            do: "#{column} is null or ",
            else: ""

        create(
          constraint(
            :domain_outbox_events,
            String.to_atom("domain_outbox_events_#{column}_bounds_check"),
            check:
              "#{optional}(octet_length(#{column}) between 1 and 255 and #{column} = btrim(#{column}))"
          )
        )
      end

      create(
        constraint(:domain_outbox_events, :domain_outbox_events_origin_check,
          check: "origin in ('fornacast', 'github', 'system')"
        )
      )

      create(
        constraint(:domain_outbox_events, :domain_outbox_events_state_check,
          check: "state in ('pending', 'processing', 'completed', 'failed')"
        )
      )

      create(
        constraint(:domain_outbox_events, :domain_outbox_events_attempt_count_check,
          check: "attempt_count >= 0"
        )
      )

      create(
        constraint(:domain_outbox_events, :domain_outbox_events_lock_version_check,
          check: "lock_version >= 0"
        )
      )

      create(
        constraint(:domain_outbox_events, :domain_outbox_events_payload_check,
          check: "jsonb_typeof(payload) = 'object' and pg_column_size(payload) <= 65536"
        )
      )

      create(
        constraint(:domain_outbox_events, :domain_outbox_events_state_lease_check,
          check:
            "(state = 'processing' and lease_owner is not null and lease_expires_at is not null) or " <>
              "(state <> 'processing' and lease_owner is null and lease_expires_at is null)"
        )
      )
    end
  end

  defp turso? do
    repo().__adapter__() == Ecto.Adapters.Turso
  end
end
