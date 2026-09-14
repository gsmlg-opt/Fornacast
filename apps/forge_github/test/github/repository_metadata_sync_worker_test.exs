defmodule ForgeGitHub.RepositoryMetadataSyncWorkerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{InstallationToken, RepositoryMetadataSyncWorker}
  alias ForgeMirrors.MirrorOperation

  @now ~U[2026-09-14 05:00:00Z]

  test "uses an installation token to reconcile one leased canonical repository observation" do
    operation = %MirrorOperation{
      id: 1,
      kind: "reconcile.repository.metadata",
      state: :processing,
      cursor: %{"trigger" => "reconcile", "sweep_key" => "inventory:one"}
    }

    sync = %{
      github_installation_id: 7,
      remote_owner: "acme",
      remote_repository: "forge",
      github_repository_id: 9,
      github_node_id: "R_9"
    }

    remote = %{
      id: 9,
      node_id: "R_9",
      name: "forge",
      description: nil,
      visibility: :private,
      default_branch: "main",
      archived: false,
      updated_at: @now
    }

    assert {:ok, :recorded} =
             RepositoryMetadataSyncWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, sync} end,
               token_fetch: fn 7, %{permissions: %{"metadata" => "read"}} ->
                 %InstallationToken{
                   token: "installation-token",
                   expires_at: ~U[2026-09-14 06:00:00Z],
                   permissions: %{"metadata" => "read"}
                 }
               end,
               repository_fetch: fn "installation-token", "acme", "forge", _opts ->
                 {:ok, remote}
               end,
               record: fn ^operation,
                          %{
                            id: 9,
                            node_id: "R_9",
                            name: "forge",
                            description: nil,
                            visibility: :private,
                            default_branch: "main",
                            archived: false,
                            updated_at: @now
                          },
                          @now ->
                 {:ok, :recorded}
               end
             )
  end

  test "executes a marked outbound update and confirms its canonical response" do
    operation = operation()
    marked = %{operation | state: :effect_pending, lock_version: 2}
    sync = sync()

    target = %{
      "name" => "forge-next",
      "description" => "",
      "visibility" => "private",
      "default_branch" => "main",
      "archived" => false
    }

    remote = %{
      id: 9,
      node_id: "R_9",
      name: "forge",
      description: nil,
      visibility: :private,
      default_branch: "main",
      archived: false,
      updated_at: @now
    }

    updated = %{remote | name: "forge-next", description: ""}

    assert {:ok, :confirmed} =
             RepositoryMetadataSyncWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, sync} end,
               token_fetch: fn
                 7, %{permissions: %{"metadata" => "read"}} -> token()
                 7, %{permissions: %{"administration" => "write"}} -> token()
               end,
               repository_fetch: fn "installation-token", "acme", "forge", _ ->
                 {:ok, remote}
               end,
               record: fn ^operation, ^remote, @now ->
                 {:ok, %{action: :update_remote, operation: marked, target: target}}
               end,
               repository_update: fn "installation-token", "acme", "forge", attrs, _ ->
                 assert attrs == target
                 {:ok, updated}
               end,
               confirm_effect: fn ^marked, ^updated, @now -> {:ok, :confirmed} end
             )
  end

  test "defers an ambiguous timeout without clearing the outbound marker" do
    operation = operation()
    marked = %{operation | state: :effect_pending, lock_version: 2}
    remote = remote()

    assert {:ok, :deferred} =
             RepositoryMetadataSyncWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, sync()} end,
               token_fetch: fn
                 7, %{permissions: %{"metadata" => "read"}} -> token()
                 7, %{permissions: %{"administration" => "write"}} -> token()
               end,
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end,
               record: fn ^operation, ^remote, @now ->
                 {:ok, %{action: :update_remote, operation: marked, target: target()}}
               end,
               repository_update: fn _, _, _, _, _ ->
                 {:error, ForgeGitHub.Error.new(:timeout)}
               end,
               defer_effect: fn ^marked, @now, retry_at, "network" ->
                 assert retry_at == DateTime.add(@now, 60)
                 {:ok, :deferred}
               end
             )
  end

  test "recovers a timed-out rename through the marked target path and immutable identity" do
    operation = %{operation() | state: :effect_pending}
    remote = %{remote() | name: "forge-next"}

    sync =
      sync()
      |> Map.put(:effect_marker, %{
        "action" => "update_remote_repository_metadata",
        "target" => target()
      })

    assert {:ok, :confirmed} =
             RepositoryMetadataSyncWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, sync} end,
               token_fetch: fn 7, %{permissions: %{"metadata" => "read"}} -> token() end,
               repository_fetch: fn "installation-token", "acme", repository, _ ->
                 assert repository == "forge-next"
                 {:ok, remote}
               end,
               record: fn ^operation, ^remote, @now -> {:ok, :confirmed} end
             )
  end

  test "falls back to the old path when a marked rename did not commit" do
    operation = %{operation() | state: :effect_pending}
    remote = remote()

    sync =
      sync()
      |> Map.put(:effect_marker, %{
        "action" => "update_remote_repository_metadata",
        "target" => target()
      })

    assert {:ok, :observed_old} =
             RepositoryMetadataSyncWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, sync} end,
               token_fetch: fn 7, %{permissions: %{"metadata" => "read"}} -> token() end,
               repository_fetch: fn
                 "installation-token", "acme", "forge-next", _ ->
                   {:error, ForgeGitHub.Error.new(:not_found)}

                 "installation-token", "acme", "forge", _ ->
                   {:ok, remote}
               end,
               record: fn ^operation, ^remote, @now -> {:ok, :observed_old} end
             )
  end

  test "a revoked installation token terminally records credential_revoked" do
    operation = operation()

    assert {:ok, :failed} =
             RepositoryMetadataSyncWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, sync()} end,
               token_fetch: fn _, _ -> {:error, :revoked} end,
               fail: fn ^operation, @now, "credential_revoked", nil -> {:ok, :failed} end
             )
  end

  test "an invalidated installation token retries as a network failure" do
    operation = operation()

    assert {:ok, :retried} =
             RepositoryMetadataSyncWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, sync()} end,
               token_fetch: fn _, _ -> {:error, :invalidated} end,
               retry: fn ^operation, @now, retry_at, "network", [] ->
                 assert retry_at == DateTime.add(@now, 60)
                 {:ok, :retried}
               end
             )
  end

  test "claims only one operation so a run cannot outlive a later batch lease" do
    assert {:ok, []} =
             RepositoryMetadataSyncWorker.run_once("metadata-worker",
               batch_size: 99,
               now: fn -> @now end,
               claim: fn "metadata-worker", @now, 60, 1, ["reconcile.repository.metadata"] ->
                 {:ok, []}
               end
             )
  end

  test "continues scheduling when its task supervisor is unavailable" do
    {:ok, pid} =
      start_supervised(
        {RepositoryMetadataSyncWorker,
         enabled: false, name: nil, task_starter: fn _task -> {:error, :unavailable} end}
      )

    send(pid, :tick)

    assert %{task_ref: nil} = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  defp operation do
    %MirrorOperation{
      id: 1,
      kind: "reconcile.repository.metadata",
      state: :processing,
      cursor: %{"trigger" => "reconcile", "sweep_key" => "inventory:one"}
    }
  end

  defp sync do
    %{
      github_installation_id: 7,
      remote_owner: "acme",
      remote_repository: "forge",
      github_repository_id: 9,
      github_node_id: "R_9"
    }
  end

  defp token do
    %InstallationToken{
      token: "installation-token",
      expires_at: ~U[2026-09-14 06:00:00Z],
      permissions: %{"metadata" => "read", "administration" => "write"}
    }
  end

  defp remote do
    %{
      id: 9,
      node_id: "R_9",
      name: "forge",
      description: nil,
      visibility: :private,
      default_branch: "main",
      archived: false,
      updated_at: @now
    }
  end

  defp target do
    %{
      "name" => "forge-next",
      "description" => "updated",
      "visibility" => "private",
      "default_branch" => "main",
      "archived" => false
    }
  end
end
