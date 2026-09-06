defmodule ForgeMirrors.ResourceConflictSnapshotTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.MirrorConflict
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture()

    %{
      attrs: %{
        organization_mirror_id: organization.id,
        resource_kind: "issue",
        resource_identity: "issue:123",
        conflict_kind: "concurrent_edit",
        baseline_snapshot: %{"body" => String.duplicate("界", 65_536)},
        local_snapshot: %{"body" => String.duplicate("文", 65_536)},
        remote_snapshot: %{"body" => String.duplicate("語", 65_536)}
      }
    }
  end

  test "conflicts retain all supported body values without truncation", %{attrs: attrs} do
    assert {:ok, conflict} =
             %MirrorConflict{} |> MirrorConflict.record_changeset(attrs) |> Repo.insert()

    reloaded = Repo.get!(MirrorConflict, conflict.id)

    for field <- [:baseline_snapshot, :local_snapshot, :remote_snapshot] do
      assert Map.fetch!(reloaded, field) == Map.fetch!(attrs, field)
    end
  end

  test "oversized snapshots remain rejected by changesets", %{attrs: attrs} do
    changeset =
      MirrorConflict.record_changeset(
        %MirrorConflict{},
        Map.put(attrs, :local_snapshot, %{"body" => String.duplicate("x", 2_000_001)})
      )

    assert Keyword.has_key?(changeset.errors, :local_snapshot)
  end

  test "database independently bounds the expanded snapshot size", %{attrs: attrs} do
    conflict = %MirrorConflict{} |> MirrorConflict.record_changeset(attrs) |> Repo.insert!()

    assert_raise Postgrex.Error, ~r/mirror_conflicts_local_snapshot_check/, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE mirror_conflicts SET local_snapshot = $1::jsonb WHERE id = $2",
        [%{"body" => String.duplicate("x", 2_000_001)}, conflict.id]
      )
    end
  end
end
