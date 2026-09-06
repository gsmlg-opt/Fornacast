defmodule ForgeIssues.LabelSyncTest do
  use ExUnit.Case, async: false
  import ForgeIssues.Fixtures
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.Label
  alias Fornacast.{AuditEvent, DomainOutboxEvent, Repo}

  setup do
    reset_database!()
    actor = user_fixture("label-sync-#{System.unique_integer([:positive])}")
    repository = repository_fixture(actor)
    %{actor: actor, repository: repository}
  end

  test "fresh remote labels start version one with canonical metadata and github provenance",
       ctx do
    assert {:ok, %{resource: projection}} =
             import_label(ctx, %{
               "name" => "Remote Label",
               "color" => "AB12CD",
               "description" => ""
             })

    assert projection.local_version == 1
    assert projection.local_resource_type == "ForgeIssues.Label"
    assert projection.resource_kind == :label
    assert projection.repository_id == ctx.repository.id

    assert projection.fields == %{
             "name" => "Remote Label",
             "color" => "ab12cd",
             "description" => nil
           }

    assert Repo.get!(Label, projection.local_resource_id).normalized_name == "remote label"

    assert {:ok, ^projection} =
             ForgeIssues.label_sync_projection(ctx.repository.id, projection.local_resource_id)

    assert [event] = Repo.all(from e in DomainOutboxEvent, where: e.aggregate_type == "label")
    assert event.origin == :github
    assert event.event_type == "label.created"
    assert event.causation_id == "delivery"
    assert event.payload["sync_version"] == 1
    assert event.payload["label_id"] == projection.local_resource_id
    assert Repo.exists?(from a in AuditEvent, where: a.action == "github_sync.label_created")
  end

  test "exact adoption retains actual version and emits no additional event", ctx do
    {:ok, %{resource: first}} = import_label(ctx, fields())
    row = Repo.get!(Label, first.local_resource_id)

    assert {:ok, changed} =
             row |> Label.changeset(%{description: "Changed locally"}) |> Repo.update()

    assert changed.sync_version == 2

    assert {:ok, %{resource: adopted}} =
             import_label(ctx, %{fields() | "description" => "Changed locally"})

    assert adopted.local_resource_id == first.local_resource_id
    assert adopted.local_version == 2

    assert Repo.aggregate(
             from(e in DomainOutboxEvent, where: e.aggregate_type == "label"),
             :count
           ) == 1

    assert Repo.aggregate(
             from(a in AuditEvent, where: a.action == "github_sync.label_created"),
             :count
           ) == 1
  end

  test "normalized-name collisions never overwrite local spelling or metadata", ctx do
    {:ok, %{resource: first}} = import_label(ctx, fields())

    for different <- [
          %{fields() | "name" => "REMOTE"},
          %{fields() | "color" => "ffffff"},
          %{fields() | "description" => "Other"}
        ] do
      assert {:error, _, :namespace_collision, _} = import_label(ctx, different)
    end

    assert {:ok, ^first} =
             ForgeIssues.label_sync_projection(ctx.repository.id, first.local_resource_id)
  end

  test "observation checks version and full metadata under the enclosing transaction", ctx do
    {:ok, %{resource: first}} = import_label(ctx, fields())

    expected = %{
      repository_id: ctx.repository.id,
      local_resource_id: first.local_resource_id,
      expected_local_version: 1,
      expected_fields: first.fields
    }

    assert {:ok, %{resource: ^first}} = observe(expected)
    assert {:error, _, :stale_local_version, _} = observe(%{expected | expected_local_version: 2})

    assert {:error, _, :stale_local_snapshot, _} =
             observe(%{expected | expected_fields: %{first.fields | "color" => "ffffff"}})

    assert {:error, _, :invalid_sync_request, _} = observe(Map.delete(expected, :expected_fields))
  end

  test "loaded label changesets prevent stale metadata writes and forged versions", ctx do
    {:ok, %{resource: first}} = import_label(ctx, fields())
    old = Repo.get!(Label, first.local_resource_id)

    assert {:ok, changed} =
             old |> Label.changeset(%{color: "ffffff", sync_version: 999}) |> Repo.update()

    assert changed.sync_version == 2

    assert {:error, changeset} =
             old
             |> Label.changeset(%{description: "Stale"})
             |> Repo.update(stale_error_field: :id)

    assert Keyword.has_key?(changeset.errors, :id)
    assert Repo.get!(Label, old.id).color == "ffffff"
  end

  test "downstream failure rolls back label, event, and audit together", ctx do
    multi =
      Multi.new()
      |> ForgeIssues.append_sync_label_import(:resource, request(ctx, fields()))
      |> Multi.error(:later, :rollback)

    assert {:error, :later, :rollback, _} = Repo.transaction(multi)
    assert Repo.aggregate(Label, :count) == 0
    refute Repo.exists?(from e in DomainOutboxEvent, where: e.aggregate_type == "label")
    refute Repo.exists?(from a in AuditEvent, where: a.action == "github_sync.label_created")
  end

  test "scope and provenance fail closed", ctx do
    {:ok, %{resource: first}} = import_label(ctx, fields())
    other = repository_fixture(ctx.actor)

    assert {:error, :not_found} =
             ForgeIssues.label_sync_projection(other.id, first.local_resource_id)

    assert {:error, _, :not_found, _} =
             observe(%{
               repository_id: other.id,
               local_resource_id: first.local_resource_id,
               expected_local_version: 1,
               expected_fields: first.fields
             })

    invalid = %{request(ctx, fields()) | provenance: %{origin: :fornacast}}

    assert {:error, _, :invalid_sync_request, _} =
             Multi.new()
             |> ForgeIssues.append_sync_label_import(:resource, invalid)
             |> Repo.transaction()

    ctx.repository |> Changeset.change(deleted_at: DateTime.utc_now(:second)) |> Repo.update!()

    assert {:error, :not_found} =
             ForgeIssues.label_sync_projection(ctx.repository.id, first.local_resource_id)
  end

  test "the database rejects non-positive versions even when changesets are bypassed", ctx do
    {:ok, %{resource: first}} = import_label(ctx, fields())
    row = Repo.get!(Label, first.local_resource_id)

    for invalid <- [0, -1] do
      changeset =
        row
        |> Changeset.change(sync_version: invalid)
        |> Changeset.check_constraint(:sync_version,
          name: :repository_labels_sync_version_positive
        )

      assert {:error, failed} = Repo.update(changeset, mode: :savepoint)
      assert Keyword.has_key?(failed.errors, :sync_version)
    end

    assert Repo.get!(Label, row.id).sync_version == 1
  end

  test "default provisioning stays idempotent and begins with usable versions", ctx do
    labels = ForgeIssues.list_labels(ctx.repository)
    assert Enum.all?(labels, &(&1.sync_version == 1))
    assert labels == ForgeIssues.list_labels(ctx.repository)
  end

  defp fields, do: %{"name" => "Remote", "color" => "123abc", "description" => "Description"}

  defp request(ctx, fields),
    do: %{
      repository_id: ctx.repository.id,
      fields: fields,
      provenance: %{origin: :github, causation_id: "delivery", correlation_id: "operation"}
    }

  defp import_label(ctx, fields),
    do:
      Multi.new()
      |> ForgeIssues.append_sync_label_import(:resource, request(ctx, fields))
      |> Repo.transaction()

  defp observe(expected),
    do:
      Multi.new()
      |> ForgeIssues.append_sync_label_observe(:resource, expected)
      |> Repo.transaction()
end
