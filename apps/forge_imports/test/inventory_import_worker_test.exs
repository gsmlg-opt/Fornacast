defmodule ForgeImports.InventoryImportWorkerTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeImports.{ImportRun, Persistence, RepositoryItem}
  alias ForgeImports.OrganizationSync.InventoryImportWorker
  alias ForgeMirrors.{MirrorOperation, OrganizationMirror, RepositoryMirror}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "materializes one repository import and releases the FIFO parent after handoff" do
    now = DateTime.utc_now(:second)

    organization_mirror =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled"},
        policy: %{
          "direction" => "bidirectional",
          "new_github_repositories" => "import",
          "new_local_repositories" => "ignore",
          "repository_selection" => "all"
        }
      })

    actor = organization_owner_fixture(organization_mirror)
    github_repository_id = System.unique_integer([:positive, :monotonic])

    assert {:ok, repository_mirror} =
             ForgeMirrors.bind_repository(actor, %{
               organization_mirror_id: organization_mirror.id,
               github_repository_id: github_repository_id,
               github_node_id: "R_inventory_#{github_repository_id}",
               github_full_name: "#{organization_mirror.github_account_login}/inventory-repo"
             })

    assert {:ok, operation} =
             ForgeMirrors.enqueue_operation(%{
               organization_mirror_id: organization_mirror.id,
               repository_mirror_id: repository_mirror.id,
               kind: "bootstrap.repository_import",
               dedupe_key: "inventory-bootstrap:#{repository_mirror.id}",
               cursor: %{
                 "github_repository_id" => github_repository_id,
                 "source" => "inventory"
               },
               next_attempt_at: now
             })

    context = fn _claimed ->
      {:ok,
       %{
         actor: actor,
         organization_mirror: Repo.get!(OrganizationMirror, organization_mirror.id),
         repository_mirror: Repo.get!(RepositoryMirror, repository_mirror.id)
       }}
    end

    discovery = fn run_id, _owner, _options ->
      run = Repo.get!(ImportRun, run_id)
      assert run.destination_organization_id == organization_mirror.organization_id

      if is_nil(run.predecessor_run_id) do
        Repo.update_all(from(candidate in ImportRun, where: candidate.id == ^run.id),
          set: [
            state: :failed,
            failure_kind: "credential_service_unavailable",
            terminal_at: now
          ]
        )

        {:ok, :failed}
      else
        assert {:ok, _item} =
                 Persistence.insert_repository_item(%{
                   import_run_id: run.id,
                   github_repository_id: github_repository_id,
                   source_full_name: repository_mirror.github_full_name,
                   source_name: "inventory-repo",
                   source_observed_at: now,
                   selected: true,
                   destination_owner_id: organization_mirror.organization_id,
                   destination_slug: "inventory-repo",
                   destination_visibility: :private,
                   state: :queued,
                   source_metadata: %{
                     "default_branch" => "main",
                     "visibility" => "private",
                     "has_issues" => true,
                     "allow_merge_commit" => true,
                     "fork" => false,
                     "archived" => false
                   }
                 })

        {:ok, :awaiting_resolution}
      end
    end

    options = [context: context, discovery: discovery, lease_seconds: 30]

    assert {:ok, [{operation_id, {:ok, %MirrorOperation{state: :pending}}}]} =
             InventoryImportWorker.run_once("inventory-first", [now: now] ++ options)

    assert operation_id == operation.id
    assert Repo.aggregate(ImportRun, :count) == 1
    assert Repo.aggregate(RepositoryItem, :count) == 0

    second_now = DateTime.add(now, 6, :second)

    assert {:ok, [{^operation_id, {:ok, %MirrorOperation{state: :pending}}}]} =
             InventoryImportWorker.run_once("inventory-second", [now: second_now] ++ options)

    assert Repo.aggregate(ImportRun, :count) == 2
    assert Repo.aggregate(RepositoryItem, :count) == 1

    [predecessor, successor] = Repo.all(from run in ImportRun, order_by: [asc: run.id])
    assert predecessor.state == :failed
    assert successor.predecessor_run_id == predecessor.id
    assert successor.mirror_operation_id == operation.id

    materialize_now = DateTime.add(second_now, 6, :second)

    assert {:ok, [{^operation_id, :pending}]} =
             InventoryImportWorker.run_once(
               "inventory-materialize",
               [now: materialize_now] ++ options
             )

    parent = Repo.get!(MirrorOperation, operation.id)
    item = Repo.get_by!(RepositoryItem, import_run_id: successor.id)

    assert parent.cursor["import_run_id"] == successor.id
    assert parent.cursor["repository_item_id"] == item.id
    assert Repo.aggregate(ImportRun, :count) == 2
    assert Repo.aggregate(RepositoryItem, :count) == 1

    repository_id = repository_fixture(organization_mirror.organization_id)

    assert {:ok, bound} =
             ForgeMirrors.update_repository_mirror(actor, repository_mirror, %{
               repository_id: repository_id,
               bootstrap_repository_item_id: item.id
             })

    assert bound.state == :discovered

    Repo.update_all(from(candidate in RepositoryItem, where: candidate.id == ^item.id),
      set: [state: :published]
    )

    assert {:ok, child} =
             ForgeMirrors.enqueue_operation(%{
               organization_mirror_id: organization_mirror.id,
               repository_mirror_id: repository_mirror.id,
               kind: "reconcile.repository.bootstrap",
               dedupe_key: "bootstrap-handoff:item:#{item.id}",
               cursor: %{
                 "bootstrap_repository_item_id" => item.id,
                 "baseline" => "seeded"
               },
               next_attempt_at: materialize_now
             })

    complete_now = DateTime.add(materialize_now, 6, :second)

    assert {:ok, [{^operation_id, {:ok, %MirrorOperation{state: :completed}}}]} =
             InventoryImportWorker.run_once("inventory-complete", [now: complete_now] ++ options)

    assert Repo.get!(MirrorOperation, operation.id).state == :completed
    assert Repo.get!(OrganizationMirror, organization_mirror.id).state == :active
    assert is_nil(Repo.get!(OrganizationMirror, organization_mirror.id).bootstrap_import_run_id)

    assert {:ok, [%MirrorOperation{id: child_id}]} =
             ForgeMirrors.claim_operations("bootstrap-child", complete_now, 30, 1, [
               "reconcile.repository.bootstrap"
             ])

    assert child_id == child.id
  end

  test "a lifecycle fence creates no import run" do
    now = DateTime.utc_now(:second)
    organization_mirror = active_organization_mirror_fixture()
    repository_mirror = repository_mirror_fixture(organization_mirror)

    assert {:ok, operation} =
             ForgeMirrors.enqueue_operation(%{
               organization_mirror_id: organization_mirror.id,
               repository_mirror_id: repository_mirror.id,
               kind: "bootstrap.repository_import",
               dedupe_key: Ecto.UUID.generate(),
               cursor: %{"source" => "inventory"},
               next_attempt_at: now
             })

    assert {:ok, [{operation_id, {:error, :paused}}]} =
             InventoryImportWorker.run_once("inventory-paused",
               now: now,
               context: fn _operation -> {:error, :paused} end
             )

    assert operation_id == operation.id
    assert Repo.aggregate(ImportRun, :count) == 0
  end
end
