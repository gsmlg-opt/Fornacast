defmodule ForgeMirrors.OutboxMaterializationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Ecto.Multi
  alias Fornacast.{DomainOutbox, DomainOutboxEvent, Repo}
  alias ForgeMirrors.{MirrorOperation, RepositoryMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(DomainOutboxEvent)
    :ok
  end

  test "repository.created creates a local discovered binding and durable outbound intent" do
    organization_mirror = active_organization_mirror_fixture(create_policy())
    repository_id = repository_fixture(organization_mirror.organization_id)
    event = created_event(repository_id, organization_mirror.organization_id)

    assert {:ok, {:materialized, [%MirrorOperation{} = operation]}} =
             ForgeMirrors.materialize_outbox_event(event)

    repository_mirror = Repo.get_by!(RepositoryMirror, repository_id: repository_id)
    assert repository_mirror.organization_mirror_id == organization_mirror.id
    assert repository_mirror.state == :discovered
    assert repository_mirror.github_repository_id == nil
    assert operation.repository_mirror_id == repository_mirror.id
    assert operation.kind == "sync.repository.create"
    assert operation.state == :pending
  end

  test "repository.created is acknowledged without a binding when remote creation is disabled" do
    organization_mirror = active_organization_mirror_fixture()
    repository_id = repository_fixture(organization_mirror.organization_id)
    event = created_event(repository_id, organization_mirror.organization_id)

    assert {:ok, {:ignored, :repository_create_disabled}} =
             ForgeMirrors.materialize_outbox_event(event)

    refute Repo.get_by(RepositoryMirror, repository_id: repository_id)

    refute Repo.exists?(
             from operation in MirrorOperation,
               where:
                 operation.organization_mirror_id == ^organization_mirror.id and
                   operation.kind == "sync.repository.create"
           )
  end

  test "repository.created is acknowledged without a binding when Git capability is disabled" do
    organization_mirror =
      active_organization_mirror_fixture(%{
        policy: %{"auto_create_remote_repositories" => true},
        capabilities: %{"git" => "disabled"}
      })

    repository_id = repository_fixture(organization_mirror.organization_id)
    event = created_event(repository_id, organization_mirror.organization_id)

    assert {:ok, {:ignored, :repository_create_capability_disabled}} =
             ForgeMirrors.materialize_outbox_event(event)

    refute Repo.exists?(
             from mirror in RepositoryMirror,
               where: mirror.repository_id == ^repository_id
           )
  end

  test "repository.created rejects malformed remote-creation policy" do
    organization_mirror =
      active_organization_mirror_fixture(%{
        policy: %{"auto_create_remote_repositories" => "yes"},
        capabilities: %{"git" => "enabled"}
      })

    repository_id = repository_fixture(organization_mirror.organization_id)
    event = created_event(repository_id, organization_mirror.organization_id)

    assert {:error, :invalid_policy} = ForgeMirrors.materialize_outbox_event(event)

    refute Repo.exists?(
             from mirror in RepositoryMirror,
               where: mirror.repository_id == ^repository_id
           )
  end

  test "repository.created rejects malformed Git capability state" do
    organization_mirror =
      active_organization_mirror_fixture(%{
        policy: %{"auto_create_remote_repositories" => true},
        capabilities: %{"git" => "sometimes"}
      })

    repository_id = repository_fixture(organization_mirror.organization_id)
    event = created_event(repository_id, organization_mirror.organization_id)

    assert {:error, :invalid_capabilities} = ForgeMirrors.materialize_outbox_event(event)

    refute Repo.exists?(
             from mirror in RepositoryMirror,
               where: mirror.repository_id == ^repository_id
           )
  end

  test "repository.created replay is idempotent after materialization but before acknowledgement" do
    organization_mirror = active_organization_mirror_fixture(create_policy())
    repository_id = repository_fixture(organization_mirror.organization_id)
    event = created_event(repository_id, organization_mirror.organization_id)

    assert {:ok, {:materialized, [first]}} = ForgeMirrors.materialize_outbox_event(event)
    assert {:ok, {:materialized, [replayed]}} = ForgeMirrors.materialize_outbox_event(event)

    assert replayed.id == first.id

    assert Repo.aggregate(
             from(repository in RepositoryMirror,
               where: repository.repository_id == ^repository_id
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(operation in MirrorOperation,
               where: operation.dedupe_key == ^first.dedupe_key
             ),
             :count
           ) == 1
  end

  test "repository.pushed materializes durable intent for an existing binding" do
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    event = %DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(repository_mirror.repository_id),
      event_type: "repository.pushed",
      origin: :fornacast,
      payload: %{
        "repository_id" => repository_mirror.repository_id,
        "owner_id" => organization_mirror.organization_id,
        "changed_refs" => [
          %{
            "ref" => "refs/heads/main",
            "old_oid" => nil,
            "new_oid" => String.duplicate("a", 40)
          },
          %{
            "ref" => "refs/tags/v1.0.0",
            "old_oid" => String.duplicate("b", 40),
            "new_oid" => nil
          }
        ]
      },
      available_at: DateTime.utc_now(:second)
    }

    assert {:ok, {:materialized, [%MirrorOperation{} = branch, %MirrorOperation{} = tag]}} =
             ForgeMirrors.materialize_outbox_event(event)

    assert branch.repository_mirror_id == repository_mirror.id
    assert branch.kind == "sync.git_ref"

    assert branch.cursor == %{
             "initial_absence" => true,
             "outbox_event_id" => event.event_id,
             "ref_name" => "refs/heads/main",
             "trigger" => "local"
           }

    assert tag.kind == "sync.git_ref"
    assert tag.cursor["ref_name"] == "refs/tags/v1.0.0"
    assert tag.cursor["initial_absence"] == false

    assert {:ok, {:materialized, replayed}} = ForgeMirrors.materialize_outbox_event(event)
    assert Enum.map(replayed, & &1.id) == [branch.id, tag.id]
  end

  test "repository.updated materializes repository metadata reconciliation work" do
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    event =
      repository_event(repository_mirror, organization_mirror, event_type: "repository.updated")

    assert {:ok, {:materialized, [%MirrorOperation{} = operation]}} =
             ForgeMirrors.materialize_outbox_event(event)

    assert operation.repository_mirror_id == repository_mirror.id
    assert operation.kind == "reconcile.repository.metadata"

    assert operation.cursor == %{
             "causation_id" => nil,
             "correlation_id" => nil,
             "outbox_event_id" => event.event_id,
             "trigger" => "local"
           }
  end

  test "repository.pushed rejects malformed or duplicate exact-ref evidence" do
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    for changed_refs <- [
          [%{"ref" => "refs/pull/1/head", "old_oid" => nil, "new_oid" => nil}],
          [%{"ref" => "refs/heads/main", "old_oid" => "bad", "new_oid" => nil}],
          [
            %{"ref" => "refs/heads/main", "old_oid" => nil, "new_oid" => nil},
            %{"ref" => "refs/heads/main", "old_oid" => nil, "new_oid" => nil}
          ]
        ] do
      event =
        repository_event(repository_mirror, organization_mirror, event_type: "repository.pushed")
        |> put_in([Access.key!(:payload), "changed_refs"], changed_refs)

      assert {:error, :invalid_payload} = ForgeMirrors.materialize_outbox_event(event)
    end
  end

  test "non-local repository events are explicitly ignored without outbound intent" do
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    event =
      repository_event(repository_mirror, organization_mirror,
        event_type: "repository.pushed",
        origin: :github
      )

    assert {:ok, {:ignored, :non_local_event}} =
             ForgeMirrors.materialize_outbox_event(event)

    refute Repo.exists?(
             from(operation in MirrorOperation, where: operation.kind == "repository.pushed")
           )
  end

  test "a repository aggregate with a non-repository event type is explicitly ignored" do
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    event =
      repository_event(repository_mirror, organization_mirror, event_type: "organization.updated")

    assert {:ok, {:ignored, :non_repository_event}} =
             ForgeMirrors.materialize_outbox_event(event)

    refute Repo.exists?(
             from(operation in MirrorOperation, where: operation.kind == "organization.updated")
           )
  end

  test "repository.created persists paused intent but the scheduler cannot claim it" do
    organization_mirror = active_organization_mirror_fixture(create_policy())
    actor = organization_owner_fixture(organization_mirror)
    assert {:ok, paused} = ForgeMirrors.pause(actor, organization_mirror)
    repository_id = repository_fixture(paused.organization_id)
    event = created_event(repository_id, paused.organization_id)

    assert {:ok, {:materialized, [%MirrorOperation{state: :pending}]}} =
             ForgeMirrors.materialize_outbox_event(event)

    assert {:ok, []} =
             ForgeMirrors.claim_operations("paused-created", DateTime.utc_now(:second), 30, 1)
  end

  test "dispatcher acknowledges an explicitly ignored event for an unmirrored owner" do
    owner_id = organization_fixture()
    repository_id = repository_fixture(owner_id)
    now = DateTime.utc_now(:second)
    event_id = Ecto.UUID.generate()

    assert {:ok, %{event: event}} =
             record_event(created_event(repository_id, owner_id, event_id, now))

    assert {:ok, [{:ok, ^event_id, {:ignored, :unmirrored_owner}}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("unmirrored-owner", now,
               lease_seconds: 30,
               batch_size: 1
             )

    assert Repo.get!(DomainOutboxEvent, event.id).state == :completed

    refute Repo.exists?(
             from(repository in RepositoryMirror,
               where: repository.repository_id == ^repository_id
             )
           )
  end

  test "dispatcher explicitly ignores and acknowledges a mirrored owner with no repository binding" do
    organization_mirror = active_organization_mirror_fixture()
    repository_id = repository_fixture(organization_mirror.organization_id)
    now = DateTime.utc_now(:second)
    event_id = Ecto.UUID.generate()

    event =
      %DomainOutboxEvent{
        created_event(repository_id, organization_mirror.organization_id, event_id, now)
        | event_type: "repository.pushed"
      }

    assert {:ok, %{event: persisted}} = record_event(event)

    assert {:ok, [{:ok, ^event_id, {:ignored, :unbound_repository}}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("unbound-repository", now,
               lease_seconds: 30,
               batch_size: 1
             )

    assert Repo.get!(DomainOutboxEvent, persisted.id).state == :completed

    refute Repo.exists?(
             from(operation in MirrorOperation,
               where:
                 operation.organization_mirror_id == ^organization_mirror.id and
                   operation.kind == "repository.pushed"
             )
           )
  end

  test "invalid repository identity is released and never acknowledged as ignored" do
    now = DateTime.utc_now(:second)
    event_id = Ecto.UUID.generate()

    invalid =
      %DomainOutboxEvent{
        event_id: event_id,
        aggregate_type: "repository",
        aggregate_id: "not-an-id",
        event_type: "repository.created",
        origin: :fornacast,
        payload: %{"owner_id" => 42},
        available_at: now
      }

    assert {:ok, %{event: event}} = record_event(invalid)

    assert {:ok, [{:error, ^event_id, :invalid_payload}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("invalid-payload", now,
               lease_seconds: 30,
               batch_size: 1
             )

    released = Repo.get!(DomainOutboxEvent, event.id)
    assert released.state == :pending
    assert released.available_at == DateTime.add(now, 5)
  end

  test "a repository owner mismatch is invalid payload and is released" do
    actual_owner_id = organization_fixture()
    claimed_owner_id = organization_fixture()

    _organization_mirror =
      active_organization_mirror_fixture(%{organization_id: claimed_owner_id})

    repository_id = repository_fixture(actual_owner_id)
    now = DateTime.utc_now(:second)
    event_id = Ecto.UUID.generate()

    assert {:ok, %{event: event}} =
             created_event(repository_id, claimed_owner_id, event_id, now)
             |> record_event()

    assert {:ok, [{:error, ^event_id, :invalid_payload}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("owner-mismatch", now,
               lease_seconds: 30,
               batch_size: 1
             )

    assert Repo.get!(DomainOutboxEvent, event.id).state == :pending
  end

  test "an existing-binding event owner mismatch is invalid payload and is released" do
    actual_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(actual_mirror)
    claimed_owner_id = organization_fixture()
    _claimed_mirror = active_organization_mirror_fixture(%{organization_id: claimed_owner_id})
    now = DateTime.utc_now(:second)
    event_id = Ecto.UUID.generate()

    event = %DomainOutboxEvent{
      event_id: event_id,
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(repository_mirror.repository_id),
      event_type: "repository.pushed",
      origin: :fornacast,
      payload: %{
        "repository_id" => repository_mirror.repository_id,
        "owner_id" => claimed_owner_id
      },
      available_at: now
    }

    assert {:ok, %{event: persisted}} = record_event(event)

    assert {:ok, [{:error, ^event_id, :invalid_payload}]} =
             ForgeMirrors.OutboxDispatcher.dispatch_once("existing-owner-mismatch", now,
               lease_seconds: 30,
               batch_size: 1
             )

    assert Repo.get!(DomainOutboxEvent, persisted.id).state == :pending
  end

  defp created_event(
         repository_id,
         owner_id,
         event_id \\ Ecto.UUID.generate(),
         now \\ DateTime.utc_now(:second)
       ) do
    %DomainOutboxEvent{
      event_id: event_id,
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(repository_id),
      event_type: "repository.created",
      origin: :fornacast,
      payload: %{"repository_id" => repository_id, "owner_id" => owner_id},
      available_at: now
    }
  end

  defp repository_event(repository_mirror, organization_mirror, options) do
    %DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(repository_mirror.repository_id),
      event_type: Keyword.fetch!(options, :event_type),
      origin: Keyword.get(options, :origin, :fornacast),
      payload: %{
        "repository_id" => repository_mirror.repository_id,
        "owner_id" => organization_mirror.organization_id
      },
      available_at: DateTime.utc_now(:second)
    }
  end

  defp record_event(%DomainOutboxEvent{} = event) do
    Multi.new()
    |> DomainOutbox.record_multi(:event, Map.from_struct(event))
    |> Repo.transaction()
  end

  defp create_policy,
    do: %{
      policy: %{"auto_create_remote_repositories" => true},
      capabilities: %{"git" => "enabled"}
    }
end

defmodule ForgeMirrors.OutboxMaterializationRaceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.{DomainOutboxEvent, Repo}
  alias ForgeMirrors.{MirrorOperation, RepositoryMirror}

  @tag :independent_connections
  test "concurrent repository.created materialization converges on one binding and operation" do
    {organization_id, organization_mirror, repository_id} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        organization_mirror =
          active_organization_mirror_fixture(%{
            policy: %{"auto_create_remote_repositories" => true},
            capabilities: %{"git" => "enabled"}
          })

        repository_id = repository_fixture(organization_mirror.organization_id)
        {organization_mirror.organization_id, organization_mirror, repository_id}
      end)

    on_exit(fn ->
      cleanup_organization(organization_id, organization_mirror.id, repository_id)
    end)

    event = %DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(repository_id),
      event_type: "repository.created",
      origin: :fornacast,
      payload: %{
        "repository_id" => repository_id,
        "owner_id" => organization_mirror.organization_id
      },
      available_at: DateTime.utc_now(:second)
    }

    results =
      1..2
      |> Task.async_stream(
        fn _index ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            ForgeMirrors.materialize_outbox_event(event)
          end)
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    operation_ids =
      Enum.map(results, fn {:ok, {:materialized, [%MirrorOperation{id: id}]}} -> id end)

    assert length(Enum.uniq(operation_ids)) == 1

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(repository in RepositoryMirror,
                 where: repository.repository_id == ^repository_id
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(operation in MirrorOperation,
                 where: operation.id in ^operation_ids
               ),
               :count
             ) == 1
    end)
  end

  defp cleanup_organization(organization_id, organization_mirror_id, repository_id) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(
        from(mirror in ForgeMirrors.OrganizationMirror,
          where: mirror.id == ^organization_mirror_id
        )
      )

      Repo.delete_all(
        from(repository in ForgeRepos.Repository, where: repository.id == ^repository_id)
      )

      Repo.delete_all(from(user in ForgeAccounts.User, where: user.id == ^organization_id))
    end)
  end
end
