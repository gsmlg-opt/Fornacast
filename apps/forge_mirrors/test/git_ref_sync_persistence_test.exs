defmodule ForgeMirrors.GitRefSyncPersistenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo

  alias ForgeMirrors.{MirrorConflict, MirrorOperation, MirrorWebhookDelivery}
  alias ForgeRepos.Repository

  @oid String.duplicate("a", 40)
  @other_oid String.duplicate("b", 40)
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)
    %{organization_mirror: organization_mirror, repository_mirror: repository_mirror}
  end

  test "authenticated webhook ref hints enqueue one idempotent repository operation", context do
    delivery = %MirrorWebhookDelivery{
      delivery_guid: Ecto.UUID.generate(),
      installation_id: context.organization_mirror.github_installation_id,
      github_repository_id: context.repository_mirror.github_repository_id
    }

    assert {:ok, {:scheduled, first}} =
             ForgeMirrors.retain_webhook_git_ref_trigger(
               delivery,
               "refs/heads/new",
               true
             )

    assert {:ok, {:scheduled, replayed}} =
             ForgeMirrors.retain_webhook_git_ref_trigger(
               delivery,
               "refs/heads/new",
               true
             )

    assert replayed.id == first.id
    assert first.kind == "sync.git_ref"
    assert first.cursor["initial_absence"]
    assert first.cursor["trigger"] == "remote"
  end

  test "baseline confirmation and operation completion commit atomically", context do
    now = DateTime.utc_now(:second)
    operation = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)

    assert {:ok, %{operation: completed, ref_state: state}} =
             ForgeMirrors.confirm_git_ref(operation, "refs/heads/main", @oid, @oid, now)

    assert completed.state == :completed
    assert state.state == :confirmed
    assert state.confirmed_oid == @oid
    assert state.last_local_oid == @oid
    assert state.last_remote_oid == @oid
    assert state.last_confirmed_at == now
  end

  test "conflict persistence marks the ref and operation in one transaction and deduplicates",
       context do
    now = DateTime.utc_now(:second)
    first = operation(context, "refs/heads/main", Ecto.UUID.generate(), now) |> claim!(now)

    assert {:ok, %{operation: failed, conflict: conflict, ref_state: state}} =
             ForgeMirrors.conflict_git_ref(
               first,
               "refs/heads/main",
               :git_divergence,
               @oid,
               @oid,
               @other_oid,
               now
             )

    assert failed.state == :failed
    assert failed.failure_disposition == :conflict
    assert state.state == :conflicted
    assert conflict.state == :open
    assert conflict.conflict_kind == "git_divergence"

    later = DateTime.add(now, 1)
    second = operation(context, "refs/heads/main", Ecto.UUID.generate(), later) |> claim!(later)

    assert {:ok, %{conflict: replayed}} =
             ForgeMirrors.conflict_git_ref(
               second,
               "refs/heads/main",
               :git_divergence,
               @oid,
               @oid,
               @other_oid,
               later
             )

    assert replayed.id == conflict.id

    assert Repo.aggregate(
             from(candidate in MirrorConflict,
               where:
                 candidate.repository_mirror_id == ^context.repository_mirror.id and
                   candidate.resource_identity == "refs/heads/main" and
                   candidate.state == :open
             ),
             :count
           ) == 1
  end

  test "repository reconciliation fans out bounded per-ref work before a finalizer", context do
    now = DateTime.utc_now(:second)

    {:ok, parent} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: "reconcile.repository.bootstrap",
        dedupe_key: Ecto.UUID.generate(),
        cursor: %{"baseline" => "seeded"},
        next_attempt_at: now
      })

    parent = claim!(parent, now)

    assert {:ok, %{operation: completed, ref_operations: [branch, tag], finalizer: finalizer}} =
             ForgeMirrors.fanout_git_ref_reconciliation(
               parent,
               ["refs/tags/v1.0.0", "refs/heads/main"],
               now
             )

    assert completed.state == :completed

    assert Enum.map([branch, tag], & &1.cursor["ref_name"]) == [
             "refs/heads/main",
             "refs/tags/v1.0.0"
           ]

    assert Enum.all?([branch, tag], &(&1.kind == "sync.git_ref"))
    assert finalizer.kind == "finalize.repository.git"
    assert finalizer.id > tag.id
  end

  test "repository reconciliation finalizer records a successful Git sweep", context do
    now = DateTime.utc_now(:second)

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => 41}, now)
      |> claim!(now)

    assert {:ok, %{operation: completed, repository_mirror: repository_mirror}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert completed.state == :completed
    assert repository_mirror.last_synced_at == now
  end

  test "repository reconciliation finalizer fails while a Git ref conflict is open", context do
    now = DateTime.utc_now(:second)

    assert {:ok, _conflict} =
             ForgeMirrors.record_conflict(%{
               organization_mirror_id: context.organization_mirror.id,
               repository_mirror_id: context.repository_mirror.id,
               resource_kind: "git_ref",
               resource_identity: "refs/heads/main",
               conflict_kind: "git_divergence",
               baseline_snapshot: %{"oid" => @oid},
               local_snapshot: %{"oid" => @oid},
               remote_snapshot: %{"oid" => @other_oid}
             })

    finalizer =
      finalizer_operation(context, %{"reconciliation_operation_id" => 42}, now)
      |> claim!(now)

    assert {:ok, %{operation: failed, repository_mirror: nil}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert failed.state == :failed
    assert failed.failure_class == "git_divergence"
    assert failed.failure_disposition == :conflict
  end

  test "claimed ref context resolves the immutable repository binding and confirmed absence",
       context do
    now = DateTime.utc_now(:second)
    relative_path = "git-ref-sync/#{Ecto.UUID.generate()}.git"
    repository_path = Fornacast.Storage.repository_path!(relative_path)
    File.mkdir_p!(Path.dirname(repository_path))
    assert {:ok, _path} = GitCore.init_bare(repository_path)
    on_exit(fn -> File.rm_rf!(repository_path) end)

    context.repository_mirror.repository_id
    |> then(&Repo.get!(Repository, &1))
    |> Ecto.Changeset.change(storage_path: relative_path)
    |> Repo.update!()

    {:ok, installation} =
      ForgeMirrors.get_github_app_installation(context.organization_mirror.github_installation_id)

    assert {:ok, _updated} =
             ForgeMirrors.observe_github_app_installation(%{
               github_installation_id: installation.github_installation_id,
               github_account_id: installation.github_account_id,
               github_account_login: installation.github_account_login,
               account_type: installation.account_type,
               repository_selection: installation.repository_selection,
               permissions: %{"contents" => "write", "metadata" => "read"},
               state: :active,
               last_verified_at: DateTime.add(installation.last_verified_at, 1)
             })

    operation =
      operation(context, "refs/heads/new", Ecto.UUID.generate(), now)
      |> then(fn operation ->
        operation
        |> Ecto.Changeset.change(cursor: Map.put(operation.cursor, "initial_absence", true))
        |> Repo.update!()
      end)
      |> claim!(now)

    assert {:ok, sync} = ForgeMirrors.git_ref_operation_context(operation)
    assert sync.baseline == nil
    assert sync.repository_path == repository_path
    assert sync.ref_name == "refs/heads/new"
    assert sync.ref_kind == :branch
    assert sync.remote_repository != ""
    assert sync.github_installation_id == installation.github_installation_id
  end

  defp operation(context, ref_name, dedupe_key, now) do
    operation(
      context,
      "sync.git_ref",
      %{"initial_absence" => false, "ref_name" => ref_name, "trigger" => "reconcile"},
      dedupe_key,
      now
    )
  end

  defp finalizer_operation(context, cursor, now) do
    operation(context, "finalize.repository.git", cursor, Ecto.UUID.generate(), now)
  end

  defp operation(context, kind, cursor, dedupe_key, now) do
    {:ok, operation} =
      ForgeMirrors.enqueue_operation(%{
        organization_mirror_id: context.organization_mirror.id,
        repository_mirror_id: context.repository_mirror.id,
        kind: kind,
        dedupe_key: dedupe_key,
        cursor: cursor,
        next_attempt_at: now
      })

    operation
  end

  defp claim!(%MirrorOperation{id: id}, now) do
    assert {:ok, [claimed]} = ForgeMirrors.claim_operations("git-ref-test", now, 30, 1)
    assert claimed.id == id
    claimed
  end
end
