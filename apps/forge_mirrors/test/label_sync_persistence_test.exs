defmodule ForgeMirrors.LabelSyncPersistenceTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture(%{capabilities: %{"issues" => "enabled"}})
    binding = repository_mirror_fixture(organization)
    now = DateTime.utc_now(:second)

    pending =
      operation_fixture(organization, %{
        repository_mirror_id: binding.id,
        kind: "sync.issue",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "issue",
          "github_object_id" => 456,
          "github_number" => 7
        },
        next_attempt_at: now
      })

    {:ok, operations} =
      ForgeMirrors.claim_operations("label-parent", now, 60, 100, ["sync.issue"])

    %{binding: binding, operation: Enum.find(operations, &(&1.id == pending.id)), now: now}
  end

  test "compatible label adoption persists actual domain version and yields the unchanged parent",
       c do
    projection = projection(c, 4)

    assert {:ok, %{operation: parent, resource_state: mapping}} =
             ForgeMirrors.confirm_label_for_resource_operation(
               c.operation,
               c.now,
               expected(),
               confirmation(),
               callback(projection)
             )

    assert parent.state == :pending
    assert parent.cursor == c.operation.cursor
    assert parent.lease_owner == nil
    assert mapping.resource_kind == :label
    assert mapping.local_resource_type == "ForgeIssues.Label"
    assert mapping.confirmed_local_version == 4
    assert mapping.confirmed_snapshot == fields()
  end

  test "local metadata changes roll back callback writes and never publish a mapping", c do
    {:ok, digest} = ForgeMirrors.resource_fingerprint(fields())

    expected = %{
      expected()
      | local_label_id: 123,
        expected_local_version: 1,
        expected_local_fingerprint: digest
    }

    callback = fn multi ->
      Ecto.Multi.run(multi, :resource, fn _, _ ->
        c.binding |> Ecto.Changeset.change(github_full_name: "changed/path") |> Repo.update!()
        {:ok, %{projection(c, 2) | fields: Map.put(fields(), "color", "ffffff")}}
      end)
    end

    assert {:error, :invalid_projection} =
             ForgeMirrors.confirm_label_for_resource_operation(
               c.operation,
               c.now,
               expected,
               confirmation(),
               callback
             )

    assert Repo.get!(ForgeMirrors.RepositoryMirror, c.binding.id).github_full_name ==
             c.binding.github_full_name

    refute Repo.exists?(MirrorResourceState)
    assert Repo.get!(MirrorOperation, c.operation.id).state == :processing
  end

  test "an external label effect is confirmed before its parent resumes", c do
    marker = %{"action" => "create_remote_label", "local_label_id" => 123}
    assert {:ok, marked} = ForgeMirrors.mark_external_effect(c.operation, c.now, marker)

    assert {:ok, %{operation: parent}} =
             ForgeMirrors.confirm_label_for_resource_operation(
               marked,
               c.now,
               %{expected() | effect_marker: marker},
               confirmation(),
               callback(projection(c, 1))
             )

    assert parent.state == :pending
    assert parent.external_effect_marker == nil
    assert parent.effect_marked_at == nil
    assert parent.cursor == c.operation.cursor
  end

  test "changed expected marker cannot run the domain callback", c do
    marker = %{"action" => "create_remote_label", "local_label_id" => 123}
    assert {:ok, marked} = ForgeMirrors.mark_external_effect(c.operation, c.now, marker)

    assert {:error, :stale_baseline} =
             ForgeMirrors.confirm_label_for_resource_operation(
               marked,
               c.now,
               expected(),
               confirmation(),
               fn _ -> flunk("stale marker") end
             )
  end

  test "confirmation cannot replace a label mapping's immutable local identity", c do
    mapping =
      %MirrorResourceState{}
      |> MirrorResourceState.persistence_changeset(%{
        repository_mirror_id: c.binding.id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: 123,
        github_object_id: 777,
        github_node_id: "LA_777",
        state: :confirmed
      })
      |> Repo.insert!()

    expected = %{
      expected()
      | resource_state_lock_version: mapping.lock_version,
        github_object_id: 777
    }

    assert {:error, :invalid_projection} =
             ForgeMirrors.confirm_label_for_resource_operation(
               c.operation,
               c.now,
               expected,
               confirmation(),
               callback(%{projection(c, 1) | local_resource_id: 124})
             )

    assert Repo.get!(MirrorResourceState, mapping.id).local_resource_id == 123
  end

  test "confirmation cannot substitute another observed remote identity", c do
    assert {:error, :stale_baseline} =
             ForgeMirrors.confirm_label_for_resource_operation(
               c.operation,
               c.now,
               %{expected() | github_object_id: 888},
               confirmation(),
               fn _ -> flunk("identity mismatch must precede callback") end
             )
  end

  test "label effect marking proves exact local metadata in its transaction", c do
    {:ok, digest} = ForgeMirrors.resource_fingerprint(fields())

    expected = %{
      expected()
      | local_label_id: 123,
        expected_local_version: 1,
        expected_local_fingerprint: digest
    }

    marker = %{
      "action" => "create_remote_label",
      "local_label_id" => 123,
      "expected_local_version" => 1,
      "expected_local_fingerprint" => digest
    }

    assert {:ok, %{operation: marked}} =
             ForgeMirrors.mark_label_effect_for_resource_operation(
               c.operation,
               c.now,
               expected,
               marker,
               callback(projection(c, 1))
             )

    assert marked.state == :effect_pending
    assert marked.external_effect_marker == marker
  end

  test "changed local version prevents marking a provider label create", c do
    {:ok, digest} = ForgeMirrors.resource_fingerprint(fields())

    expected = %{
      expected()
      | local_label_id: 123,
        expected_local_version: 1,
        expected_local_fingerprint: digest
    }

    marker = %{
      "action" => "create_remote_label",
      "local_label_id" => 123,
      "expected_local_version" => 1,
      "expected_local_fingerprint" => digest
    }

    assert {:error, :invalid_projection} =
             ForgeMirrors.mark_label_effect_for_resource_operation(
               c.operation,
               c.now,
               expected,
               marker,
               callback(projection(c, 2))
             )

    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker == nil
  end

  defp expected,
    do: %{
      resource_state_lock_version: :missing,
      local_label_id: nil,
      expected_local_version: nil,
      expected_local_fingerprint: nil,
      github_object_id: nil,
      effect_marker: nil
    }

  defp confirmation,
    do: %{github_object_id: 777, github_node_id: "LA_777", confirmed_snapshot: fields()}

  defp fields, do: %{"name" => "bug", "color" => "aa0000", "description" => nil}

  defp projection(c, version),
    do: %{
      repository_id: c.binding.repository_id,
      resource_kind: :label,
      local_resource_type: "ForgeIssues.Label",
      local_resource_id: 123,
      local_version: version,
      fields: fields()
    }

  defp callback(projection), do: &Ecto.Multi.run(&1, :resource, fn _, _ -> {:ok, projection} end)
end
