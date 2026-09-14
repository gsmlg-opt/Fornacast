defmodule ForgeMirrors.RepositoryMetadataConflictResolutionTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeAccounts.User

  alias ForgeMirrors.{MirrorConflict, MirrorOperation, MirrorResourceState, RepositoryMirror}
  alias ForgeRepos.Repository
  alias Fornacast.{AuditEvent, Repo}

  setup context do
    checkout_options = if context[:committed], do: [sandbox: false], else: []
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, checkout_options)
    suffix = Ecto.UUID.generate()

    organization =
      active_organization_mirror_fixture(%{
        github_installation_id: random_github_id(),
        github_account_id: random_github_id(),
        github_account_login: "github-org-#{suffix}"
      })

    binding =
      repository_mirror_fixture(organization, %{
        github_repository_id: random_github_id(),
        github_node_id: "R_#{suffix}",
        github_full_name: "example/repo-#{suffix}"
      })

    if context[:committed] do
      on_exit(fn -> cleanup_committed_operations(organization.id) end)
    end

    actor = organization_owner_fixture(organization)
    now = DateTime.utc_now(:second)

    %{organization: organization, binding: binding, actor: actor, now: now}
  end

  test "an owner durably requests one exact accept-GitHub resolution and duplicate submission replays",
       c do
    %{conflict: conflict} = create_conflict(c)

    assert {:ok, first} = request(c, conflict, "accept_github")
    assert first.conflict.id == conflict.id
    assert first.conflict.state == :open
    assert first.operation.kind == "reconcile.repository.metadata"
    assert first.operation.state == :pending
    assert first.operation.cursor["trigger"] == "operator_resolution"

    assert %{
             "action" => "accept_github",
             "actor_id" => actor_id,
             "conflict_id" => conflict_id,
             "conflict_lock_version" => lock_version,
             "v" => 1
           } = first.operation.cursor["operator_resolution"]

    assert actor_id == c.actor.id
    assert conflict_id == conflict.id
    assert lock_version == conflict.lock_version

    assert {:ok, replay} = request(c, conflict, "accept_github")
    assert replay.operation.id == first.operation.id

    assert 1 ==
             Repo.aggregate(
               from(operation in MirrorOperation,
                 where:
                   operation.kind == "reconcile.repository.metadata" and
                     operation.repository_mirror_id == ^c.binding.id and
                     operation.state == :pending
               ),
               :count,
               :id
             )

    assert %AuditEvent{
             actor_user_id: actor_id,
             action: "github.repository_metadata_conflict.accept_github.requested",
             target_type: "mirror_conflict"
           } =
             Repo.get_by!(AuditEvent,
               operation_id:
                 "repository-metadata-conflict:#{conflict.id}:#{conflict.lock_version}:accept_github:requested"
             )

    assert actor_id == c.actor.id
  end

  test "a competing resolution, stale capability, foreign owner, and wrong resource are rejected",
       c do
    %{conflict: conflict} = create_conflict(c)
    assert {:ok, _requested} = request(c, conflict, "accept_github")

    assert {:error, :busy} = request(c, conflict, "keep_fornacast")

    assert {:error, :stale} =
             request(c, %{conflict | lock_version: conflict.lock_version + 1}, "accept_github")

    outsider = Repo.get!(User, user_fixture())

    assert {:error, :forbidden} =
             ForgeMirrors.request_repository_metadata_conflict_resolution(
               outsider,
               c.organization.organization_id,
               conflict,
               "accept_github",
               c.now,
               request_metadata()
             )

    assert {:ok, git_conflict} =
             ForgeMirrors.record_conflict(%{
               organization_mirror_id: c.organization.id,
               repository_mirror_id: c.binding.id,
               resource_kind: "git_ref",
               resource_identity: "refs/heads/main",
               conflict_kind: "git_divergence",
               baseline_snapshot: %{"oid" => String.duplicate("0", 40)},
               local_snapshot: %{"oid" => String.duplicate("1", 40)},
               remote_snapshot: %{"oid" => String.duplicate("2", 40)}
             })

    assert {:error, :invalid_transition} = request(c, git_conflict, "external_recheck")
  end

  test "accept GitHub applies the exact canonical remote snapshot before resolving", c do
    %{conflict: conflict, remote: remote} = create_conflict(c)
    assert {:ok, %{operation: operation}} = request(c, conflict, "accept_github")
    claimed = claim(operation, "metadata-resolution-accept", c.now)

    assert {:ok, %{action: :confirmed, operation: completed}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert completed.state == :completed
    assert Repo.get!(Repository, c.binding.repository_id).slug == remote.name

    assert %MirrorConflict{
             state: :resolved,
             resolution: %{"action" => "accept_github", "v" => 1},
             resolved_by_user_id: actor_id
           } = Repo.get!(MirrorConflict, conflict.id)

    assert actor_id == c.actor.id

    assert %AuditEvent{action: "github.repository_metadata_conflict.accept_github.completed"} =
             Repo.get_by!(AuditEvent,
               operation_id:
                 "repository-metadata-conflict:#{conflict.id}:#{conflict.lock_version}:accept_github:completed"
             )
  end

  test "keep Fornacast marks an exact remote effect and resolves only after canonical confirmation",
       c do
    %{conflict: conflict, remote: remote, local: local} = create_conflict(c)
    assert {:ok, %{operation: operation}} = request(c, conflict, "keep_fornacast")
    claimed = claim(operation, "metadata-resolution-keep", c.now)

    assert {:ok, %{action: :update_remote, operation: marked, target: target}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert marked.state == :effect_pending
    assert target == local
    assert Repo.get!(MirrorConflict, conflict.id).state == :open

    confirmed_remote = atomize_remote(target, c.binding, DateTime.add(c.now, 1))

    assert {:ok, %{action: :confirmed, operation: completed}} =
             ForgeMirrors.record_repository_metadata_observation(
               marked,
               confirmed_remote,
               DateTime.add(c.now, 1)
             )

    assert completed.state == :completed

    assert %MirrorConflict{
             state: :resolved,
             resolution: %{"action" => "keep_fornacast", "v" => 1},
             resolved_by_user_id: actor_id
           } = Repo.get!(MirrorConflict, conflict.id)

    assert actor_id == c.actor.id

    assert %AuditEvent{action: "github.repository_metadata_conflict.keep_fornacast.completed"} =
             Repo.get_by!(AuditEvent,
               operation_id:
                 "repository-metadata-conflict:#{conflict.id}:#{conflict.lock_version}:keep_fornacast:completed"
             )
  end

  test "external recheck resolves only after the canonical sides already agree", c do
    %{conflict: conflict, local: local} = create_conflict(c)
    assert {:ok, %{operation: operation}} = request(c, conflict, "external_recheck")
    claimed = claim(operation, "metadata-resolution-recheck", c.now)
    reconciled_remote = atomize_remote(local, c.binding, DateTime.add(c.now, 1))

    assert {:ok, %{action: :confirmed}} =
             ForgeMirrors.record_repository_metadata_observation(
               claimed,
               reconciled_remote,
               DateTime.add(c.now, 1)
             )

    assert %MirrorConflict{
             state: :resolved,
             resolution: %{"action" => "external_recheck", "v" => 1}
           } = Repo.get!(MirrorConflict, conflict.id)
  end

  test "an owner may explicitly keep Fornacast across an archived internal GitHub state", c do
    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata-resolution:policy-conflict",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(
               "metadata-resolution-policy-conflict",
               c.now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)

    remote =
      sync.local_snapshot
      |> atomize_remote(c.binding, c.now)
      |> Map.merge(%{visibility: :internal, archived: true})

    assert {:ok, %{action: :conflict, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert conflict.conflict_kind == "repository_archived_internal_unrepresentable"
    assert {:error, :invalid_transition} = request(c, conflict, "accept_github")
    assert {:ok, %{operation: operation}} = request(c, conflict, "keep_fornacast")
    resolution = claim(operation, "metadata-resolution-policy-keep", c.now)

    assert {:ok, %{action: :update_remote, operation: marked, target: target}} =
             ForgeMirrors.record_repository_metadata_observation(resolution, remote, c.now)

    assert target["visibility"] == "private"
    assert target["archived"] == false

    confirmed = atomize_remote(target, c.binding, DateTime.add(c.now, 1))

    assert {:ok, %{action: :confirmed}} =
             ForgeMirrors.record_repository_metadata_observation(
               marked,
               confirmed,
               DateTime.add(c.now, 1)
             )

    assert %MirrorConflict{
             state: :resolved,
             resolution: %{"action" => "keep_fornacast", "v" => 1}
           } = Repo.get!(MirrorConflict, conflict.id)
  end

  test "changed local or remote evidence invalidates an accept/keep request without mutation",
       c do
    for action <- ["accept_github", "keep_fornacast"] do
      %{conflict: conflict, remote: remote} = create_conflict(c, action)
      assert {:ok, %{operation: operation}} = request(c, conflict, action)

      changed =
        if action == "accept_github" do
          repository = Repo.get!(Repository, c.binding.repository_id)

          repository
          |> Ecto.Changeset.change(description: "changed after operator request")
          |> Ecto.Changeset.optimistic_lock(:write_version)
          |> Repo.update!()

          remote
        else
          %{remote | description: "GitHub changed after operator request"}
        end

      claimed = claim(operation, "metadata-resolution-stale-#{action}", c.now)

      assert {:ok, %{action: :conflict, operation: failed, conflict: refreshed}} =
               ForgeMirrors.record_repository_metadata_observation(claimed, changed, c.now)

      assert failed.state == :failed
      assert refreshed.id == conflict.id
      assert refreshed.lock_version > conflict.lock_version
      assert refreshed.conflict_kind == "repository_metadata_resolution_stale"
      assert Repo.get!(MirrorConflict, conflict.id).state == :open

      expected_audit_action = "github.repository_metadata_conflict.#{action}.failed"

      assert %AuditEvent{
               action: ^expected_audit_action,
               metadata: %{"failure_class" => "stale_baseline"}
             } =
               Repo.get_by!(AuditEvent,
                 operation_id:
                   "repository-metadata-conflict:#{conflict.id}:#{conflict.lock_version}:#{action}:failed"
               )
    end
  end

  test "revoking the requesting owner before execution fails closed without a local or remote effect",
       c do
    %{conflict: conflict, remote: remote} = create_conflict(c)
    before_repository = Repo.get!(Repository, c.binding.repository_id)
    assert {:ok, %{operation: operation}} = request(c, conflict, "keep_fornacast")

    Repo.delete_all(
      from(member in ForgeAccounts.OrganizationMember,
        where:
          member.organization_id == ^c.organization.organization_id and
            member.user_id == ^c.actor.id
      )
    )

    claimed = claim(operation, "metadata-resolution-revoked-owner", c.now)

    assert {:ok, %{action: :conflict, operation: failed, conflict: refreshed}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    assert failed.state == :failed
    assert failed.failure_class == "permission_missing"
    assert failed.external_effect_marker == nil
    assert refreshed.id == conflict.id
    assert refreshed.state == :open
    assert refreshed.conflict_kind == "repository_metadata_resolution_unauthorized"

    assert Repo.get!(Repository, c.binding.repository_id).write_version ==
             before_repository.write_version

    assert %AuditEvent{
             action: "github.repository_metadata_conflict.keep_fornacast.failed",
             metadata: %{"failure_class" => "permission_missing"}
           } =
             Repo.get_by!(AuditEvent,
               operation_id:
                 "repository-metadata-conflict:#{conflict.id}:#{conflict.lock_version}:keep_fornacast:failed"
             )
  end

  test "a terminal provider failure records a failed outcome rather than a completed action", c do
    %{conflict: conflict} = create_conflict(c)
    assert {:ok, %{operation: operation}} = request(c, conflict, "accept_github")
    claimed = claim(operation, "metadata-resolution-provider-failure", c.now)

    assert {:ok, failed} =
             ForgeMirrors.fail_repository_metadata_operation(
               claimed,
               c.now,
               "provider_validation",
               "canonical repository response was rejected"
             )

    assert failed.state == :failed
    assert Repo.get!(MirrorConflict, conflict.id).state == :open

    assert %AuditEvent{
             action: "github.repository_metadata_conflict.accept_github.failed",
             metadata: %{
               "failure_class" => "provider_validation",
               "failure_detail" => "canonical repository response was rejected"
             }
           } =
             Repo.get_by!(AuditEvent,
               operation_id:
                 "repository-metadata-conflict:#{conflict.id}:#{conflict.lock_version}:accept_github:failed"
             )

    refute Repo.get_by(AuditEvent,
             operation_id:
               "repository-metadata-conflict:#{conflict.id}:#{conflict.lock_version}:accept_github:completed"
           )
  end

  @tag committed: true
  test "a periodic worker lock and an owner resolution request use one non-deadlocking order",
       c do
    %{conflict: conflict, operation: periodic_operation} = create_conflict(c)
    parent = self()

    worker =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.one!(
            from(operation in MirrorOperation,
              where: operation.id == ^periodic_operation.id,
              lock: "FOR UPDATE"
            )
          )

          Repo.one!(
            from(binding in RepositoryMirror,
              where: binding.id == ^c.binding.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, :periodic_binding_locked)

          receive do
            :continue_periodic_lock_order -> :ok
          after
            5_000 -> raise "resolution request did not start"
          end

          Repo.one!(
            from(organization in ForgeMirrors.OrganizationMirror,
              where: organization.id == ^c.organization.id,
              lock: "FOR UPDATE"
            )
          )

          Repo.one!(
            from(locked_conflict in MirrorConflict,
              where: locked_conflict.id == ^conflict.id,
              lock: "FOR UPDATE"
            )
          )

          :locked
        end)
      end)

    assert_receive :periodic_binding_locked, 5_000

    requester =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        %{rows: [[backend_pid]]} =
          Ecto.Adapters.SQL.query!(Repo, "select pg_backend_pid()", [])

        send(parent, {:requester_backend, backend_pid})
        request(c, conflict, "accept_github")
      end)

    assert_receive {:requester_backend, backend_pid}, 5_000
    assert :ok = wait_for_database_lock(backend_pid)

    probe =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.one!(
            from(locked_conflict in MirrorConflict,
              where: locked_conflict.id == ^conflict.id,
              lock: "FOR UPDATE NOWAIT"
            )
          )

          :conflict_available
        end)
      end)

    assert {:ok, :conflict_available} = Task.await(probe, 5_000)
    send(worker.pid, :continue_periodic_lock_order)

    assert {:ok, :locked} = Task.await(worker, 5_000)

    assert {:ok, %{operation: %MirrorOperation{state: :pending} = requested}} =
             Task.await(requester, 5_000)

    Repo.update_all(
      from(operation in MirrorOperation, where: operation.id == ^requested.id),
      set: [
        state: :failed,
        failure_class: "local_validation",
        failure_disposition: :terminal,
        failure_detail: "concurrency regression cleanup",
        updated_at: c.now
      ]
    )
  end

  defp request(c, conflict, action) do
    ForgeMirrors.request_repository_metadata_conflict_resolution(
      c.actor,
      c.organization.organization_id,
      conflict,
      action,
      c.now,
      request_metadata()
    )
  end

  defp create_conflict(c, suffix \\ "default") do
    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               Repo.get!(RepositoryMirror, c.binding.id),
               "metadata-resolution:conflict:#{suffix}",
               c.now
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(
               "metadata-resolution-conflict-#{suffix}",
               c.now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert {:ok, sync} = ForgeMirrors.repository_metadata_operation_context(claimed)
    remote = atomize_remote(sync.local_snapshot, c.binding, c.now)
    remote = %{remote | name: "remote-#{suffix}"}

    assert {:ok, %{action: :conflict, operation: operation, conflict: conflict}} =
             ForgeMirrors.record_repository_metadata_observation(claimed, remote, c.now)

    %{
      conflict: conflict,
      operation: operation,
      remote: remote,
      local: sync.local_snapshot,
      baseline: Repo.get_by(MirrorResourceState, repository_mirror_id: c.binding.id)
    }
  end

  defp claim(operation, owner, now) do
    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations(
               owner,
               now,
               60,
               1,
               ["reconcile.repository.metadata"]
             )

    assert claimed.id == operation.id
    claimed
  end

  defp atomize_remote(snapshot, binding, updated_at) do
    %{
      id: binding.github_repository_id,
      node_id: binding.github_node_id,
      name: snapshot["name"],
      description: snapshot["description"],
      visibility: String.to_existing_atom(snapshot["visibility"]),
      default_branch: snapshot["default_branch"],
      archived: snapshot["archived"],
      updated_at: updated_at
    }
  end

  defp request_metadata do
    %{
      request_id: Ecto.UUID.generate(),
      ip_address: "127.0.0.1",
      user_agent: "repository-metadata-conflict-resolution-test"
    }
  end

  defp random_github_id,
    do: max(7 |> :crypto.strong_rand_bytes() |> :binary.decode_unsigned(), 1)

  defp wait_for_database_lock(backend_pid, attempts \\ 100)

  defp wait_for_database_lock(_backend_pid, 0),
    do: flunk("resolution request did not block on the held repository binding")

  defp wait_for_database_lock(backend_pid, attempts) do
    case Ecto.Adapters.SQL.query!(
           Repo,
           "select wait_event_type from pg_stat_activity where pid = $1",
           [backend_pid]
         ).rows do
      [["Lock"]] ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_database_lock(backend_pid, attempts - 1)
    end
  end

  defp cleanup_committed_operations(organization_mirror_id) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.update_all(
        from(operation in MirrorOperation,
          where:
            operation.organization_mirror_id == ^organization_mirror_id and
              operation.state in [:pending, :processing, :effect_pending]
        ),
        set: [
          state: :failed,
          lease_owner: nil,
          lease_expires_at: nil,
          external_effect_marker: nil,
          effect_marked_at: nil,
          failure_class: "local_validation",
          failure_disposition: :terminal,
          failure_detail: "concurrency regression cleanup",
          updated_at: DateTime.utc_now(:second)
        ]
      )

      Repo.update_all(
        from(organization in ForgeMirrors.OrganizationMirror,
          where: organization.id == ^organization_mirror_id
        ),
        set: [state: :revoked, updated_at: DateTime.utc_now(:second)]
      )
    end)
  end
end
