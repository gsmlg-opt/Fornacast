defmodule Fornacast.DomainOutbox do
  @moduledoc """
  Provider-neutral transactional outbox for local domain events.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Fornacast.{DomainOutboxEvent, Repo}

  @max_batch_size 100

  @doc false
  @spec record(map()) ::
          {:ok, DomainOutboxEvent.t()} | {:error, Ecto.Changeset.t() | :transaction_required}
  def record(attrs) when is_map(attrs) do
    if Repo.in_transaction?() do
      changeset = DomainOutboxEvent.record_changeset(%DomainOutboxEvent{}, attrs)

      if changeset.valid? do
        aggregate_type = Ecto.Changeset.get_field(changeset, :aggregate_type)
        aggregate_id = Ecto.Changeset.get_field(changeset, :aggregate_id)
        lock_aggregate(Repo, aggregate_type, aggregate_id)
        Repo.insert(changeset, mode: :savepoint)
      else
        {:error, changeset}
      end
    else
      {:error, :transaction_required}
    end
  end

  def record(_attrs), do: {:error, :transaction_required}

  @spec record_multi(Multi.t(), Multi.name(), map() | (map() -> map())) :: Multi.t()
  def record_multi(%Multi{} = multi, key, attrs) when is_map(attrs) or is_function(attrs, 1) do
    Multi.run(multi, key, fn repo, changes ->
      attrs = if is_function(attrs, 1), do: attrs.(changes), else: attrs
      changeset = DomainOutboxEvent.record_changeset(%DomainOutboxEvent{}, attrs)

      if changeset.valid? do
        aggregate_type = Ecto.Changeset.get_field(changeset, :aggregate_type)
        aggregate_id = Ecto.Changeset.get_field(changeset, :aggregate_id)
        lock_aggregate(repo, aggregate_type, aggregate_id)
        repo.insert(changeset)
      else
        {:error, changeset}
      end
    end)
  end

  @spec claim_batch(String.t(), DateTime.t(), pos_integer(), pos_integer()) ::
          {:ok, [DomainOutboxEvent.t()]} | {:error, :invalid_argument | :unavailable}
  def claim_batch(owner, %DateTime{} = now, lease_seconds, limit)
      when is_binary(owner) and is_integer(lease_seconds) and lease_seconds > 0 and
             is_integer(limit) and limit in 1..@max_batch_size do
    with :ok <- validate_owner(owner),
         :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)
      lease_expires_at = DateTime.add(now, lease_seconds, :second)

      case Repo.transaction(fn -> claim_due(owner, now, lease_expires_at, limit) end) do
        {:ok, events} -> {:ok, events}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def claim_batch(_owner, _now, _lease_seconds, _limit), do: {:error, :invalid_argument}

  @spec ack(DomainOutboxEvent.t(), DateTime.t()) ::
          {:ok, DomainOutboxEvent.t()} | {:error, :lost_lease | :invalid_argument | :unavailable}
  def ack(%DomainOutboxEvent{} = event, %DateTime{} = now) do
    transition_owned(event, now, :completed, [])
  end

  def ack(_event, _now), do: {:error, :invalid_argument}

  @spec release(DomainOutboxEvent.t(), DateTime.t(), DateTime.t()) ::
          {:ok, DomainOutboxEvent.t()} | {:error, :lost_lease | :invalid_argument | :unavailable}
  def release(%DomainOutboxEvent{} = event, %DateTime{} = now, %DateTime{} = available_at) do
    with :ok <- validate_utc(available_at) do
      transition_owned(event, now, :pending,
        available_at: DateTime.truncate(available_at, :second)
      )
    end
  end

  def release(_event, _now, _available_at), do: {:error, :invalid_argument}

  @spec fail(DomainOutboxEvent.t(), DateTime.t()) ::
          {:ok, DomainOutboxEvent.t()} | {:error, :lost_lease | :invalid_argument | :unavailable}
  def fail(%DomainOutboxEvent{} = event, %DateTime{} = now) do
    transition_owned(event, now, :failed, [])
  end

  def fail(_event, _now), do: {:error, :invalid_argument}

  @spec recover_stale_leases(DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_argument | :unavailable}
  def recover_stale_leases(%DateTime{} = now) do
    with :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)

      {count, _rows} =
        DomainOutboxEvent
        |> where(
          [event],
          event.state == :processing and event.lease_expires_at <= ^now
        )
        |> Repo.update_all(
          set: [
            state: :pending,
            available_at: now,
            lease_owner: nil,
            lease_expires_at: nil,
            updated_at: now
          ],
          inc: [lock_version: 1]
        )

      {:ok, count}
    end
  rescue
    _error -> {:error, :unavailable}
  end

  def recover_stale_leases(_now), do: {:error, :invalid_argument}

  defp claim_due(owner, now, lease_expires_at, limit) do
    earlier_unfinished =
      from earlier in DomainOutboxEvent,
        where:
          earlier.aggregate_type == parent_as(:candidate).aggregate_type and
            earlier.aggregate_id == parent_as(:candidate).aggregate_id and
            earlier.id < parent_as(:candidate).id and
            earlier.state in [:pending, :processing],
        select: 1

    ids =
      DomainOutboxEvent
      |> from(as: :candidate)
      |> where(
        [candidate: event],
        event.state == :pending and event.available_at <= ^now and
          not exists(earlier_unfinished)
      )
      |> order_by([candidate: event], asc: event.available_at, asc: event.id)
      |> limit(^limit)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> select([candidate: event], event.id)
      |> Repo.all()

    if ids == [] do
      []
    else
      {count, _rows} =
        DomainOutboxEvent
        |> where([event], event.id in ^ids and event.state == :pending)
        |> Repo.update_all(
          set: [
            state: :processing,
            lease_owner: owner,
            lease_expires_at: lease_expires_at,
            updated_at: now
          ],
          inc: [attempt_count: 1, lock_version: 1]
        )

      if count != length(ids), do: Repo.rollback(:claim_conflict)

      DomainOutboxEvent
      |> where([event], event.id in ^ids)
      |> order_by([event], asc: event.available_at, asc: event.id)
      |> Repo.all()
    end
  end

  defp transition_owned(
         %DomainOutboxEvent{
           id: id,
           state: :processing,
           lease_owner: owner,
           lease_expires_at: %DateTime{} = lease_expires_at,
           lock_version: lock_version
         },
         %DateTime{} = now,
         target_state,
         updates
       )
       when is_integer(id) and is_binary(owner) and is_integer(lock_version) and
              target_state in [:pending, :completed, :failed] and is_list(updates) do
    with :ok <- validate_utc(now) do
      now = DateTime.truncate(now, :second)

      case Repo.transaction(fn ->
             query =
               from event in DomainOutboxEvent,
                 where:
                   event.id == ^id and event.state == :processing and
                     event.lease_owner == ^owner and
                     event.lease_expires_at == ^lease_expires_at and
                     event.lock_version == ^lock_version and
                     event.lease_expires_at > fragment("timezone('UTC', clock_timestamp())")

             case Repo.update_all(query,
                    set:
                      updates ++
                        [
                          state: target_state,
                          lease_owner: nil,
                          lease_expires_at: nil,
                          updated_at: now
                        ],
                    inc: [lock_version: 1]
                  ) do
               {1, _rows} -> Repo.get!(DomainOutboxEvent, id)
               {0, _rows} -> Repo.rollback(:lost_lease)
             end
           end) do
        {:ok, updated} -> {:ok, updated}
        {:error, :lost_lease} -> {:error, :lost_lease}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  rescue
    _error -> {:error, :unavailable}
  end

  defp transition_owned(_event, _now, _target_state, _updates),
    do: {:error, :invalid_argument}

  defp lock_aggregate(repo, aggregate_type, aggregate_id) do
    canonical_key =
      IO.iodata_to_binary([
        Integer.to_string(byte_size(aggregate_type)),
        ":",
        aggregate_type,
        Integer.to_string(byte_size(aggregate_id)),
        ":",
        aggregate_id
      ])

    # PostgreSQL hashes the collision-free canonical key to a signed 64-bit advisory-lock key.
    # A hash collision can only serialize unrelated aggregates; it cannot weaken ordering.
    Ecto.Adapters.SQL.query!(
      repo,
      "select pg_advisory_xact_lock(hashtextextended($1::text, 0))",
      [canonical_key],
      log: false
    )

    :ok
  end

  defp validate_owner(owner) do
    if byte_size(owner) in 1..255 and owner == String.trim(owner),
      do: :ok,
      else: {:error, :invalid_argument}
  end

  defp validate_utc(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_utc(_now), do: {:error, :invalid_argument}
end
