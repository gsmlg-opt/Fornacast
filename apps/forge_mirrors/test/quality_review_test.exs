defmodule ForgeMirrors.QualityReviewTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.Multi
  alias Fornacast.{DomainOutbox, DomainOutboxEvent, Repo}
  alias ForgeMirrors.{MirrorOperation, MirrorRefState}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "a restarted outbox dispatcher recovers a stale aggregate head before claiming" do
    Repo.delete_all(DomainOutboxEvent)
    now = DateTime.utc_now(:second)
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    first = outbox_event!(repository_mirror, "stale-head-first", now)
    second = outbox_event!(repository_mirror, "stale-head-second", now)

    assert {:ok, [%DomainOutboxEvent{id: first_id} = stale]} =
             DomainOutbox.claim_batch("crashed-dispatcher", now, 30, 1)

    assert first_id == first.id
    expired_at = DateTime.add(DateTime.utc_now(:second), -1)

    Repo.update_all(from(event in DomainOutboxEvent, where: event.id == ^stale.id),
      set: [lease_expires_at: expired_at]
    )

    restarted_at = DateTime.utc_now(:second)

    assert {:ok, [{:ok, "stale-head-first", {:materialized, [_operation_id]}}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("restarted-dispatcher", restarted_at,
               lease_seconds: 30,
               batch_size: 1
             )

    assert Repo.get!(DomainOutboxEvent, first.id).state == :completed
    assert Repo.get!(DomainOutboxEvent, second.id).state == :pending

    assert {:ok, [{:ok, "stale-head-second", {:materialized, [_operation_id]}}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("restarted-dispatcher", restarted_at,
               lease_seconds: 30,
               batch_size: 1
             )
  end

  test "paused and revoked organizations block new external effect markers" do
    for target <- [:paused, :revoked] do
      organization_mirror = active_organization_mirror_fixture()
      operation = claimed_repository_operation!(organization_mirror)

      result =
        case target do
          :paused ->
            ForgeMirrors.pause(
              organization_owner_fixture(organization_mirror),
              organization_mirror
            )

          :revoked ->
            ForgeMirrors.transition_organization_mirror(
              organization_owner_fixture(organization_mirror),
              organization_mirror,
              :revoked
            )
        end

      assert {:ok, transitioned} = result

      expected_error = if transitioned.state == :paused, do: :paused, else: :revoked

      assert {:error, ^expected_error} =
               ForgeMirrors.mark_external_effect(operation, DateTime.utc_now(:second), %{
                 "request_id" => "blocked-#{target}"
               })
    end
  end

  test "orphaned, revoked, and tombstoned repositories block new external effect markers" do
    organization_mirror = active_organization_mirror_fixture()

    for target <- [:orphaned, :revoked, :tombstoned] do
      repository_mirror = repository_mirror_fixture(organization_mirror)

      operation =
        operation_fixture(organization_mirror, %{
          repository_mirror_id: repository_mirror.id,
          next_attempt_at: DateTime.utc_now(:second)
        })

      assert {:ok, [claimed]} =
               ForgeMirrors.claim_operations(
                 "blocked-repository-#{target}",
                 DateTime.utc_now(:second),
                 30,
                 1
               )

      assert claimed.id == operation.id

      assert {:ok, _transitioned} =
               ForgeMirrors.transition_repository_mirror(
                 organization_owner_fixture(repository_mirror),
                 repository_mirror,
                 target
               )

      assert {:error, :invalid_transition} =
               ForgeMirrors.mark_external_effect(claimed, DateTime.utc_now(:second), %{
                 "request_id" => "blocked-#{target}"
               })
    end
  end

  test "fail_operation rejects every retry-disposition class" do
    organization_mirror = active_organization_mirror_fixture()
    now = DateTime.utc_now(:second)

    for failure_class <- ["primary_rate_limit", "secondary_rate_limit", "network"] do
      operation =
        operation_fixture(organization_mirror, %{
          dedupe_key: "fail-retryable-#{failure_class}",
          next_attempt_at: now
        })

      assert {:ok, [claimed]} =
               ForgeMirrors.claim_operations("fail-retryable-#{failure_class}", now, 30, 1)

      assert claimed.id == operation.id

      assert {:error, :invalid_argument} =
               ForgeMirrors.fail_operation(claimed, now, failure_class)

      assert {:ok, retried} =
               ForgeMirrors.retry_operation(
                 claimed,
                 now,
                 DateTime.add(now, 60),
                 failure_class
               )

      assert retried.state == :pending
      Repo.delete!(retried)
    end
  end

  test "owned mirror transitions use server time rather than a stale caller timestamp" do
    organization_mirror = active_organization_mirror_fixture()
    claimed = claimed_repository_operation!(organization_mirror)
    expired_at = DateTime.add(DateTime.utc_now(:second), -1)

    Repo.update_all(from(operation in MirrorOperation, where: operation.id == ^claimed.id),
      set: [lease_expires_at: expired_at]
    )

    expired_capability = %{claimed | lease_expires_at: expired_at}
    stale_caller_now = DateTime.add(expired_at, -60)

    assert {:error, :lost_lease} =
             ForgeMirrors.complete_operation(expired_capability, stale_caller_now)

    assert Repo.get!(MirrorOperation, claimed.id).state == :processing
  end

  test "owned mirror transitions compare UTC-naive leases with UTC server time in a non-UTC session" do
    Ecto.Adapters.SQL.query!(Repo, "set local time zone 'Asia/Shanghai'", [])
    assert %{rows: [["Asia/Shanghai"]]} = Ecto.Adapters.SQL.query!(Repo, "show time zone", [])

    organization_mirror = active_organization_mirror_fixture()
    valid = claimed_repository_operation!(organization_mirror)
    now = DateTime.utc_now(:second)

    assert {:ok, %MirrorOperation{state: :completed}} =
             ForgeMirrors.complete_operation(valid, now)

    expired = claimed_repository_operation!(organization_mirror)
    expired_at = DateTime.add(now, -1)

    Repo.update_all(from(operation in MirrorOperation, where: operation.id == ^expired.id),
      set: [lease_expires_at: expired_at]
    )

    assert {:error, :lost_lease} =
             ForgeMirrors.complete_operation(
               %{expired | lease_expires_at: expired_at},
               DateTime.add(now, -60)
             )
  end

  test "operation repository scope is enforced by a composite foreign key" do
    first_organization = active_organization_mirror_fixture()
    second_organization = active_organization_mirror_fixture()
    second_repository = repository_mirror_fixture(second_organization)
    now = DateTime.utc_now(:second)

    assert_raise Postgrex.Error, ~r/mirror_operations_repository_scope_fkey/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into mirror_operations (organization_mirror_id, repository_mirror_id, kind, dedupe_key, state, cursor, attempt_count, next_attempt_at, lock_version, inserted_at, updated_at) values ($1, $2, 'repository.metadata', $3, 'pending', '{}', 0, $4, 1, $4, $4)",
        [first_organization.id, second_repository.id, Ecto.UUID.generate(), now]
      )
    end
  end

  test "failed operations cannot retain a retry disposition in direct writes" do
    organization_mirror = active_organization_mirror_fixture()
    claimed = claimed_repository_operation!(organization_mirror)

    assert_raise Postgrex.Error, ~r/mirror_operations_failed_state_check/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "update mirror_operations set state = 'failed', lease_owner = null, lease_expires_at = null, failure_class = 'network', failure_disposition = 'retry' where id = $1",
        [claimed.id]
      )
    end
  end

  test "ref OIDs accept exactly 40 or 64 lowercase hexadecimal characters" do
    repository_mirror =
      active_organization_mirror_fixture()
      |> repository_mirror_fixture()

    for oid <- [String.duplicate("a", 40), String.duplicate("b", 64)] do
      assert MirrorRefState.persistence_changeset(%MirrorRefState{}, %{
               repository_mirror_id: repository_mirror.id,
               ref_name: "refs/heads/valid-#{byte_size(oid)}",
               ref_kind: :branch,
               confirmed_oid: oid,
               state: :pending,
               lock_version: 1
             }).valid?
    end

    for oid <- [String.duplicate("a", 41), String.duplicate("b", 63), String.duplicate("A", 40)] do
      changeset =
        MirrorRefState.persistence_changeset(%MirrorRefState{}, %{
          repository_mirror_id: repository_mirror.id,
          ref_name: "refs/heads/invalid-#{System.unique_integer([:positive])}",
          ref_kind: :branch,
          confirmed_oid: oid,
          state: :pending,
          lock_version: 1
        })

      refute changeset.valid?

      assert "must be a 40 or 64 character lowercase hexadecimal object ID" in errors_on(
               changeset
             ).confirmed_oid
    end
  end

  test "database rejects ref OIDs whose lowercase hexadecimal length is between 40 and 64" do
    repository_mirror =
      active_organization_mirror_fixture()
      |> repository_mirror_fixture()

    now = DateTime.utc_now(:second)

    assert_raise Postgrex.Error, ~r/mirror_ref_states_confirmed_oid_check/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into mirror_ref_states (repository_mirror_id, ref_name, ref_kind, confirmed_oid, state, lock_version, inserted_at, updated_at) values ($1, 'refs/heads/invalid-direct', 'branch', $2, 'pending', 1, $3, $3)",
        [repository_mirror.id, String.duplicate("a", 41), now]
      )
    end
  end

  test "a non-map operation cursor returns a typed changeset error" do
    organization_mirror = active_organization_mirror_fixture()

    assert {:error, %Ecto.Changeset{} = changeset} =
             ForgeMirrors.enqueue_operation(%{
               organization_mirror_id: organization_mirror.id,
               kind: "repository.metadata",
               dedupe_key: Ecto.UUID.generate(),
               cursor: ["not", "an", "object"]
             })

    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).cursor
  end

  defp claimed_repository_operation!(organization_mirror) do
    repository_mirror = repository_mirror_fixture(organization_mirror)
    now = DateTime.utc_now(:second)

    operation =
      operation_fixture(organization_mirror, %{
        repository_mirror_id: repository_mirror.id,
        next_attempt_at: now
      })

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("quality-review-#{operation.id}", now, 30, 1)

    assert claimed.id == operation.id
    claimed
  end

  defp outbox_event!(repository_mirror, event_id, now) do
    organization_mirror =
      Repo.get!(ForgeMirrors.OrganizationMirror, repository_mirror.organization_mirror_id)

    assert {:ok, %{event: event}} =
             Multi.new()
             |> DomainOutbox.record_multi(:event, %{
               event_id: event_id,
               aggregate_type: "repository",
               aggregate_id: Integer.to_string(repository_mirror.repository_id),
               event_type: "repository.updated",
               origin: :fornacast,
               payload: %{
                 "repository_id" => repository_mirror.repository_id,
                 "owner_id" => organization_mirror.organization_id
               },
               available_at: now
             })
             |> Repo.transaction()

    event
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
