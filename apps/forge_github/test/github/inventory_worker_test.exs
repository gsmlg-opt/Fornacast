defmodule ForgeGitHub.InventoryWorkerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, InstallationToken, InventoryWorker, Repository}
  alias ForgeMirrors.MirrorOperation

  test "executes one claimed page with an ephemeral installation token" do
    parent = self()
    now = ~U[2026-09-05 03:00:00Z]
    operation = claimed_operation(now)

    options =
      worker_options(now, operation,
        context: fn ^operation ->
          {:ok,
           %{
             cursor: 2,
             github_account_id: 99,
             github_installation_id: 44,
             installation_selection: :all,
             sweep_marker: "inventory-operation:1"
           }}
        end,
        token_fetch: fn 44, %{permissions: %{"metadata" => "read"}} ->
          %InstallationToken{
            token: "short-lived-secret",
            expires_at: DateTime.add(now, 3_600),
            permissions: %{"metadata" => "read"}
          }
        end,
        page_fetch: fn "short-lived-secret", 2, options ->
          assert options[:gate_key] == {:github_installation, 44}

          {:ok,
           %{
             repositories: [repository(501, "R_inventory", "github/repository")],
             next_cursor: 3
           }}
        end,
        page_record: fn ^operation, repositories, 3, ^now ->
          send(parent, {:recorded, repositories})
          {:ok, %{operation: %{operation | state: :pending}, classifications: %{added: [10]}}}
        end
      )

    assert {:ok, [{1, {:ok, %{operation: %MirrorOperation{state: :pending}}}}]} =
             InventoryWorker.run_once("inventory-test", options)

    assert_received {:recorded,
                     [
                       %{
                         github_repository_id: 501,
                         github_node_id: "R_inventory",
                         github_full_name: "github/repository",
                         github_archived: false
                       }
                     ]}

    refute inspect(options) =~ "short-lived-secret"
  end

  test "rejects a repository outside the installation account before persistence" do
    now = ~U[2026-09-05 03:00:00Z]
    operation = claimed_operation(now)
    parent = self()

    options =
      worker_options(now, operation,
        page_fetch: fn _token, 1, _options ->
          {:ok,
           %{
             repositories: [%{repository(1, "R_wrong", "other/repo") | owner_id: 100}],
             next_cursor: nil
           }}
        end,
        page_record: fn _operation, _repositories, _cursor, _now ->
          flunk("invalid owner must not reach the mirror transaction")
        end,
        operation_fail: fn ^operation, ^now, "provider_validation", detail ->
          send(parent, {:failed, detail})
          {:ok, %{operation | state: :failed}}
        end
      )

    assert {:ok, [{1, {:ok, %MirrorOperation{state: :failed}}}]} =
             InventoryWorker.run_once("inventory-test", options)

    assert_received {:failed, "installation repository owner identity mismatch"}
  end

  test "maps only retryable provider failures to durable retry scheduling" do
    now = ~U[2026-09-05 03:00:00Z]

    for {kind, failure_class} <- [
          {:primary_rate_limit, "primary_rate_limit"},
          {:secondary_rate_limit, "secondary_rate_limit"},
          {:transport, "network"},
          {:timeout, "network"},
          {:upstream_unavailable, "network"}
        ] do
      operation = claimed_operation(now)
      parent = self()

      options =
        worker_options(now, operation,
          page_fetch: fn _token, 1, _options -> {:error, Error.new(kind)} end,
          operation_retry: fn ^operation, ^now, retry_at, ^failure_class ->
            send(parent, {:retried, kind, retry_at})
            {:ok, %{operation | state: :pending}}
          end
        )

      assert {:ok, [{1, {:ok, %MirrorOperation{state: :pending}}}]} =
               InventoryWorker.run_once("inventory-test", options)

      assert_received {:retried, ^kind, %DateTime{}}
    end
  end

  test "a task crash leaves the durable lease untouched for expired-lease recovery" do
    now = ~U[2026-09-05 03:00:00Z]
    operation = claimed_operation(now)

    options =
      worker_options(now, operation,
        page_fetch: fn _token, 1, _options -> raise "injected crash" end,
        operation_retry: fn _operation, _now, _retry_at, _failure_class ->
          flunk("a crashed task must not pretend it owns a retry transition")
        end,
        operation_fail: fn _operation, _now, _failure_class, _detail ->
          flunk("a crashed task must not pretend it owns a failure transition")
        end
      )

    assert {:ok, [{1, {:error, :worker_crash}}]} =
             InventoryWorker.run_once("inventory-test", options)
  end

  defp worker_options(now, operation, overrides) do
    defaults = [
      now: fn -> now end,
      lease_seconds: 30,
      batch_size: 1,
      max_concurrency: 1,
      processor_timeout_ms: 5_000,
      claim: fn "inventory-test", ^now, 30, 1, ["reconcile.organization_inventory"] ->
        {:ok, [operation]}
      end,
      context: fn ^operation ->
        {:ok,
         %{
           cursor: 1,
           github_account_id: 99,
           github_installation_id: 44,
           installation_selection: :all,
           sweep_marker: "inventory-operation:1"
         }}
      end,
      token_fetch: fn 44, %{permissions: %{"metadata" => "read"}} ->
        %InstallationToken{
          token: "ephemeral",
          expires_at: DateTime.add(now, 3_600),
          permissions: %{"metadata" => "read"}
        }
      end,
      page_fetch: fn "ephemeral", 1, _options ->
        {:ok,
         %{repositories: [repository(501, "R_inventory", "github/repository")], next_cursor: nil}}
      end,
      page_record: fn ^operation, _repositories, nil, ^now ->
        {:ok, %{operation: %{operation | state: :completed}, classifications: %{added: [10]}}}
      end,
      operation_retry: fn ^operation, ^now, _retry_at, _failure_class ->
        {:ok, %{operation | state: :pending}}
      end,
      operation_fail: fn ^operation, ^now, _failure_class, _detail ->
        {:ok, %{operation | state: :failed}}
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp claimed_operation(now) do
    %MirrorOperation{
      id: 1,
      organization_mirror_id: 2,
      kind: "reconcile.organization_inventory",
      dedupe_key: "inventory-worker-test",
      state: :processing,
      cursor: %{},
      checkpoint: %{},
      attempt_count: 1,
      next_attempt_at: now,
      lease_owner: "inventory-test",
      lease_expires_at: DateTime.add(now, 30),
      lock_version: 2
    }
  end

  defp repository(id, node_id, full_name) do
    %Repository{
      id: id,
      node_id: node_id,
      owner_id: 99,
      name: full_name |> String.split("/") |> List.last(),
      full_name: full_name,
      owner_login: "github",
      visibility: :private,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: nil,
      fork: false,
      archived: false
    }
  end
end
