defmodule ForgeReleases.SyncTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeReleases.Fixtures

  alias Ecto.{Changeset, Multi}
  alias ForgeAccounts.GitHubIdentity
  alias ForgeReleases.Release
  alias Fornacast.{AuditEvent, DomainOutboxEvent, Repo}

  setup do
    reset_database!()
    owner = user_fixture("release-sync-#{System.unique_integer([:positive])}")
    repository = repository_fixture(owner)

    identity =
      %GitHubIdentity{}
      |> GitHubIdentity.observed_changeset(%{
        github_user_id: System.unique_integer([:positive]),
        github_node_id: "U_release_#{System.unique_integer([:positive])}",
        login: "remote-author",
        avatar_url: "https://avatars.githubusercontent.com/u/42",
        profile_url: "https://github.com/remote-author",
        last_observed_at: ~U[2026-09-14 01:00:00Z]
      })
      |> Repo.insert!()

    %{owner: owner, repository: repository, identity: identity}
  end

  test "canonical GitHub create sets provider publication state with a provider-origin event",
       ctx do
    assert {:ok, %{release: projection}} = apply_sync(create_request(ctx))

    assert projection.repository_id == ctx.repository.id
    assert projection.resource_kind == :release
    assert projection.local_resource_type == "ForgeReleases.Release"
    assert projection.local_version == 1
    assert projection.deleted == false
    assert projection.fields == fields()

    assert %Release{
             author_user_id: nil,
             author_github_identity_id: identity_id,
             published_at: ~U[2026-09-12 10:11:12Z]
           } = Repo.get!(Release, projection.local_resource_id)

    assert identity_id == ctx.identity.id
    assert [%DomainOutboxEvent{} = event] = events(projection.local_resource_id)
    assert event.origin == :github
    assert event.causation_id == "delivery-1"
    assert event.correlation_id == "operation-1"
    assert event.event_type == "release.created"

    assert event.payload == %{
             "repository_id" => ctx.repository.id,
             "release_id" => projection.local_resource_id,
             "tag_name" => "v1.0.0",
             "sync_version" => 1,
             "deleted" => false
           }

    assert Repo.exists?(
             from audit in AuditEvent, where: audit.action == "github_sync.release_created"
           )
  end

  test "canonical update requires the exact version and complete preimage", ctx do
    {:ok, %{release: original}} = apply_sync(create_request(ctx))

    request = %{
      action: :update,
      repository_id: ctx.repository.id,
      local_resource_id: original.local_resource_id,
      expected_local_version: original.local_version,
      expected_fields: original.fields,
      expected_deleted: false,
      fields: %{fields() | "name" => "Canonical", "body" => "Changed remotely"},
      tag_proof: tag_proof(ctx.repository.id, "v1.0.0"),
      updated_at: ~U[2026-09-13 10:11:12Z],
      provenance: provenance()
    }

    assert {:error, _, :invalid_sync_request, _} = apply_sync(Map.delete(request, :tag_proof))

    assert {:ok, %{release: changed}} = apply_sync(request)
    assert changed.local_version == 2
    assert changed.fields["name"] == "Canonical"
    assert changed.fields["published_at"] == ~U[2026-09-12 10:11:12Z]
    assert Repo.get!(Release, changed.local_resource_id).updated_at == ~U[2026-09-13 10:11:12Z]

    assert {:error, _, :stale_local_version, _} = apply_sync(request)

    stale_snapshot = %{
      request
      | expected_local_version: changed.local_version,
        expected_fields: %{changed.fields | "body" => "not the preimage"}
    }

    assert {:error, _, :stale_local_snapshot, _} = apply_sync(stale_snapshot)
    assert [created, updated] = events(original.local_resource_id)

    assert Enum.map([created, updated], &{&1.origin, &1.event_type}) == [
             {:github, "release.created"},
             {:github, "release.updated"}
           ]
  end

  test "canonical soft delete is versioned, exact, and remains observable as a tombstone", ctx do
    {:ok, %{release: original}} = apply_sync(create_request(ctx))

    request = %{
      action: :delete,
      repository_id: ctx.repository.id,
      local_resource_id: original.local_resource_id,
      expected_local_version: 1,
      expected_fields: original.fields,
      expected_deleted: false,
      fields: %{},
      updated_at: ~U[2026-09-13 11:12:13Z],
      provenance: provenance()
    }

    assert {:ok, %{release: deleted}} = apply_sync(request)
    assert deleted.local_version == 2
    assert deleted.deleted == true
    assert deleted.fields == original.fields

    assert %Release{deleted_at: %DateTime{}, sync_version: 2} =
             Repo.get!(Release, original.local_resource_id)

    assert Repo.get!(Release, original.local_resource_id).deleted_at ==
             ~U[2026-09-13 11:12:13Z]

    assert {:ok, ^deleted} =
             ForgeReleases.release_sync_projection(
               ctx.repository.id,
               original.local_resource_id
             )

    assert {:ok, %{release: ^deleted}} =
             observe(%{
               repository_id: ctx.repository.id,
               local_resource_id: original.local_resource_id,
               expected_local_version: 2,
               expected_fields: original.fields,
               expected_deleted: true
             })

    assert [created, deleted_event] = events(original.local_resource_id)
    assert created.event_type == "release.created"
    assert deleted_event.origin == :github
    assert deleted_event.event_type == "release.deleted"
    assert deleted_event.payload["deleted"] == true
    assert deleted_event.payload["sync_version"] == 2
  end

  test "observation locks and compares version snapshot and deletion state", ctx do
    {:ok, %{release: original}} = apply_sync(create_request(ctx))

    expected = %{
      repository_id: ctx.repository.id,
      local_resource_id: original.local_resource_id,
      expected_local_version: 1,
      expected_fields: original.fields,
      expected_deleted: false
    }

    assert {:ok, %{release: ^original}} = observe(expected)

    assert {:error, _, :stale_local_version, _} =
             observe(%{expected | expected_local_version: 2})

    assert {:error, _, :stale_local_snapshot, _} =
             observe(%{expected | expected_fields: %{original.fields | "name" => "Wrong"}})

    assert {:error, _, :stale_local_snapshot, _} = observe(%{expected | expected_deleted: true})
  end

  test "minimum-version observation returns newer metadata without certifying its old snapshot",
       ctx do
    {:ok, %{release: original}} = apply_sync(create_request(ctx))

    minimum = %{
      repository_id: ctx.repository.id,
      local_resource_id: original.local_resource_id,
      minimum_local_version: 1,
      expected_fields: original.fields,
      expected_deleted: false
    }

    assert {:ok, %{release: ^original}} = observe(minimum)

    assert {:error, _, :stale_local_snapshot, _} =
             observe(%{minimum | expected_fields: %{original.fields | "name" => "drift"}})

    request = %{
      action: :update,
      repository_id: ctx.repository.id,
      local_resource_id: original.local_resource_id,
      expected_local_version: original.local_version,
      expected_fields: original.fields,
      expected_deleted: false,
      fields: %{original.fields | "name" => "Newer projection"},
      tag_proof: tag_proof(ctx.repository.id, "v1.0.0"),
      updated_at: ~U[2026-09-13 12:00:00Z],
      provenance: provenance()
    }

    assert {:ok, %{release: changed}} = apply_sync(request)
    assert changed.local_version == 2

    historical = %{
      minimum
      | expected_fields: %{original.fields | "name" => "historical snapshot"},
        expected_deleted: true
    }

    assert {:ok, %{release: ^changed}} = observe(historical)
    assert Repo.get!(Release, original.local_resource_id).name == "Newer projection"

    assert {:error, _, :stale_local_snapshot, _} =
             observe(%{
               minimum
               | minimum_local_version: 2,
                 expected_fields: %{changed.fields | "name" => "equal-version drift"},
                 expected_deleted: changed.deleted
             })

    assert {:error, _, :stale_local_version, _} =
             observe(%{minimum | minimum_local_version: 3})

    assert {:error, _, :invalid_sync_request, _} =
             minimum |> Map.put(:expected_local_version, 1) |> observe()
  end

  test "invalid author scope and downstream failure fail closed atomically", ctx do
    invalid_author = %{create_request(ctx) | author_github_identity_id: ctx.identity.id + 1000}
    assert {:error, _, :invalid_author, _} = apply_sync(invalid_author)

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx) |> Map.put(:unexpected, true) |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx) |> Map.delete(:tag_proof) |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> put_in([:tag_proof, :remote_oid], String.duplicate("b", 40))
             |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> put_in([:tag_proof, :ref_state_lock_version], 0)
             |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> put_in([:provenance, :correlation_id], String.duplicate("x", 256))
             |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> put_in([:provenance, :unexpected], "forged")
             |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> Map.put(:updated_at, ~U[2026-09-12 10:11:12.123456Z])
             |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> put_in([:fields, "published_at"], ~U[2026-09-12 10:11:12.123456Z])
             |> apply_sync()

    non_utc = %{
      ~U[2026-09-12 10:11:12Z]
      | time_zone: "Etc/GMT-1",
        zone_abbr: "+01",
        utc_offset: 3600
    }

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> put_in([:fields, "published_at"], non_utc)
             |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> put_in([:fields, "body"], String.duplicate("x", 262_145))
             |> apply_sync()

    assert {:error, _, :invalid_sync_request, _} =
             create_request(ctx)
             |> put_in([:fields, "body"], String.duplicate("😀", 65_537))
             |> apply_sync()

    other = repository_fixture(ctx.owner)

    scoped =
      create_request(ctx)
      |> Map.put(:repository_id, other.id)
      |> put_in([:tag_proof, :repository_id], other.id)

    multi =
      Multi.new()
      |> ForgeReleases.append_sync_release_apply(:release, scoped)
      |> Multi.error(:later, :rollback)

    assert {:error, :later, :rollback, _} = Repo.transaction(multi)
    assert Repo.aggregate(Release, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0

    refute Repo.exists?(
             from event in DomainOutboxEvent,
               where:
                 event.aggregate_type == "release" and
                   event.payload["repository_id"] == ^other.id
           )
  end

  test "loaded release contention and database version constraint reject stale or invalid writes",
       ctx do
    {:ok, %{release: original}} = apply_sync(create_request(ctx))
    stale = Repo.get!(Release, original.local_resource_id)

    {:ok, changed} =
      stale
      |> Release.update_changeset(%{"name" => "One", "sync_version" => 900})
      |> Repo.update()

    assert changed.sync_version == 2

    assert {:error, changeset} =
             stale
             |> Release.update_changeset(%{"name" => "Two"})
             |> Repo.update(stale_error_field: :id)

    assert Keyword.has_key?(changeset.errors, :id)

    for invalid <- [0, -1] do
      changeset =
        changed
        |> Changeset.change(sync_version: invalid)
        |> Changeset.check_constraint(:sync_version, name: :releases_sync_version_positive)

      assert {:error, failed} = Repo.update(changeset, mode: :savepoint)
      assert Keyword.has_key?(failed.errors, :sync_version)
    end
  end

  defp create_request(ctx) do
    %{
      action: :create,
      repository_id: ctx.repository.id,
      local_resource_id: nil,
      expected_local_version: :missing,
      expected_fields: %{},
      fields: fields(),
      tag_proof: tag_proof(ctx.repository.id, "v1.0.0"),
      author_github_identity_id: ctx.identity.id,
      inserted_at: ~U[2026-09-12 10:11:12Z],
      updated_at: ~U[2026-09-12 10:11:12Z],
      provenance: provenance()
    }
  end

  defp fields do
    %{
      "tag_name" => "v1.0.0",
      "name" => "Remote release",
      "body" => "Canonical notes",
      "draft" => false,
      "prerelease" => false,
      "target_commitish" => "main",
      "published_at" => ~U[2026-09-12 10:11:12Z]
    }
  end

  defp provenance,
    do: %{origin: :github, causation_id: "delivery-1", correlation_id: "operation-1"}

  defp tag_proof(repository_id, tag_name) do
    oid = String.duplicate("a", 40)

    %{
      tag_name: tag_name,
      ref_name: "refs/tags/#{tag_name}",
      confirmed_oid: oid,
      local_oid: oid,
      remote_oid: oid,
      confirmed_at: ~U[2026-09-13 09:00:00Z],
      ref_state_lock_version: 1,
      repository_id: repository_id
    }
  end

  defp apply_sync(request) do
    Multi.new()
    |> ForgeReleases.append_sync_release_apply(:release, request)
    |> Repo.transaction()
  end

  defp observe(expected) do
    Multi.new()
    |> ForgeReleases.append_sync_release_observe(:release, expected)
    |> Repo.transaction()
  end

  defp events(release_id) do
    Repo.all(
      from event in DomainOutboxEvent,
        where: event.aggregate_type == "release" and event.aggregate_id == ^to_string(release_id),
        order_by: event.id
    )
  end
end
