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
end
