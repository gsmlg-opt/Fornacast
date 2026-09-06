defmodule ForgeGitHub.GitRefWorkerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{GitRefWorker, InstallationToken}
  alias ForgeMirrors.MirrorOperation
  alias GitCore.RepositoryWriteLimiter
  alias GitCore.Remote.{Error, ObservedRef, RefUpdate, SyncRequest}

  @base String.duplicate("1", 40)
  @head String.duplicate("2", 40)
  @remote String.duplicate("3", 40)
  @now ~U[2026-09-06 06:00:00Z]

  test "applies an inbound fast-forward with an exact local CAS after marking the effect" do
    parent = self()
    operation = operation()

    options =
      options(operation,
        remote_oid: @head,
        ancestor?: fn "/repos/example.git", @base, @head -> {:ok, true} end,
        lfs_gate: fn ^operation, sync, :inbound, @head, "installation-secret", %SyncRequest{} ->
          assert sync.ref_name == "refs/heads/main"
          send(parent, :lfs_ready)
          :ok
        end,
        mark_effect: mark_effect(parent, operation),
        apply_local: fn "/repos/example.git", "refs/heads/main", @base, @head ->
          send(parent, :local_cas)
          {:ok, @head}
        end,
        confirm: fn marked, "refs/heads/main", @head, @head, @now ->
          assert marked.state == :effect_pending
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = GitRefWorker.process_operation(operation, @now, options)

    assert collect_events(4) == [
             :lfs_ready,
             {:effect_marked, %{"action" => "apply_local"}},
             :local_cas,
             :confirmed
           ]
  end

  test "an inbound mirror CAS waits on the repository ID write fence" do
    parent = self()
    operation = operation()
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert {:ok, holder} = RepositoryWriteLimiter.acquire(10, deadline)

    try do
      writer =
        Task.async(fn ->
          GitRefWorker.process_operation(
            operation,
            @now,
            options(operation,
              remote_oid: @head,
              ancestor?: fn "/repos/example.git", @base, @head -> {:ok, true} end,
              mark_effect: mark_effect(parent, operation),
              apply_local: fn "/repos/example.git", "refs/heads/main", @base, @head ->
                send(parent, :local_cas)
                {:ok, @head}
              end,
              confirm: fn _marked, "refs/heads/main", @head, @head, @now ->
                {:ok, :confirmed}
              end
            )
          )
        end)

      assert_receive {:effect_marked, %{"action" => "apply_local"}}
      assert :ok = wait_for_repository_waiter(10)
      refute_received :local_cas

      assert :ok = RepositoryWriteLimiter.release(holder)
      assert {:ok, :confirmed} = Task.await(writer)
      assert_received :local_cas
    after
      RepositoryWriteLimiter.release(holder)
    end
  end

  test "pushes an outbound fast-forward with the exact observed remote OID" do
    parent = self()
    operation = operation()

    options =
      options(operation,
        local_oid: @head,
        remote_oid: @base,
        ancestor?: fn "/repos/example.git", @base, @head -> {:ok, true} end,
        lfs_gate: fn ^operation, _sync, :outbound, @head, "installation-secret", %SyncRequest{} ->
          send(parent, :lfs_ready)
          :ok
        end,
        mark_effect: mark_effect(parent, operation),
        push_remote: fn
          %SyncRequest{owner: "acme", repository: "project"},
          "installation-secret",
          %RefUpdate{ref: "refs/heads/main", expected_oid: @base, proposed_oid: @head} ->
            send(parent, :remote_push)
            :ok
        end,
        confirm: fn marked, "refs/heads/main", @head, @head, @now ->
          assert marked.state == :effect_pending
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = GitRefWorker.process_operation(operation, @now, options)

    assert collect_events(4) == [
             :lfs_ready,
             {:effect_marked, %{"action" => "apply_remote"}},
             :remote_push,
             :confirmed
           ]
  end

  test "equal Git refs still require LFS convergence before confirmation" do
    parent = self()
    operation = operation()

    options =
      options(operation,
        local_oid: @head,
        remote_oid: @head,
        lfs_gate: fn ^operation, _sync, :converge, @head, _token, _request ->
          send(parent, :lfs_ready)
          :ok
        end,
        confirm: fn ^operation, "refs/heads/main", @head, @head, @now ->
          send(parent, :confirmed)
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = GitRefWorker.process_operation(operation, @now, options)
    assert collect_events(2) == [:lfs_ready, :confirmed]
  end

  test "a remote deletion publishes the future LFS reachability before deleting locally" do
    parent = self()
    operation = operation()

    options =
      options(operation,
        remote_oid: nil,
        lfs_gate: fn ^operation, _sync, :inbound, nil, _token, _request ->
          send(parent, :lfs_ready)
          :ok
        end,
        mark_effect: mark_effect(parent, operation),
        delete_local: fn "/repos/example.git", "refs/heads/main", @base ->
          send(parent, :local_delete)
          {:ok, @base}
        end,
        confirm: fn marked, "refs/heads/main", nil, nil, @now ->
          assert marked.state == :effect_pending
          send(parent, :confirmed)
          {:ok, :deleted}
        end
      )

    assert {:ok, :deleted} = GitRefWorker.process_operation(operation, @now, options)

    assert collect_events(4) == [
             :lfs_ready,
             {:effect_marked, %{"action" => "delete_local"}},
             :local_delete,
             :confirmed
           ]
  end

  test "a local deletion publishes the future LFS reachability before deleting remotely" do
    parent = self()
    operation = operation()

    options =
      options(operation,
        local_oid: nil,
        remote_oid: @base,
        lfs_gate: fn ^operation, _sync, :outbound, nil, _token, _request ->
          send(parent, :lfs_ready)
          :ok
        end,
        mark_effect: mark_effect(parent, operation),
        delete_remote: fn _request, "installation-secret", "refs/heads/main", @base ->
          send(parent, :remote_delete)
          :ok
        end,
        confirm: fn marked, "refs/heads/main", nil, nil, @now ->
          assert marked.state == :effect_pending
          send(parent, :confirmed)
          {:ok, :deleted}
        end
      )

    assert {:ok, :deleted} = GitRefWorker.process_operation(operation, @now, options)

    assert collect_events(4) == [
             :lfs_ready,
             {:effect_marked, %{"action" => "delete_remote"}},
             :remote_delete,
             :confirmed
           ]
  end

  test "a missing LFS object degrades without marking or writing the Git ref" do
    parent = self()
    operation = operation()

    options =
      options(operation,
        remote_oid: @head,
        ancestor?: fn "/repos/example.git", @base, @head -> {:ok, true} end,
        lfs_gate: fn ^operation, _sync, :inbound, @head, _token, _request ->
          {:error, :lfs_missing}
        end,
        degrade_lfs: fn ^operation,
                        "refs/heads/main",
                        @base,
                        @head,
                        @now,
                        "lfs_missing",
                        detail ->
          assert detail =~ "missing"
          send(parent, :degraded)
          {:ok, :degraded}
        end
      )

    assert {:ok, :degraded} = GitRefWorker.process_operation(operation, @now, options)
    assert_received :degraded
    refute_received {:effect_marked, _marker}
    refute_received :local_cas
    refute_received :confirmed
  end

  test "an incomplete pointer scan yields the operation with its durable scan identity" do
    operation = operation()
    checkpoint = %{"lfs_scan_key" => "operation-1-head", "phase" => "scan"}

    options =
      options(operation,
        remote_oid: @head,
        ancestor?: fn "/repos/example.git", @base, @head -> {:ok, true} end,
        lfs_gate: fn ^operation, _sync, :inbound, @head, _token, _request ->
          {:incomplete, checkpoint}
        end,
        checkpoint_lfs: fn ^operation, "refs/heads/main", ^checkpoint, @now ->
          {:ok, :yielded}
        end
      )

    assert {:ok, :yielded} = GitRefWorker.process_operation(operation, @now, options)
  end

  test "records divergence without attempting any mutation" do
    parent = self()
    operation = operation()

    options =
      options(operation,
        local_oid: @head,
        remote_oid: @remote,
        ancestor?: fn _path, _left, _right -> {:ok, false} end,
        mark_effect: fn _operation, _now, _marker -> flunk("conflicts must not mutate") end,
        conflict: fn ^operation,
                     "refs/heads/main",
                     :git_divergence,
                     @base,
                     @head,
                     @remote,
                     @now ->
          send(parent, :conflicted)
          {:ok, :conflicted}
        end
      )

    assert {:ok, :conflicted} = GitRefWorker.process_operation(operation, @now, options)
    assert_received :conflicted
  end

  test "effect-pending recovery re-observes an already-applied push and only confirms" do
    operation = %{
      operation()
      | state: :effect_pending,
        external_effect_marker: %{
          "action" => "apply_remote",
          "expected_oid" => @base,
          "proposed_oid" => @head,
          "ref" => "refs/heads/main"
        }
    }

    options =
      options(operation,
        local_oid: @head,
        remote_oid: @head,
        mark_effect: fn _operation, _now, _marker -> flunk("must reuse durable marker") end,
        push_remote: fn _request, _token, _update -> flunk("effect already landed") end,
        confirm: fn ^operation, "refs/heads/main", @head, @head, @now ->
          {:ok, :recovered}
        end
      )

    assert {:ok, :recovered} = GitRefWorker.process_operation(operation, @now, options)
  end

  test "effect-pending recovery replaces a landed remote marker before an opposite local effect" do
    parent = self()

    marker = %{
      "action" => "apply_remote",
      "expected_oid" => @base,
      "proposed_oid" => @head,
      "ref" => "refs/heads/main"
    }

    operation = %{operation() | state: :effect_pending, external_effect_marker: marker}

    options =
      options(operation,
        local_oid: @base,
        remote_oid: @head,
        ancestor?: fn "/repos/example.git", @base, @head -> {:ok, true} end,
        lfs_gate: fn ^operation, _sync, :inbound, @head, _token, _request ->
          send(parent, :lfs_ready)
          :ok
        end,
        replace_effect: fn ^operation, @now, ^marker, replacement ->
          assert replacement == %{
                   "action" => "apply_local",
                   "expected_oid" => @base,
                   "proposed_oid" => @head,
                   "ref" => "refs/heads/main"
                 }

          send(parent, :effect_replaced)

          {:ok,
           %{
             operation
             | external_effect_marker: replacement,
               lock_version: operation.lock_version + 1
           }}
        end,
        apply_local: fn "/repos/example.git", "refs/heads/main", @base, @head ->
          send(parent, :local_cas)
          {:ok, @head}
        end,
        confirm: fn marked, "refs/heads/main", @head, @head, @now ->
          assert marked.external_effect_marker["action"] == "apply_local"
          send(parent, :confirmed)
          {:ok, :recovered}
        end
      )

    assert {:ok, :recovered} = GitRefWorker.process_operation(operation, @now, options)
    assert collect_events(4) == [:lfs_ready, :effect_replaced, :local_cas, :confirmed]
  end

  test "effect-pending recovery fails closed when the recorded endpoint matches neither condition" do
    marker = %{
      "action" => "apply_remote",
      "expected_oid" => @base,
      "proposed_oid" => @head,
      "ref" => "refs/heads/main"
    }

    operation = %{operation() | state: :effect_pending, external_effect_marker: marker}

    options =
      options(operation,
        local_oid: @head,
        remote_oid: @remote,
        ancestor?: fn "/repos/example.git", @head, @remote -> {:ok, true} end,
        lfs_gate: fn _operation, _sync, _direction, _target, _token, _request ->
          flunk("ambiguous recovery must stop before LFS publication")
        end,
        replace_effect: fn _operation, _now, _expected, _replacement ->
          flunk("ambiguous recovery must not replace its durable marker")
        end,
        apply_local: fn _path, _ref, _expected, _proposed ->
          flunk("ambiguous recovery must not mutate a ref")
        end,
        conflict: fn ^operation,
                     "refs/heads/main",
                     :git_divergence,
                     @base,
                     @head,
                     @remote,
                     @now ->
          {:ok, :ambiguous_effect}
        end
      )

    assert {:ok, :ambiguous_effect} = GitRefWorker.process_operation(operation, @now, options)
  end

  test "effect-pending recovery fails closed for an invalid deletion marker" do
    operation = %{
      operation()
      | state: :effect_pending,
        external_effect_marker: %{
          "action" => "delete_local",
          "expected_oid" => nil,
          "ref" => "refs/heads/main"
        }
    }

    options =
      options(operation,
        local_oid: nil,
        remote_oid: nil,
        lfs_gate: fn _operation, _sync, _direction, _target, _token, _request ->
          flunk("invalid recovery marker must stop before LFS publication")
        end,
        confirm: fn _operation, _ref, _local, _remote, _now ->
          flunk("invalid recovery marker must not confirm")
        end,
        conflict: fn ^operation, "refs/heads/main", :git_divergence, @base, nil, nil, @now ->
          {:ok, :invalid_marker}
        end
      )

    assert {:ok, :invalid_marker} = GitRefWorker.process_operation(operation, @now, options)
  end

  test "reconciled effect-pending LFS rate limits retain the provider retry time" do
    retry_at = DateTime.add(@now, 90)

    operation = %{
      operation()
      | state: :effect_pending,
        external_effect_marker: %{
          "action" => "apply_remote",
          "expected_oid" => @base,
          "proposed_oid" => @head,
          "ref" => "refs/heads/main"
        }
    }

    options =
      options(operation,
        local_oid: @head,
        remote_oid: @head,
        lfs_gate: fn ^operation, _sync, :converge, @head, _token, _request ->
          {:error,
           %ForgeGitHub.Error{
             kind: :primary_rate_limit,
             detail: "rate limited",
             retry_at: retry_at
           }}
        end,
        retry: fn ^operation,
                  @now,
                  ^retry_at,
                  "primary_rate_limit",
                  external_effect_reconciled: true ->
          {:ok, :rate_limited}
        end
      )

    assert {:ok, :rate_limited} = GitRefWorker.process_operation(operation, @now, options)
  end

  test "a remote lease race becomes one conflict using the original observations" do
    operation = operation()
    marked = %{operation | state: :effect_pending, lock_version: 2}

    options =
      options(operation,
        local_oid: @head,
        remote_oid: @base,
        ancestor?: fn _path, @base, @head -> {:ok, true} end,
        mark_effect: fn ^operation, @now, _marker -> {:ok, marked} end,
        push_remote: fn _request, _token, _update ->
          {:error, %Error{kind: :stale_remote, detail: "stale_remote"}}
        end,
        conflict: fn ^marked, "refs/heads/main", :git_divergence, @base, @head, @base, @now ->
          {:ok, :race_conflict}
        end
      )

    assert {:ok, :race_conflict} = GitRefWorker.process_operation(operation, @now, options)
  end

  test "repository reconciliation observes canonical local remote and baseline ref names before fanout" do
    parent = self()
    operation = %{operation() | kind: "reconcile.repository.bootstrap", cursor: %{}}

    options = [
      repository_context: fn ^operation ->
        {:ok,
         %{
           baseline_ref_names: ["refs/heads/old"],
           github_installation_id: 44,
           remote_owner: "acme",
           remote_repository: "project",
           repository_generation: 1,
           repository_id: 10,
           repository_path: "/repos/example.git",
           tracking_namespace: "repository-3",
           lfs_enabled: true
         }}
      end,
      token_fetch: token_fetch(),
      fetch_refs: fn _request, "installation-secret", "repository-3" ->
        {:ok, [%ObservedRef{ref: "refs/tags/v1.0.0", oid: @head}]}
      end,
      list_refs: fn "/repos/example.git" ->
        {:ok, [%{name: "refs/heads/main", target: @base}, %{name: "refs/fornacast/hidden"}]}
      end,
      fanout: fn ^operation, ref_names, @now ->
        send(parent, {:fanout, ref_names})
        {:ok, :fanned_out}
      end,
      retry: fn _operation, _now, _retry_at, _class, _options -> flunk("unexpected retry") end,
      fail: fn _operation, _now, _class, _detail -> flunk("unexpected failure") end
    ]

    assert {:ok, :fanned_out} = GitRefWorker.process_operation(operation, @now, options)

    assert_received {:fanout, ["refs/heads/main", "refs/heads/old", "refs/tags/v1.0.0"]}
  end

  test "a ref baseline race rechecks finalizer supersession before retrying" do
    operation =
      %{
        operation()
        | kind: "finalize.repository.git",
          cursor: %{"reconciliation_operation_id" => 9}
      }

    Process.put(:finalizer_preflight_count, 0)
    on_exit(fn -> Process.delete(:finalizer_preflight_count) end)

    preflight = fn ^operation, @now ->
      count = Process.get(:finalizer_preflight_count, 0) + 1
      Process.put(:finalizer_preflight_count, count)

      if count == 1,
        do: {:ok, :continue},
        else: {:ok, %{operation: :completed, replacement: :queued}}
    end

    options = [
      repository_context: fn ^operation -> {:ok, %{lfs_enabled: true}} end,
      finalize_preflight: preflight,
      reconcile_lfs: fn ^operation, %{lfs_enabled: true}, _finalize ->
        {:error, :bootstrap_refs_unconfirmed}
      end,
      finalize: fn _operation, _now -> flunk("stale baselines must not finalize") end,
      retry: fn _operation, _now, _retry_at, _class, _options ->
        flunk("known later work must supersede instead of retry")
      end
    ]

    assert {:ok, %{operation: :completed, replacement: :queued}} =
             GitRefWorker.process_operation(operation, @now, options)

    assert Process.get(:finalizer_preflight_count) == 2
  end

  test "an operation for a ref with an unresolved conflict terminates without observation" do
    operation = operation()

    options =
      options(operation,
        context: fn ^operation -> {:error, :git_ref_conflicted} end,
        token_fetch: fn _installation_id, _scope -> flunk("must not request a token") end,
        fail: fn ^operation, @now, "git_divergence", detail ->
          assert detail =~ "unresolved conflict"
          {:ok, :already_conflicted}
        end
      )

    assert {:ok, :already_conflicted} =
             GitRefWorker.process_operation(operation, @now, options)
  end

  defp operation do
    %MirrorOperation{
      id: 1,
      organization_mirror_id: 2,
      repository_mirror_id: 3,
      kind: "sync.git_ref",
      state: :processing,
      cursor: %{"ref_name" => "refs/heads/main"},
      lease_owner: "worker",
      lease_expires_at: DateTime.add(@now, 60),
      lock_version: 1
    }
  end

  defp options(operation, overrides) do
    local_oid = Keyword.get(overrides, :local_oid, @base)
    remote_oid = Keyword.get(overrides, :remote_oid, @head)

    defaults = [
      context: fn ^operation ->
        {:ok,
         %{
           baseline: @base,
           effect_marker: operation.external_effect_marker,
           github_installation_id: 44,
           ref_kind: :branch,
           ref_name: "refs/heads/main",
           remote_owner: "acme",
           remote_repository: "project",
           repository_id: 10,
           repository_path: "/repos/example.git",
           tracking_namespace: "repository-3"
         }}
      end,
      token_fetch: token_fetch(),
      fetch_refs: fn
        %SyncRequest{}, "installation-secret", "repository-3" ->
          observations =
            if remote_oid,
              do: [%ObservedRef{ref: "refs/heads/main", oid: remote_oid}],
              else: []

          {:ok, observations}
      end,
      exact_ref: fn "/repos/example.git", "refs/heads/main" -> {:ok, local_oid} end,
      ancestor?: fn _path, _left, _right -> {:ok, false} end,
      lfs_gate: fn _operation, _sync, _direction, _target_oid, _token, _request -> :ok end,
      checkpoint_lfs: fn _operation, _ref, _checkpoint, _now -> flunk("unexpected checkpoint") end,
      degrade_lfs: fn _operation, _ref, _local, _remote, _now, _class, _detail ->
        flunk("unexpected LFS degradation")
      end,
      mark_effect: fn _operation, _now, _marker -> flunk("unexpected effect") end,
      apply_local: fn _path, _ref, _expected, _proposed -> flunk("unexpected local write") end,
      delete_local: fn _path, _ref, _expected -> flunk("unexpected local delete") end,
      push_remote: fn _request, _token, _update -> flunk("unexpected remote write") end,
      delete_remote: fn _request, _token, _ref, _expected -> flunk("unexpected remote delete") end,
      confirm: fn _operation, _ref, _local, _remote, _now -> flunk("unexpected confirmation") end,
      conflict: fn _operation, _ref, _kind, _base, _local, _remote, _now ->
        flunk("unexpected conflict")
      end,
      retry: fn _operation, _now, _retry_at, _class, _options -> flunk("unexpected retry") end,
      fail: fn _operation, _now, _class, _detail -> flunk("unexpected failure") end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp mark_effect(parent, operation) do
    fn ^operation, @now, marker ->
      send(parent, {:effect_marked, Map.take(marker, ["action"])})
      {:ok, %{operation | state: :effect_pending, lock_version: operation.lock_version + 1}}
    end
  end

  defp token_fetch do
    fn 44, %{permissions: %{"contents" => "write", "metadata" => "read"}} ->
      %InstallationToken{
        token: "installation-secret",
        expires_at: DateTime.add(@now, 3_600),
        permissions: %{"contents" => "write", "metadata" => "read"}
      }
    end
  end

  defp collect_events(count) do
    Enum.map(1..count, fn _index ->
      receive do
        event -> event
      after
        100 -> flunk("expected ordered worker event")
      end
    end)
  end

  defp wait_for_repository_waiter(repository_id, attempts \\ 100)

  defp wait_for_repository_waiter(_repository_id, 0),
    do: flunk("mirror writer never waited on the repository ID fence")

  defp wait_for_repository_waiter(repository_id, attempts) do
    waiting? =
      RepositoryWriteLimiter
      |> :sys.get_state()
      |> Map.fetch!(:waiters)
      |> Map.values()
      |> Enum.any?(&(&1.repository_key == repository_id))

    if waiting? do
      :ok
    else
      Process.sleep(5)
      wait_for_repository_waiter(repository_id, attempts - 1)
    end
  end
end
