defmodule ForgeGitHub.RepositoryCreationWorkerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, InstallationToken, Repository, RepositoryCreationWorker}
  alias ForgeMirrors.MirrorOperation

  @now ~U[2026-09-14 07:00:00Z]

  test "preflights absence, marks the effect, creates, and confirms canonical identity" do
    operation = operation()
    marked = %{operation | state: :effect_pending, lock_version: 2}
    context = context()
    remote = remote()

    assert {:ok, :confirmed} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn 7,
                               %{
                                 permissions: %{
                                   "administration" => "write",
                                   "metadata" => "read"
                                 }
                               } ->
                 token()
               end,
               repository_fetch: fn "installation-token", "acme", "widgets", _ ->
                 {:error, Error.new(:not_found)}
               end,
               mark_effect: fn ^operation, ^context, @now -> {:ok, marked} end,
               authorize_effect: fn ^marked -> {:ok, context} end,
               repository_create: fn "installation-token", "acme", attrs, _ ->
                 assert attrs == %{
                          "name" => "widgets",
                          "description" => "Canonical widgets",
                          "visibility" => "private"
                        }

                 {:ok, remote}
               end,
               confirm: fn ^marked, observation, @now ->
                 assert observation.id == 41
                 assert observation.node_id == "R_41"
                 assert observation.owner_id == 9
                 {:ok, :confirmed}
               end
             )
  end

  test "an effect-pending retry recovers the created repository without another POST" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}
    context = %{context() | effect_marker: marker()}
    remote = remote()

    assert {:ok, :recovered} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, "acme", "widgets", _ -> {:ok, remote} end,
               repository_create: fn _, _, _, _ -> flunk("must not repeat POST") end,
               confirm: fn ^operation, observation, @now ->
                 assert observation.id == 41
                 {:ok, :recovered}
               end
             )
  end

  test "a timeout after POST retains the marked effect for canonical recovery" do
    operation = operation()

    marked = %{
      operation
      | state: :effect_pending,
        lock_version: 2,
        external_effect_marker: marker()
    }

    context = context()

    assert {:ok, :deferred} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ -> {:error, Error.new(:not_found)} end,
               mark_effect: fn ^operation, ^context, @now -> {:ok, marked} end,
               authorize_effect: fn ^marked -> {:ok, context} end,
               repository_create: fn _, _, _, _ -> {:error, Error.new(:timeout)} end,
               defer_effect: fn ^marked, @now, retry_at, "network" ->
                 assert retry_at == DateTime.add(@now, 60)
                 {:ok, :deferred}
               end
             )
  end

  test "a same-name repository found before POST becomes a visible conflict" do
    operation = operation()
    context = context()
    remote = %{remote() | description: "foreign"}

    assert {:ok, :conflicted} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end,
               repository_create: fn _, _, _, _ -> flunk("must not POST over a collision") end,
               conflict: fn ^operation, observation, "repository_namespace_collision", @now ->
                 assert observation.id == 41
                 assert observation.description == "foreign"
                 {:ok, :conflicted}
               end
             )
  end

  test "an invalidated credential defers an effect-pending operation without clearing its marker" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}

    assert {:ok, :deferred} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, %{context() | effect_marker: marker()}} end,
               token_fetch: fn _, _ -> {:error, :invalidated} end,
               retry: fn _, _, _, _ -> flunk("must not clear an ambiguous effect") end,
               defer_effect: fn ^operation, @now, retry_at, "network" ->
                 assert retry_at == DateTime.add(@now, 60)
                 {:ok, :deferred}
               end
             )
  end

  test "a revoked credential halts an ambiguous effect without discarding its marker" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}

    assert {:ok, :halted} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, %{context() | effect_marker: marker()}} end,
               token_fetch: fn _, _ -> {:error, :revoked} end,
               fail: fn _, _, _, _ -> flunk("must retain the ambiguous effect marker") end,
               halt_effect: fn ^operation, @now, "credential_revoked" -> {:ok, :halted} end
             )
  end

  test "pause after claim releases processing work before any token or GitHub request" do
    operation = operation()

    assert {:ok, :paused} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:error, :paused} end,
               token_fetch: fn _, _ -> flunk("must not fetch a token while paused") end,
               pause: fn ^operation, @now -> {:ok, :paused} end
             )
  end

  test "pause after marking retains an ambiguous effect before any token or GitHub request" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}

    assert {:ok, :paused} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:error, :paused} end,
               token_fetch: fn _, _ -> flunk("must not fetch a token while paused") end,
               pause: fn ^operation, @now -> {:ok, :paused} end
             )
  end

  test "revocation after marking halts as credential revoked before token use" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}

    assert {:ok, :halted} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:error, :revoked} end,
               token_fetch: fn _, _ -> flunk("must not fetch a token after revocation") end,
               halt_effect: fn ^operation, @now, "credential_revoked" -> {:ok, :halted} end
             )
  end

  test "revocation after claim fails processing as credential revoked before token use" do
    operation = operation()

    assert {:ok, :failed} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:error, :revoked} end,
               token_fetch: fn _, _ -> flunk("must not fetch a token after revocation") end,
               fail: fn ^operation, @now, "credential_revoked", nil -> {:ok, :failed} end
             )
  end

  test "403 before marking is classified as permission missing" do
    operation = operation()

    assert {:ok, :failed} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context()} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ -> {:error, Error.new(:forbidden)} end,
               fail: fn ^operation, @now, "permission_missing", nil -> {:ok, :failed} end
             )
  end

  test "403 after marking halts while preserving the ambiguous effect" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}

    assert {:ok, :halted} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, %{context() | effect_marker: marker()}} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ -> {:error, Error.new(:forbidden)} end,
               halt_effect: fn ^operation, @now, "permission_missing" -> {:ok, :halted} end
             )
  end

  test "a POST-time name collision performs one canonical GET and records a conflict" do
    operation = operation()
    marked = %{operation | state: :effect_pending, lock_version: 2}
    context = context()
    remote = %{remote() | description: "foreign"}

    assert {:ok, :conflicted} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ ->
                 calls = Process.get(:repository_fetch_calls, 0) + 1
                 Process.put(:repository_fetch_calls, calls)
                 if calls == 1, do: {:error, Error.new(:not_found)}, else: {:ok, remote}
               end,
               mark_effect: fn ^operation, ^context, @now -> {:ok, marked} end,
               authorize_effect: fn ^marked -> {:ok, context} end,
               repository_create: fn _, _, _, _ ->
                 assert Process.get(:repository_create_calls, 0) == 0
                 Process.put(:repository_create_calls, 1)
                 {:error, Error.new(:unprocessable_entity)}
               end,
               confirm: fn ^marked, _observation, @now -> {:error, :namespace_collision} end,
               conflict: fn ^marked, observation, "repository_namespace_collision", @now ->
                 assert observation.id == remote.id
                 {:ok, :conflicted}
               end
             )

    assert Process.get(:repository_fetch_calls) == 2
    assert Process.get(:repository_create_calls) == 1
  end

  test "a delayed self-create confirmed after POST returns 422 is not reported as a collision" do
    operation = operation()
    marked = %{operation | state: :effect_pending, lock_version: 2}
    context = context()
    remote = remote()

    assert {:ok, :confirmed} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ ->
                 calls = Process.get(:delayed_repository_fetch_calls, 0) + 1
                 Process.put(:delayed_repository_fetch_calls, calls)
                 if calls == 1, do: {:error, Error.new(:not_found)}, else: {:ok, remote}
               end,
               mark_effect: fn ^operation, ^context, @now -> {:ok, marked} end,
               authorize_effect: fn ^marked -> {:ok, context} end,
               repository_create: fn _, _, _, _ ->
                 {:error, Error.new(:unprocessable_entity)}
               end,
               confirm: fn ^marked, observation, @now ->
                 assert observation.id == remote.id
                 {:ok, :confirmed}
               end,
               conflict: fn _, _, _, _ -> flunk("self-create must not become a conflict") end
             )

    assert Process.get(:delayed_repository_fetch_calls) == 2
  end

  test "pause after marking is rechecked immediately before POST" do
    operation = operation()
    marked = %{operation | state: :effect_pending, lock_version: 2}
    context = context()

    assert {:ok, :paused} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ -> {:error, Error.new(:not_found)} end,
               mark_effect: fn ^operation, ^context, @now -> {:ok, marked} end,
               authorize_effect: fn ^marked -> {:error, :paused} end,
               repository_create: fn _, _, _, _ -> flunk("must not POST after pause") end,
               pause: fn ^marked, @now -> {:ok, :paused} end
             )
  end

  test "revocation after recovery GET is rechecked immediately before POST" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}
    context = %{context() | effect_marker: marker()}

    assert {:ok, :halted} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ -> {:error, Error.new(:not_found)} end,
               authorize_effect: fn ^operation -> {:error, :revoked} end,
               repository_create: fn _, _, _, _ -> flunk("must not POST after revocation") end,
               halt_effect: fn ^operation, @now, "credential_revoked" -> {:ok, :halted} end
             )
  end

  test "policy downgrade after marking checkpoints the effect before POST" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}
    context = %{context() | effect_marker: marker()}

    assert {:ok, :halted} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, context} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ -> {:error, Error.new(:not_found)} end,
               authorize_effect: fn ^operation -> {:error, :policy_disabled} end,
               repository_create: fn _, _, _, _ ->
                 flunk("must not POST after policy downgrade")
               end,
               halt_effect: fn ^operation, @now, "local_validation" -> {:ok, :halted} end
             )
  end

  test "canonical projection accepts the real repository client struct" do
    operation = %{operation() | state: :effect_pending, external_effect_marker: marker()}

    remote =
      struct!(
        Repository,
        Map.merge(remote(), %{has_issues: true, allow_merge_commit: true, fork: false})
      )

    assert {:ok, :confirmed} =
             RepositoryCreationWorker.process_operation(operation, @now,
               context: fn ^operation -> {:ok, %{context() | effect_marker: marker()}} end,
               token_fetch: fn _, _ -> token() end,
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end,
               confirm: fn ^operation, observation, @now ->
                 assert observation.id == 41
                 assert observation.owner_login == "acme"
                 {:ok, :confirmed}
               end
             )
  end

  defp operation do
    %MirrorOperation{
      id: 1,
      kind: "sync.repository.create",
      state: :processing,
      cursor: %{"trigger" => "local"}
    }
  end

  defp context do
    %{
      repository_mirror_id: 3,
      repository_id: 5,
      repository_generation: 1,
      local_write_version: 0,
      github_repository_id: nil,
      github_installation_id: 7,
      github_account_id: 9,
      github_account_login: "acme",
      effect_marker: nil,
      target: %{
        "name" => "widgets",
        "description" => "Canonical widgets",
        "visibility" => "private",
        "default_branch" => "main",
        "archived" => false
      }
    }
  end

  defp marker do
    %{
      "action" => "create_remote_repository",
      "expected_absence" => true,
      "target" => context().target
    }
  end

  defp remote do
    %{
      id: 41,
      node_id: "R_41",
      owner_id: 9,
      owner_login: "acme",
      full_name: "acme/widgets",
      name: "widgets",
      description: "Canonical widgets",
      visibility: :private,
      default_branch: "main",
      archived: false,
      updated_at: @now
    }
  end

  defp token do
    %InstallationToken{
      token: "installation-token",
      expires_at: ~U[2026-09-14 08:00:00Z],
      permissions: %{"metadata" => "read", "administration" => "write"}
    }
  end
end
