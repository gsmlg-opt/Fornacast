defmodule ForgeMirrors.ResourceBaselineTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.MirrorResourceState
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    mirror = active_organization_mirror_fixture() |> repository_mirror_fixture()

    %{
      attrs: %{
        repository_mirror_id: mirror.id,
        resource_kind: :issue,
        local_resource_type: "issue",
        local_resource_id: 123,
        github_object_id: 456,
        state: :confirmed,
        confirmed_local_version: 1,
        confirmed_fingerprint: "fingerprint"
      }
    }
  end

  test "persists the canonical baseline needed for field and set comparisons", %{attrs: attrs} do
    snapshot = %{
      "title" => "Baseline",
      "body" => String.duplicate("界", 30_000),
      "state" => "open",
      "state_reason" => nil,
      "labels" => [23, 42],
      "assignees" => [17]
    }

    assert {:ok, state} =
             %MirrorResourceState{}
             |> MirrorResourceState.persistence_changeset(
               Map.put(attrs, :confirmed_snapshot, snapshot)
             )
             |> Repo.insert()

    reloaded = Repo.get!(MirrorResourceState, state.id)
    assert Map.get(reloaded, :confirmed_snapshot) == snapshot
    assert reloaded.confirmed_fingerprint == "fingerprint"
    assert reloaded.confirmed_local_version == 1
  end

  test "legacy missing baselines remain distinguishable from empty objects", %{attrs: attrs} do
    assert {:ok, state} =
             %MirrorResourceState{}
             |> MirrorResourceState.persistence_changeset(attrs)
             |> Repo.insert()

    assert Map.get(state, :confirmed_snapshot) == nil

    assert {:ok, updated} =
             state
             |> MirrorResourceState.persistence_changeset(%{confirmed_snapshot: %{}})
             |> Repo.update()

    assert Map.get(updated, :confirmed_snapshot) == %{}
  end

  test "snapshot size stays bounded without dropping long supported bodies", %{attrs: attrs} do
    changeset =
      MirrorResourceState.persistence_changeset(
        %MirrorResourceState{},
        Map.put(attrs, :confirmed_snapshot, %{"body" => String.duplicate("x", 2_000_001)})
      )

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :confirmed_snapshot)
  end

  for {name, snapshot} <- [
        {"arrays", []},
        {"oversized objects", %{"body" => String.duplicate("x", 2_000_001)}}
      ] do
    test "database rejects #{name} even when changeset validation is bypassed", %{attrs: attrs} do
      state =
        %MirrorResourceState{}
        |> MirrorResourceState.persistence_changeset(attrs)
        |> Repo.insert!()

      assert_raise Postgrex.Error, ~r/mirror_resource_states_snapshot_check/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE mirror_resource_states SET confirmed_snapshot = $1::jsonb WHERE id = $2",
          [unquote(Macro.escape(snapshot)), state.id]
        )
      end
    end
  end
end
