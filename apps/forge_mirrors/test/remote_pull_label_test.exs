defmodule ForgeMirrors.RemotePullLabelTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Ecto.Multi
  alias ForgeMirrors.{MirrorOperation, MirrorResourceState}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    binding = repository_mirror_fixture(org)
    now = DateTime.utc_now(:second)

    op =
      operation_fixture(org, %{
        repository_mirror_id: binding.id,
        kind: "sync.pull",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "pull",
          "github_object_id" => 1700,
          "github_number" => 7
        },
        checkpoint: %{"discovery" => "preserved"},
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("remote-pull-label", now, 120, 100, ["sync.pull"])

    op = Enum.find(claimed, &(&1.id == op.id))

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^op.id),
      set: [checkpoint: %{"discovery" => "preserved"}]
    )

    op = Repo.get!(MirrorOperation, op.id)
    fields = %{"name" => "discovery", "color" => "abcdef", "description" => nil}

    expected = %{
      resource_state_lock_version: :missing,
      local_label_id: nil,
      expected_local_version: nil,
      expected_local_fingerprint: nil,
      github_object_id: 500,
      effect_marker: nil
    }

    confirmation = %{
      github_object_id: 500,
      github_node_id: "LA_500",
      confirmed_snapshot: fields,
      confirmed_local_version: nil
    }

    request = %{
      repository_id: binding.repository_id,
      fields: fields,
      provenance: %{origin: :github}
    }

    %{
      org: org,
      binding: binding,
      op: op,
      now: now,
      expected: expected,
      confirmation: confirmation,
      request: request
    }
  end

  test "one imported label is mapped and same parent yields without a child operation", c do
    count = Repo.aggregate(MirrorOperation, :count)
    assert {:ok, result} = confirm(c)
    assert result.operation.state == :pending
    assert result.operation.id == c.op.id
    assert result.operation.cursor == c.op.cursor
    assert result.operation.checkpoint == c.op.checkpoint
    assert result.operation.lease_owner == nil
    assert result.resource_state.resource_kind == :label
    assert result.resource_state.github_object_id == 500
    assert result.resource_state.confirmed_local_version == 1
    assert Repo.aggregate(MirrorOperation, :count) == count
    refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.binding.repository_id)

    assert {:ok, claimed} =
             ForgeMirrors.claim_operations("remote-pull-label-next", c.now, 120, 100, [
               "sync.pull"
             ])

    reclaimed = Enum.find(claimed, &(&1.id == c.op.id))
    assert {:ok, %{mode: :inbound_create}} = ForgeMirrors.remote_pull_creation_context(reclaimed)
  end

  test "compatible existing label is adopted at actual version without a duplicate", c do
    {:ok, %{resource: label}} =
      Multi.new()
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> Repo.transaction()

    Repo.update_all(from(l in "repository_labels", where: l.id == ^label.local_resource_id),
      set: [sync_version: 2]
    )

    assert {:ok, result} = confirm(c)
    assert result.resource_state.local_resource_id == label.local_resource_id
    assert result.resource_state.confirmed_local_version == 2

    assert Repo.aggregate(
             from(l in "repository_labels", where: l.repository_id == ^c.binding.repository_id),
             :count
           ) == 1
  end

  test "fake projection cannot create a mapping without an actual label", c do
    callback = fn multi ->
      Multi.put(multi, :resource, %{
        repository_id: c.binding.repository_id,
        resource_kind: :label,
        local_resource_type: "ForgeIssues.Label",
        local_resource_id: 999_999_999,
        local_version: 1,
        fields: c.request.fields
      })
    end

    assert {:error, :invalid_projection} = confirm(c, callback)

    refute Repo.exists?(
             from m in MirrorResourceState, where: m.repository_mirror_id == ^c.binding.id
           )
  end

  test "two valid label imports cannot leave an unmapped extra label", c do
    callback = fn multi ->
      multi
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> ForgeIssues.append_sync_label_import(:orphan, %{
        c.request
        | fields: %{c.request.fields | "name" => "extra"}
      })
    end

    assert {:error, :invalid_projection} = confirm(c, callback)

    refute Repo.exists?(
             from l in "repository_labels", where: l.repository_id == ^c.binding.repository_id
           )
  end

  test "callback cannot create an unrelated canonical issue while importing its prerequisite",
       c do
    actor = organization_owner_fixture(c.org)
    repository = Repo.get!(ForgeRepos.Repository, c.binding.repository_id)

    callback = fn multi ->
      multi
      |> ForgeIssues.append_sync_label_import(:resource, c.request)
      |> ForgeIssues.insert_numbered_identity(:unrelated, repository, actor, :issue, %{
        title: "unrelated"
      })
    end

    assert {:error, :invalid_projection} = confirm(c, callback)
    refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.binding.repository_id)

    refute Repo.exists?(
             from l in "repository_labels", where: l.repository_id == ^c.binding.repository_id
           )

    refute Repo.get(ForgeIssues.NumberSequence, c.binding.repository_id)
  end

  test "partial parent identity and local or effect-pending work fail before callback", c do
    callback = fn _ -> flunk("must not invoke label callback") end

    partial =
      Repo.insert!(%MirrorResourceState{
        repository_mirror_id: c.binding.id,
        resource_kind: :issue,
        github_number: 7,
        github_object_id: 700,
        state: :pending
      })

    assert {:error, :identity_conflict} = confirm(c, callback)
    Repo.delete!(partial)

    for attrs <- [
          [cursor: Map.put(c.op.cursor, "trigger", "local")],
          [
            state: :effect_pending,
            external_effect_marker: %{"action" => "create_remote_pull"},
            effect_marked_at: c.now
          ]
        ] do
      Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id), set: attrs)
      assert {:error, _} = confirm(%{c | op: Repo.get!(MirrorOperation, c.op.id)}, callback)

      Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id),
        set: [
          cursor: c.op.cursor,
          state: :processing,
          external_effect_marker: nil,
          effect_marked_at: nil
        ]
      )
    end
  end

  test "revocation and lease loss inside callback roll back label and mapping", c do
    for action <- [:revoke, :expire] do
      callback = fn multi ->
        multi
        |> ForgeIssues.append_sync_label_import(:resource, c.request)
        |> Multi.run(:change_scope, fn repo, _ ->
          case action do
            :revoke ->
              repo.update_all(
                from(o in ForgeMirrors.OrganizationMirror, where: o.id == ^c.org.id),
                set: [state: :revoked]
              )

            :expire ->
              repo.update_all(from(o in MirrorOperation, where: o.id == ^c.op.id),
                set: [lease_expires_at: DateTime.add(c.now, -1)]
              )
          end

          {:ok, :changed}
        end)
      end

      assert {:error, _} = confirm(c, callback)

      refute Repo.exists?(
               from l in "repository_labels", where: l.repository_id == ^c.binding.repository_id
             )

      refute Repo.exists?(
               from m in MirrorResourceState, where: m.repository_mirror_id == ^c.binding.id
             )
    end
  end

  defp confirm(c, callback \\ nil),
    do:
      ForgeMirrors.confirm_remote_pull_label(
        c.op,
        c.now,
        c.expected,
        c.confirmation,
        callback ||
          fn multi -> ForgeIssues.append_sync_label_import(multi, :resource, c.request) end
      )
end
