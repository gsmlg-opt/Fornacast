defmodule ForgeReleases.SyncOutboxTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeReleases.Fixtures

  alias Ecto.Multi
  alias ForgeReleases.Release
  alias Fornacast.{AuditEvent, DomainOutboxEvent, Repo}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    reset_database!()
    previous_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous_root) end)

    actor = user_fixture("release-outbox-#{System.unique_integer([:positive])}")
    repository = repository_fixture(actor)
    put_tag(repository, "v1.0.0")
    %{actor: actor, repository: repository}
  end

  test "local provenance is trusted and public attributes cannot forge sync metadata", ctx do
    assert {:ok, release} =
             ForgeReleases.create(
               ctx.actor,
               ctx.actor.username,
               ctx.repository.slug,
               %{
                 "tag_name" => "v1.0.0",
                 "name" => "Local",
                 "published_at" => ~U[2000-01-01 00:00:00Z],
                 "sync_version" => 900,
                 "origin" => "github"
               },
               %{"origin" => "github", request_id: "local-release"}
             )

    refute release.published_at == ~U[2000-01-01 00:00:00Z]
    assert release.sync_version == 1

    assert [%DomainOutboxEvent{} = event] = events(release.id)
    assert event.origin == :fornacast
    assert event.event_type == "release.created"
    assert event.payload["deleted"] == false
    refute Map.has_key?(event.payload, "name")
    refute Map.has_key?(event.payload, "published_at")

    original_published_at = release.published_at

    assert {:ok, updated} =
             ForgeReleases.update(
               ctx.actor,
               ctx.actor.username,
               ctx.repository.slug,
               release.id,
               %{"name" => "Still local", "published_at" => ~U[1999-01-01 00:00:00Z]},
               %{}
             )

    assert updated.published_at == original_published_at
  end

  test "an outbox failure rolls back release and audit", ctx do
    multi =
      ForgeReleases.create_multi(
        ctx.actor,
        ctx.repository,
        %{"tag_name" => "v1.0.0", "name" => "Rollback"},
        %{},
        origin: :invalid
      )

    assert {:error, :outbox, _changeset, _changes} = ForgeReleases.transaction(multi)
    assert Repo.aggregate(Release, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
    refute release_event_for_repository?(ctx.repository.id)
  end

  test "a later failure rolls back mutation audit and outbox together", ctx do
    assert {:error, :later, :rollback, _changes} =
             ForgeReleases.create_multi(
               ctx.actor,
               ctx.repository,
               %{"tag_name" => "v1.0.0", "name" => "Rollback"},
               %{}
             )
             |> Multi.error(:later, :rollback)
             |> ForgeReleases.transaction()

    assert Repo.aggregate(Release, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
    refute release_event_for_repository?(ctx.repository.id)
  end

  test "local create and update reject bodies beyond Unicode and UTF-8 bounds", ctx do
    codepoint_overflow = String.duplicate("x", 65_537)
    multibyte_overflow = String.duplicate("😀", 65_537)

    for body <- [codepoint_overflow, multibyte_overflow] do
      assert {:error, {:validation, errors}} =
               ForgeReleases.create(
                 ctx.actor,
                 ctx.actor.username,
                 ctx.repository.slug,
                 %{"tag_name" => "v1.0.0", "name" => "Too large", "body" => body},
                 %{}
               )

      assert Enum.any?(errors, &(&1.field == "body" and &1.code == :invalid))
    end

    assert {:ok, release} =
             ForgeReleases.create(
               ctx.actor,
               ctx.actor.username,
               ctx.repository.slug,
               %{"tag_name" => "v1.0.0", "name" => "Bounded", "body" => "before"},
               %{}
             )

    for body <- [codepoint_overflow, multibyte_overflow] do
      assert {:error, {:validation, errors}} =
               ForgeReleases.update(
                 ctx.actor,
                 ctx.actor.username,
                 ctx.repository.slug,
                 release.id,
                 %{"body" => body},
                 %{}
               )

      assert Enum.any?(errors, &(&1.field == "body" and &1.code == :invalid))
      assert Repo.get!(Release, release.id).body == "before"
    end
  end

  defp events(release_id) do
    Repo.all(
      from event in DomainOutboxEvent,
        where: event.aggregate_type == "release" and event.aggregate_id == ^to_string(release_id),
        order_by: event.id
    )
  end

  defp release_event_for_repository?(repository_id) do
    Repo.exists?(
      from event in DomainOutboxEvent,
        where:
          event.aggregate_type == "release" and
            event.payload["repository_id"] == ^repository_id
    )
  end
end
