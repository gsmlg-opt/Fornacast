defmodule ForgeGitHub.GitRefWorkerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{GitRefWorker, InstallationToken}
  alias ForgeMirrors.MirrorOperation
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
    assert_received {:effect_marked, %{"action" => "apply_local"}}
    assert_received :local_cas
    assert_received :confirmed
  end

  test "pushes an outbound fast-forward with the exact observed remote OID" do
    parent = self()
    operation = operation()

    options =
      options(operation,
        local_oid: @head,
        remote_oid: @base,
        ancestor?: fn "/repos/example.git", @base, @head -> {:ok, true} end,
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
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = GitRefWorker.process_operation(operation, @now, options)
    assert_received {:effect_marked, %{"action" => "apply_remote"}}
    assert_received :remote_push
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
        external_effect_marker: %{"ref" => "refs/heads/main"}
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
           repository_path: "/repos/example.git",
           tracking_namespace: "repository-3"
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
end
