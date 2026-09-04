defmodule Fornacast.DomainOutboxTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias Fornacast.{AuditEvent, DomainOutbox, DomainOutboxEvent, Repo}

  @moduletag :persistence

  setup context do
    if context[:independent_connections] != true do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    end

    :ok
  end

  test "record_multi rolls the event back with its domain mutation" do
    event_id = Ecto.UUID.generate()

    result =
      Multi.new()
      |> Multi.insert(
        :mutation,
        AuditEvent.changeset(%AuditEvent{}, %{
          action: "domain.outbox.test",
          target_type: "test",
          target_id: event_id,
          metadata: %{}
        })
      )
      |> DomainOutbox.record_multi(:event, %{
        event_id: event_id,
        aggregate_type: "repository",
        aggregate_id: "42",
        event_type: "repository.created",
        origin: :fornacast,
        payload: %{"repository_id" => 42}
      })
      |> Multi.error(:forced_failure, :rollback)
      |> Repo.transaction()

    assert {:error, :forced_failure, :rollback, _changes} = result
    refute Repo.get_by(AuditEvent, action: "domain.outbox.test", target_id: event_id)
    refute Repo.get_by(DomainOutboxEvent, event_id: event_id)
  end

  test "record_multi rejects a duplicate event ID" do
    event_id = Ecto.UUID.generate()
    attrs = event_attrs(event_id)

    assert {:ok, %{event: %DomainOutboxEvent{}}} = record_event(attrs)

    assert {:error, :event, %Ecto.Changeset{} = changeset, %{}} = record_event(attrs)
    assert %{event_id: ["has already been taken"]} = errors_on(changeset)

    assert Repo.aggregate(
             from(event in DomainOutboxEvent, where: event.event_id == ^event_id),
             :count,
             :id
           ) == 1
  end

  test "record_multi always starts events in the pending lifecycle" do
    attrs =
      event_attrs(Ecto.UUID.generate())
      |> Map.merge(%{state: :failed, attempt_count: 9})

    assert {:ok,
            %{
              event: %DomainOutboxEvent{
                state: :pending,
                attempt_count: 0,
                lock_version: 0,
                lease_owner: nil,
                lease_expires_at: nil
              }
            }} = record_event(attrs)
  end

  test "record_multi preserves origin, causation, and correlation metadata" do
    attrs =
      event_attrs(Ecto.UUID.generate())
      |> Map.merge(%{
        origin: :github,
        causation_id: "webhook:delivery-123",
        correlation_id: "sync:repository-42"
      })

    assert {:ok,
            %{
              event: %DomainOutboxEvent{
                origin: :github,
                causation_id: "webhook:delivery-123",
                correlation_id: "sync:repository-42"
              }
            }} = record_event(attrs)
  end

  test "the PostgreSQL payload bound is mapped back to the payload field" do
    oversized_payload = %{
      "data" => :crypto.strong_rand_bytes(70_000) |> Base.encode64()
    }

    changeset =
      %DomainOutboxEvent{}
      |> DomainOutboxEvent.record_changeset(event_attrs(Ecto.UUID.generate()))
      |> Ecto.Changeset.put_change(:payload, oversized_payload)

    assert {:error, changeset} = Repo.insert(changeset)
    assert %{payload: ["is too large"]} = errors_on(changeset)
  end

  test "claim_batch leases due events in insertion order" do
    now = DateTime.utc_now(:second)

    assert {:ok, %{event: first}} =
             record_event(event_attrs(Ecto.UUID.generate()) |> Map.put(:available_at, now))

    assert {:ok, %{event: second}} =
             record_event(
               event_attrs(Ecto.UUID.generate())
               |> Map.put(:aggregate_id, "43")
               |> Map.put(:available_at, now)
             )

    assert {:ok, [claimed_first, claimed_second]} =
             DomainOutbox.claim_batch("worker-a", now, 30, 2)

    assert [claimed_first.id, claimed_second.id] == [first.id, second.id]

    for claimed <- [claimed_first, claimed_second] do
      assert claimed.state == :processing
      assert claimed.attempt_count == 1
      assert claimed.lease_owner == "worker-a"
      assert claimed.lease_expires_at == DateTime.add(now, 30, :second)
    end
  end

  test "recover_stale_leases makes expired work claimable again" do
    now = DateTime.utc_now(:second)

    assert {:ok, %{event: event}} =
             record_event(event_attrs(Ecto.UUID.generate()) |> Map.put(:available_at, now))

    assert {:ok, [%DomainOutboxEvent{id: event_id, lock_version: 1} = stale_claim]} =
             DomainOutbox.claim_batch("worker-a", now, 5, 1)

    assert event_id == event.id
    assert {:ok, 0} = DomainOutbox.recover_stale_leases(DateTime.add(now, 4, :second))
    assert {:ok, 1} = DomainOutbox.recover_stale_leases(DateTime.add(now, 5, :second))

    assert %DomainOutboxEvent{
             state: :pending,
             attempt_count: 1,
             lock_version: 2,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(DomainOutboxEvent, event.id)

    assert {:ok,
            [
              %DomainOutboxEvent{
                id: ^event_id,
                attempt_count: 2,
                lock_version: 3,
                lease_owner: "worker-a"
              }
            ]} = DomainOutbox.claim_batch("worker-a", DateTime.add(now, 5, :second), 30, 1)

    assert {:error, :lost_lease} =
             DomainOutbox.ack(stale_claim, DateTime.add(now, 6, :second))
  end

  test "ack completes only the currently owned lease" do
    now = DateTime.utc_now(:second)

    assert {:ok, %{event: event}} =
             record_event(event_attrs(Ecto.UUID.generate()) |> Map.put(:available_at, now))

    assert {:ok, [%DomainOutboxEvent{lock_version: 1} = claimed]} =
             DomainOutbox.claim_batch("worker-a", now, 30, 1)

    assert {:ok, %DomainOutboxEvent{state: :completed, lock_version: 2} = completed} =
             DomainOutbox.ack(claimed, DateTime.add(now, 1, :second))

    assert completed.lease_owner == nil
    assert completed.lease_expires_at == nil
    assert {:error, :lost_lease} = DomainOutbox.ack(claimed, DateTime.add(now, 2, :second))
    assert Repo.get!(DomainOutboxEvent, event.id).state == :completed
  end

  test "release explicitly reschedules owned work" do
    now = DateTime.utc_now(:second)
    retry_at = DateTime.add(now, 60, :second)

    assert {:ok, %{event: _event}} =
             record_event(event_attrs(Ecto.UUID.generate()) |> Map.put(:available_at, now))

    assert {:ok, [claimed]} = DomainOutbox.claim_batch("worker-a", now, 30, 1)

    assert {:ok,
            %DomainOutboxEvent{
              state: :pending,
              attempt_count: 1,
              available_at: ^retry_at,
              lock_version: 2
            }} = DomainOutbox.release(claimed, DateTime.add(now, 1, :second), retry_at)

    assert {:ok, []} = DomainOutbox.claim_batch("worker-b", DateTime.add(now, 59, :second), 30, 1)

    assert {:ok, [%DomainOutboxEvent{attempt_count: 2, lock_version: 3}]} =
             DomainOutbox.claim_batch("worker-b", retry_at, 30, 1)
  end

  test "fail terminally records an owned delivery failure" do
    now = DateTime.utc_now(:second)

    assert {:ok, %{event: event}} =
             record_event(event_attrs(Ecto.UUID.generate()) |> Map.put(:available_at, now))

    assert {:ok, [claimed]} = DomainOutbox.claim_batch("worker-a", now, 30, 1)

    assert {:ok, %DomainOutboxEvent{state: :failed, lock_version: 2}} =
             DomainOutbox.fail(claimed, DateTime.add(now, 1, :second))

    assert {:ok, []} =
             DomainOutbox.claim_batch("worker-b", DateTime.add(now, 2, :second), 30, 1)

    assert Repo.get!(DomainOutboxEvent, event.id).state == :failed
  end

  @tag independent_connections: true
  test "concurrent claimers preserve ordering within one aggregate" do
    now = DateTime.utc_now(:second)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(DomainOutboxEvent) end)
    end)

    {first, second} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(DomainOutboxEvent)

        {:ok, %{event: first}} =
          record_event(event_attrs(Ecto.UUID.generate()) |> Map.put(:available_at, now))

        {:ok, %{event: second}} =
          record_event(event_attrs(Ecto.UUID.generate()) |> Map.put(:available_at, now))

        {first, second}
      end)

    claims =
      ["worker-a", "worker-b"]
      |> Task.async_stream(
        fn owner ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            DomainOutbox.claim_batch(owner, now, 30, 1)
          end)
        end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, {:ok, events}} -> events end)

    assert Enum.sort(Enum.map(claims, &length/1)) == [0, 1]
    assert [[%DomainOutboxEvent{id: claimed_id}]] = Enum.reject(claims, &(&1 == []))
    assert claimed_id == first.id
    assert Repo.get!(DomainOutboxEvent, second.id).state == :pending
  end

  defp record_event(attrs) do
    Multi.new()
    |> DomainOutbox.record_multi(:event, attrs)
    |> Repo.transaction()
  end

  defp event_attrs(event_id) do
    %{
      event_id: event_id,
      aggregate_type: "repository",
      aggregate_id: "42",
      event_type: "repository.created",
      origin: :fornacast,
      payload: %{"repository_id" => 42}
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
