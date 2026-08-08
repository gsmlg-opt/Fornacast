defmodule Fornacast.OperationLeaseTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeRepos.{GitWriteOperation, Repository}
  alias Fornacast.{OperationLease, Repo}

  @moduletag :persistence
  @oid String.duplicate("a", 40)

  setup context do
    if postgres?() and context[:independent_connections] != true do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      unless postgres?() do
        Repo.delete_all(GitWriteOperation)

        on_exit(fn ->
          Repo.delete_all(GitWriteOperation)

          Ecto.Adapters.SQL.query!(
            Repo,
            "delete from repositories where slug like 'lease-repository-%'",
            []
          )

          Ecto.Adapters.SQL.query!(
            Repo,
            "delete from users where username like 'lease-user-%'",
            []
          )
        end)
      end
    end

    if context[:independent_connections] do
      :ok
    else
      operation = insert_operation!()
      %{operation: operation, now: ~U[2026-07-21 12:00:00Z]}
    end
  end

  @tag independent_connections: true
  test "two independent claimers cannot both acquire the operation" do
    operation =
      if postgres?() do
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &insert_operation!/0)
      else
        Repo.delete_all(GitWriteOperation)
        insert_operation!()
      end

    now = ~U[2026-07-21 12:00:00Z]

    claims =
      if postgres?() do
        ["owner-a", "owner-b"]
        |> Task.async_stream(
          fn owner ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              OperationLease.claim(GitWriteOperation, operation.id, owner, now, 30)
            end)
          end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)
      else
        [
          OperationLease.claim(GitWriteOperation, operation.id, "owner-a", now, 30),
          OperationLease.claim(GitWriteOperation, operation.id, "owner-b", now, 30)
        ]
      end

    assert Enum.count(claims, &match?({:ok, %GitWriteOperation{}}, &1)) == 1
    assert Enum.count(claims, &(&1 == :busy)) == 1

    if postgres?() do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> cleanup_operation_fixture(operation) end)
    else
      Repo.delete_all(GitWriteOperation)
    end
  end

  test "claim grants one owner and rejects a live competing owner", %{
    operation: operation,
    now: now
  } do
    assert {:ok, claimed} =
             OperationLease.claim(GitWriteOperation, operation.id, "owner-a", now, 30)

    assert claimed.lease_owner == "owner-a"
    assert claimed.lease_expires_at == DateTime.add(now, 30, :second)
    assert claimed.lock_version == operation.lock_version + 1

    assert :busy = OperationLease.claim(GitWriteOperation, operation.id, "owner-b", now, 30)
  end

  test "expired lease can be reclaimed and stale owner cannot update or release", %{
    operation: operation,
    now: now
  } do
    assert {:ok, stale} = OperationLease.claim(GitWriteOperation, operation.id, "owner-a", now, 5)

    assert {:ok, current} =
             OperationLease.claim(
               GitWriteOperation,
               operation.id,
               "owner-b",
               DateTime.add(now, 6, :second),
               30
             )

    assert {:error, :lost_lease} =
             OperationLease.update_owned(GitWriteOperation, stale, state: :object_written)

    assert {:error, :lost_lease} = OperationLease.release(GitWriteOperation, stale)

    assert {:ok, updated} =
             OperationLease.update_owned(GitWriteOperation, current, state: :object_written)

    assert updated.state == :object_written
    assert updated.lease_owner == nil
    assert updated.lock_version == current.lock_version + 1
  end

  test "immutable Git write evidence cannot be updated and leaves the lease unchanged", %{
    operation: operation,
    now: now
  } do
    assert {:ok, claimed} =
             OperationLease.claim(GitWriteOperation, operation.id, "owner-a", now, 30)

    immutable_updates = [
      id: operation.id + 1,
      repository_id: operation.repository_id + 1,
      actor_user_id: operation.repository_id,
      request_id: "changed-request",
      kind: :content_delete,
      target_ref: "refs/heads/changed",
      expected_oid: String.duplicate("c", 40),
      proposed_oid: String.duplicate("d", 40),
      lease_owner: "owner-b",
      lease_expires_at: DateTime.add(now, 60, :second),
      lock_version: 0,
      inserted_at: DateTime.add(now, -60, :second),
      updated_at: DateTime.add(now, -60, :second)
    ]

    for update <- immutable_updates do
      assert {:error, :invalid_update} =
               OperationLease.update_owned(GitWriteOperation, claimed, [update])

      assert Repo.get!(GitWriteOperation, claimed.id) == claimed
    end

    assert {:error, :invalid_update} =
             OperationLease.update_owned(GitWriteOperation, claimed,
               failure_reason: "native panic at /private/repository token=secret"
             )

    assert Repo.get!(GitWriteOperation, claimed.id) == claimed

    assert :ok = OperationLease.release(GitWriteOperation, claimed)
    released = Repo.get!(GitWriteOperation, operation.id)
    assert released.lease_owner == nil
    assert released.lease_expires_at == nil
    assert released.lock_version == claimed.lock_version + 1
    assert {:error, :lost_lease} = OperationLease.release(GitWriteOperation, claimed)
  end

  test "valid Git write transition values are canonicalized", %{operation: operation, now: now} do
    content_operation =
      operation
      |> Ecto.Changeset.change(kind: :content_update)
      |> Repo.update!()

    assert {:ok, claimed} =
             OperationLease.claim(GitWriteOperation, content_operation.id, "owner-a", now, 30)

    blob_oid = String.duplicate("C", 40)

    assert {:ok, updated} =
             OperationLease.update_owned(GitWriteOperation, claimed,
               state: :object_written,
               result_blob_oid: blob_oid
             )

    assert updated.state == :object_written
    assert updated.result_blob_oid == String.downcase(blob_oid)

    assert {:ok, reclaimed} =
             OperationLease.claim(GitWriteOperation, updated.id, "owner-b", now, 30)

    assert {:error, :invalid_update} =
             OperationLease.update_owned(GitWriteOperation, reclaimed,
               result_blob_oid: String.duplicate("d", 40)
             )

    assert Repo.get!(GitWriteOperation, reclaimed.id) == reclaimed
    assert :ok = OperationLease.release(GitWriteOperation, reclaimed)
  end

  test "arguments are validated", %{operation: operation, now: now} do
    assert {:error, :invalid_argument} =
             OperationLease.claim(GitWriteOperation, operation.id, "", now, 30)

    assert {:error, :invalid_argument} =
             OperationLease.claim(GitWriteOperation, operation.id, "owner", now, 0)

    assert {:error, :not_found} =
             OperationLease.claim(GitWriteOperation, operation.id + 999_999, "owner", now, 30)
  end

  defp insert_operation! do
    %GitWriteOperation{}
    |> GitWriteOperation.changeset(%{
      repository_id: repository_id!(),
      request_id: "lease-#{System.unique_integer([:positive])}",
      kind: :ref_update,
      state: :prepared,
      target_ref: "refs/heads/main",
      expected_oid: @oid,
      proposed_oid: String.duplicate("b", 40),
      lock_version: 0
    })
    |> Repo.insert!()
  end

  defp repository_id! do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "lease-user-#{suffix}",
        email: "lease-user-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{
        slug: "lease-repository-#{suffix}",
        name: "lease-repository-#{suffix}",
        visibility: :private
      })

    repository.id
  end

  defp cleanup_operation_fixture(operation) do
    repository = Repo.get!(Repository, operation.repository_id)
    Repo.delete!(repository)
    Repo.delete_all(from user in User, where: user.id == ^repository.owner_user_id)
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
