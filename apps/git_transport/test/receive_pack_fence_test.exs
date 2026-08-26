defmodule GitTransport.ReceivePackFenceTest.Reconciler do
  @behaviour ForgeRepos.RepositoryWriteReconcilers

  @impl true
  def reconcile_repository_locked(_repository, path, _deadline) do
    send(self(), {:reconciled, path})
    :ok
  end
end

defmodule GitTransport.ReceivePackFenceTest.BlockedRecovery do
  @behaviour ForgeRepos.RepositoryWriteReconcilers

  @impl true
  def reconcile_repository_locked(_repository, _path, _deadline),
    do: {:error, :unavailable}
end

defmodule GitTransport.ReceivePackFenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeRepos.{GitWriteOperation, Repository}
  alias GitTransport.ReceivePack
  alias Fornacast.{AuditEvent, Repo}

  @zero_oid String.duplicate("0", 40)
  @one_oid String.duplicate("1", 40)
  @two_oid String.duplicate("2", 40)

  setup %{tmp_dir: tmp_dir} do
    wait_for_persisted_workers(0)

    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      for table <- ~w(git_write_operations audit_events repositories users) do
        Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
      end
    end

    original_root = Application.fetch_env(:fornacast, :repo_storage_root)
    original_reconcilers = Application.fetch_env(:forge_repos, :repository_write_reconcilers)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {10, :receive_pack_test, __MODULE__.Reconciler}
    ])

    on_exit(fn ->
      restore_env(:fornacast, :repo_storage_root, original_root)
      restore_env(:forge_repos, :repository_write_reconcilers, original_reconcilers)
    end)

    username = "receive-fence-#{System.unique_integer([:positive])}"

    {:ok, owner} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    repository = repository_fixture(owner, "demo")

    {:ok, owner: owner, repository: repository}
  end

  @tag :tmp_dir
  test "prepared receive-pack intents are transactional and reject request replay", %{
    owner: owner,
    repository: repository
  } do
    request_id = "receive-pack-idempotent"

    commands = [
      {@zero_oid, @one_oid, "refs/heads/main"},
      {@zero_oid, @two_oid, "refs/heads/feature"}
    ]

    assert {:ok, [main, feature]} =
             ForgeRepos.prepare_receive_pack_operations(
               owner,
               repository,
               request_id,
               commands,
               write_deadline()
             )

    assert %GitWriteOperation{
             actor_user_id: actor_id,
             request_id: ^request_id,
             kind: :receive_pack,
             state: :prepared,
             target_ref: "refs/heads/main",
             expected_oid: nil,
             proposed_oid: @one_oid
           } = main

    assert actor_id == owner.id
    assert feature.target_ref == "refs/heads/feature"

    assert {:error, :conflict} =
             ForgeRepos.prepare_receive_pack_operations(
               owner,
               repository,
               request_id,
               commands,
               write_deadline()
             )

    assert {:error, :conflict} =
             ForgeRepos.prepare_receive_pack_operations(
               owner,
               repository,
               request_id,
               [{@zero_oid, @two_oid, "refs/heads/main"}],
               write_deadline()
             )

    assert {:error, :invalid} =
             ForgeRepos.prepare_receive_pack_operations(
               owner,
               repository,
               "invalid-batch",
               [
                 {@zero_oid, @one_oid, "refs/heads/other"},
                 {@zero_oid, @two_oid, "main"}
               ],
               write_deadline()
             )

    assert Repo.aggregate(GitWriteOperation, :count, :id) == 2

    assert {:error, :unavailable} =
             ForgeRepos.prepare_receive_pack_operations(
               owner,
               repository,
               "expired-deadline",
               [{@zero_oid, @one_oid, "refs/heads/expired"}],
               System.monotonic_time(:millisecond) - 1
             )
  end

  @tag :tmp_dir
  test "concurrent intent preparation has one winner and one typed conflict", %{
    owner: owner,
    repository: repository
  } do
    parent = self()
    request_id = "concurrent-receive-pack"
    commands = [{@zero_oid, @one_oid, "refs/heads/main"}]

    prepare = fn ->
      send(parent, {:intent_ready, self()})

      receive do
        :prepare ->
          ForgeRepos.prepare_receive_pack_operations(
            owner,
            repository,
            request_id,
            commands,
            write_deadline()
          )
      end
    end

    first = Task.async(prepare)
    second = Task.async(prepare)
    assert_receive {:intent_ready, first_pid}
    assert_receive {:intent_ready, second_pid}
    send(first_pid, :prepare)
    send(second_pid, :prepare)

    results = [Task.await(first), Task.await(second)]
    assert Enum.count(results, &match?({:ok, [%GitWriteOperation{}]}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 1

    assert 1 ==
             Repo.aggregate(
               from(operation in GitWriteOperation,
                 where: operation.request_id == ^request_id
               ),
               :count,
               :id
             )
  end

  @tag :tmp_dir
  test "Turso busy intent preparation retries within the deadline and exhausts safely", %{
    owner: owner,
    repository: repository
  } do
    if Application.get_env(:fornacast, :database_adapter) in ["libsql", "turso"] do
      attempt_key = {__MODULE__, make_ref()}

      retry_hook = fn multi, timeout ->
        attempt = Process.get(attempt_key, 0) + 1
        Process.put(attempt_key, attempt)
        assert timeout > 0

        if attempt < 3,
          do: :busy,
          else: Repo.transaction(multi, timeout: timeout)
      end

      assert {:ok, [%GitWriteOperation{target_ref: "refs/heads/main"}]} =
               ForgeRepos.with_test_receive_pack_transaction_hook(retry_hook, fn ->
                 ForgeRepos.prepare_receive_pack_operations(
                   owner,
                   repository,
                   "busy-then-success",
                   [{@zero_oid, @one_oid, "refs/heads/main"}],
                   write_deadline()
                 )
               end)

      assert Process.get(attempt_key) == 3
      Process.put(attempt_key, 0)

      assert {:error, :unavailable} =
               ForgeRepos.with_test_receive_pack_transaction_hook(
                 fn _multi, timeout ->
                   Process.put(attempt_key, Process.get(attempt_key, 0) + 1)
                   assert timeout > 0
                   :busy
                 end,
                 fn ->
                   ForgeRepos.prepare_receive_pack_operations(
                     owner,
                     repository,
                     "busy-exhausted",
                     [{@zero_oid, @two_oid, "refs/heads/feature"}],
                     write_deadline()
                   )
                 end
               )

      assert Process.get(attempt_key) == 12
      refute Repo.get_by(GitWriteOperation, request_id: "busy-exhausted")
    end
  end

  @tag :tmp_dir
  test "partial native statuses reconcile every prepared ref from exact Git evidence", %{
    owner: owner,
    repository: repository
  } do
    path = ForgeRepos.absolute_storage_path(repository)
    {main_oid, feature_oid} = create_commits(path)

    commands = [
      {@zero_oid, main_oid, "refs/heads/main"},
      {@zero_oid, feature_oid, "refs/heads/feature"}
    ]

    native = fn ^path, "PACK", ^commands ->
      update_ref(path, main_oid, "refs/heads/main")

      {:ok,
       [
         {"refs/heads/main", "ok", nil},
         {"refs/heads/feature", "ng", "rejected"}
       ]}
    end

    request_id = "partial-receive-pack"

    assert {:ok, _response, statuses} =
             ReceivePack.with_test_native(native, fn ->
               ReceivePack.response(
                 owner,
                 repository,
                 request(commands),
                 "PACK",
                 request_id
               )
             end)

    assert statuses == [
             {"refs/heads/main", "ok", nil},
             {"refs/heads/feature", "ng", "rejected"}
           ]

    assert [
             %GitWriteOperation{
               target_ref: "refs/heads/feature",
               state: :failed,
               failure_reason: "effect_not_started"
             },
             %GitWriteOperation{
               id: completed_id,
               target_ref: "refs/heads/main",
               state: :bookkeeping_complete,
               failure_reason: nil
             }
           ] =
             Repo.all(
               from operation in GitWriteOperation,
                 where:
                   operation.repository_id == ^repository.id and
                     operation.request_id == ^request_id,
                 order_by: [asc: operation.target_ref]
             )

    assert %Repository{last_pushed_at: %DateTime{}} = Repo.get!(Repository, repository.id)

    assert [
             %AuditEvent{
               action: "repository.pushed",
               actor_user_id: actor_id,
               request_id: ^request_id,
               operation_id: operation_id,
               metadata: %{
                 "ref" => "refs/heads/main",
                 "oid" => ^main_oid,
                 "result" => "success"
               }
             }
           ] = Repo.all(AuditEvent)

    assert actor_id == owner.id
    assert operation_id == "git_write:#{completed_id}"
  end

  @tag :tmp_dir
  test "response and worker reject over-limit command sets without intents or native", %{
    owner: owner,
    repository: repository
  } do
    original_limits = Application.get_env(:git_core, :limits)

    limits =
      Application.get_env(:git_core, :limits, [])
      |> Keyword.put(:receive_pack_commands, 1)

    Application.put_env(:git_core, :limits, limits)

    on_exit(fn ->
      if is_nil(original_limits),
        do: Application.delete_env(:git_core, :limits),
        else: Application.put_env(:git_core, :limits, original_limits)
    end)

    commands = [
      {@zero_oid, @one_oid, "refs/heads/main"},
      {@zero_oid, @two_oid, "refs/heads/feature"}
    ]

    test_pid = self()

    native = fn _path, _pack, _commands ->
      send(test_pid, :over_limit_native_invoked)
      {:ok, []}
    end

    assert {:error, :unavailable} =
             ForgeRepos.prepare_receive_pack_operations(
               owner,
               repository,
               "over-limit-context",
               commands,
               write_deadline()
             )

    assert Repo.aggregate(GitWriteOperation, :count, :id) == 0

    assert {:ok, _response, statuses} =
             ReceivePack.with_test_native(native, fn ->
               ReceivePack.response(
                 owner,
                 repository,
                 request(commands),
                 "PACK",
                 "over-limit-response"
               )
             end)

    assert Enum.all?(statuses, fn {_ref, status, _message} -> status == "ng" end)
    refute_receive :over_limit_native_invoked
    assert Repo.aggregate(GitWriteOperation, :count, :id) == 0

    reply = make_ref()

    worker =
      Task.async(fn ->
        GitTransport.ReceivePackWorker.run(
          test_pid,
          reply,
          owner,
          repository,
          "over-limit-worker",
          "PACK",
          commands,
          native
        )
      end)

    assert_receive {^reply, {:error, {:unavailable, :receive_pack_bookkeeping}}}
    assert :ok = Task.await(worker)
    refute_receive :over_limit_native_invoked
    assert Repo.aggregate(GitWriteOperation, :count, :id) == 0
  end

  @tag :tmp_dir
  test "portable target refs accept 255 bytes and reject longer refs before native", %{
    owner: owner,
    repository: repository
  } do
    max_ref = "refs/heads/" <> String.duplicate("a", 244)
    overlong_ref = "refs/heads/" <> String.duplicate("a", 245)
    test_pid = self()

    assert byte_size(max_ref) == 255
    assert byte_size(overlong_ref) == 256

    native = fn _path, _pack, _commands ->
      send(test_pid, :overlong_ref_native_invoked)
      {:ok, [{overlong_ref, "ok", nil}]}
    end

    assert {:ok, _response, [{^overlong_ref, "ng", _message}]} =
             ReceivePack.with_test_native(native, fn ->
               ReceivePack.response(
                 owner,
                 repository,
                 request([{@zero_oid, @one_oid, overlong_ref}]),
                 "PACK",
                 "overlong-ref-response"
               )
             end)

    refute_receive :overlong_ref_native_invoked
    assert Repo.aggregate(GitWriteOperation, :count, :id) == 0

    assert {:error, :invalid} =
             ForgeRepos.prepare_receive_pack_operations(
               owner,
               repository,
               "overlong-ref-context",
               [{@zero_oid, @one_oid, overlong_ref}],
               write_deadline()
             )

    assert Repo.aggregate(GitWriteOperation, :count, :id) == 0

    assert {:ok, [%GitWriteOperation{target_ref: ^max_ref}]} =
             ForgeRepos.prepare_receive_pack_operations(
               owner,
               repository,
               "max-ref-context",
               [{@zero_oid, @one_oid, max_ref}],
               write_deadline()
             )
  end

  @tag :tmp_dir
  test "stale expected ref is rejected before intent, native, or false bookkeeping", %{
    owner: owner,
    repository: repository
  } do
    path = ForgeRepos.absolute_storage_path(repository)
    {expected_oid, current_oid} = create_commits(path)
    update_ref(path, current_oid, "refs/heads/main")
    commands = [{expected_oid, current_oid, "refs/heads/main"}]
    test_pid = self()
    request_id = "stale-expected-ref"

    native = fn _path, _pack, _commands ->
      send(test_pid, :stale_native_invoked)
      {:error, :stale_command}
    end

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             ReceivePack.with_test_native(native, fn ->
               ReceivePack.response(owner, repository, request(commands), "PACK", request_id)
             end)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"
    refute_receive :stale_native_invoked
    refute Repo.get_by(GitWriteOperation, request_id: request_id)
    assert is_nil(Repo.get!(Repository, repository.id).last_pushed_at)
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  @tag :tmp_dir
  test "native ref success holds the fence through durable bookkeeping", %{
    owner: owner,
    repository: repository
  } do
    path = ForgeRepos.absolute_storage_path(repository)
    {proposed_oid, _other_oid} = create_commits(path)
    commands = [{@zero_oid, proposed_oid, "refs/heads/main"}]
    test_pid = self()

    native = fn ^path, "PACK", ^commands ->
      update_ref(path, proposed_oid, "refs/heads/main")
      send(test_pid, {:native_effect_complete, self()})

      receive do
        :finish_native -> {:ok, [{"refs/heads/main", "ok", nil}]}
      end
    end

    request_id = "fenced-bookkeeping"

    response =
      Task.async(fn ->
        ReceivePack.with_test_native(native, fn ->
          ReceivePack.response(owner, repository, request(commands), "PACK", request_id)
        end)
      end)

    assert_receive {:native_effect_complete, worker}
    on_exit(fn -> send(worker, :finish_native) end)

    assert %GitWriteOperation{state: :prepared} =
             Repo.get_by!(GitWriteOperation, request_id: request_id)

    assert is_nil(Repo.get!(Repository, repository.id).last_pushed_at)

    publication =
      Task.async(fn ->
        ForgeRepos.with_import_publication_fence(repository, :receive_pack, fn _path,
                                                                               _remaining ->
          operation = Repo.get_by!(GitWriteOperation, request_id: request_id)
          persisted_repository = Repo.get!(Repository, repository.id)
          send(test_pid, {:publication_entered, operation, persisted_repository, self()})

          receive do
            :finish_publication -> :published
          end
        end)
      end)

    wait_for_waiters(1)
    refute_receive {:publication_entered, _operation, _repository, _pid}
    send(worker, :finish_native)

    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(response)

    assert_receive {:publication_entered, %GitWriteOperation{state: :bookkeeping_complete},
                    %Repository{last_pushed_at: %DateTime{}}, publication_pid}

    send(publication_pid, :finish_publication)
    assert :published = Task.await(publication)
  end

  @tag :tmp_dir
  test "worker crash after a native ref effect leaves intent for the next fence", %{
    owner: owner,
    repository: repository
  } do
    path = ForgeRepos.absolute_storage_path(repository)
    {proposed_oid, _other_oid} = create_commits(path)
    commands = [{@zero_oid, proposed_oid, "refs/heads/main"}]
    request_id = "crashed-after-native"

    native = fn ^path, "PACK", ^commands ->
      update_ref(path, proposed_oid, "refs/heads/main")
      exit(:simulated_after_native_crash)
    end

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             ReceivePack.with_test_native(native, fn ->
               ReceivePack.response(owner, repository, request(commands), "PACK", request_id)
             end)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"

    operation = Repo.get_by!(GitWriteOperation, request_id: request_id)
    assert operation.state == :prepared
    assert operation.failure_reason == nil
    assert is_nil(Repo.get!(Repository, repository.id).last_pushed_at)

    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {100, :git_writes, ForgeRepos.GitWriteRecovery}
    ])

    for _attempt <- 1..2 do
      assert :entered =
               ForgeRepos.with_write_fence(repository, :ref, fn _path, _remaining -> :entered end)
    end

    assert Repo.get!(GitWriteOperation, operation.id).state == :bookkeeping_complete
    assert %Repository{last_pushed_at: %DateTime{}} = Repo.get!(Repository, repository.id)

    assert 1 ==
             Repo.aggregate(
               from(audit in AuditEvent,
                 where:
                   audit.operation_id == ^"git_write:#{operation.id}" and
                     audit.action == "repository.pushed"
               ),
               :count,
               :id
             )
  end

  @tag :tmp_dir
  test "receive-pack queued behind publication rejects the replaced generation before native", %{
    owner: owner,
    repository: repository
  } do
    test_pid = self()

    publication =
      Task.async(fn ->
        ForgeRepos.with_import_publication_fence(repository, :receive_pack, fn _path,
                                                                               _remaining ->
          send(test_pid, {:publication_holds_fence, self()})

          receive do
            :finish_publication -> :published
          end
        end)
      end)

    assert_receive {:publication_holds_fence, publication_pid}
    on_exit(fn -> send(publication_pid, :finish_publication) end)

    response =
      Task.async(fn ->
        ReceivePack.with_test_native(
          fn _path, _pack, _commands ->
            send(test_pid, :stale_native_invoked)
            {:ok, [{"refs/heads/main", "ok", nil}]}
          end,
          fn ->
            ReceivePack.response(
              owner,
              repository,
              request(),
              "PACK",
              "queued-behind-publication"
            )
          end
        )
      end)

    wait_for_waiters(1)

    assert {1, nil} =
             Repo.update_all(
               from(candidate in Repository, where: candidate.id == ^repository.id),
               set: [
                 generation: repository.generation + 1,
                 lifecycle: :tombstoned,
                 deleted_at: ~U[2026-08-26 00:00:00Z]
               ]
             )

    send(publication_pid, :finish_publication)
    assert :published = Task.await(publication)

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             Task.await(response)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"
    refute_receive :stale_native_invoked
    refute Repo.get_by(GitWriteOperation, request_id: "queued-behind-publication")
  end

  @tag :tmp_dir
  test "bookkeeping failure returns unavailable and retains recoverable evidence", %{
    owner: owner,
    repository: repository
  } do
    path = ForgeRepos.absolute_storage_path(repository)
    {proposed_oid, _other_oid} = create_commits(path)
    commands = [{@zero_oid, proposed_oid, "refs/heads/main"}]
    request_id = "bookkeeping-failure"

    native = fn ^path, "PACK", ^commands ->
      update_ref(path, proposed_oid, "refs/heads/main")

      assert {1, nil} =
               Repo.update_all(
                 from(candidate in Repository, where: candidate.id == ^repository.id),
                 set: [generation: repository.generation + 1]
               )

      {:ok, [{"refs/heads/main", "ok", nil}]}
    end

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             ReceivePack.with_test_native(native, fn ->
               ReceivePack.response(owner, repository, request(commands), "PACK", request_id)
             end)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"

    assert %GitWriteOperation{state: :prepared, failure_reason: nil, lease_owner: nil} =
             Repo.get_by!(GitWriteOperation, request_id: request_id)

    assert %Repository{generation: generation, last_pushed_at: nil} =
             Repo.get!(Repository, repository.id)

    assert generation == repository.generation + 1
    refute Repo.get_by(AuditEvent, request_id: request_id)
  end

  @tag :tmp_dir
  test "reconciles before native mutation and uses the fence-resolved path once", %{
    repository: repository
  } do
    expected_path = ForgeRepos.absolute_storage_path(repository)
    commands = successful_commands(repository)
    parent = self()

    native = fn path, pack, ^commands ->
      assert_receive {:reconciled, ^path}
      send(parent, {:native, path, pack, commands})
      apply_commands(path, commands)
      {:ok, [{"refs/heads/main", "ok", nil}]}
    end

    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} =
             ReceivePack.with_test_native(native, fn ->
               receive_pack_response(repository, request(commands), "PACK")
             end)

    assert_receive {:native, ^expected_path, "PACK", ^commands}

    refute_receive {:native, _, _, _}
  end

  @tag :tmp_dir
  test "serializes native mutations for the same repository", %{repository: repository} do
    parent = self()

    first =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :first, self()})

        receive do
          :release -> {:ok, [{"refs/heads/main", "ok", nil}]}
        end
      end)

    assert_receive {:native_entered, :first, first_worker}
    on_exit(fn -> send(first_worker, :release) end)

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :second})
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_waiters(1)
    refute_receive {:native_entered, :second}
    send(first_worker, :release)
    assert_receive {:native_entered, :second}

    assert {:ok, _response, _statuses} = Task.await(first)
    assert {:ok, _response, _statuses} = Task.await(second)
  end

  @tag :tmp_dir
  test "mutates two repositories concurrently while a third waits for node capacity", %{
    owner: owner
  } do
    parent = self()

    repositories =
      for suffix <- 1..3 do
        repository_fixture(owner, "demo-#{suffix}")
      end

    native = fn _path, pack, _commands ->
      send(parent, {:native_entered, pack, self()})

      receive do
        :release -> {:ok, [{"refs/heads/main", "ok", nil}]}
      end
    end

    [first_repo, second_repo, third_repo] = repositories
    first = response_task(first_repo, native, "FIRST")
    second = response_task(second_repo, native, "SECOND")
    assert_receive {:native_entered, "FIRST", first_pid}
    assert_receive {:native_entered, "SECOND", second_pid}

    third = response_task(third_repo, native, "THIRD")
    wait_for_waiters(1)
    refute_receive {:native_entered, "THIRD", _pid}

    send(first_pid, :release)
    assert_receive {:native_entered, "THIRD", third_pid}
    send(second_pid, :release)
    send(third_pid, :release)

    for task <- [first, second, third] do
      assert {:ok, _response, _statuses} = Task.await(task)
    end
  end

  @tag :tmp_dir
  test "blocked recovery renders protocol ng statuses without invoking native mutation", %{
    repository: repository
  } do
    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {10, :blocked_recovery, __MODULE__.BlockedRecovery}
    ])

    native = fn _path, _pack, _commands ->
      send(self(), :native_invoked)
      {:ok, []}
    end

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             ReceivePack.with_test_native(native, fn ->
               receive_pack_response(repository, request(), "SECRET PACK")
             end)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"
    refute response =~ "blocked_recovery"
    refute response =~ "SECRET PACK"
    refute_receive :native_invoked
  end

  @tag :tmp_dir
  test "keeps the writer lease after the deadline until a long native mutation returns", %{
    repository: repository
  } do
    original_limits = Application.fetch_env(:git_core, :limits)

    limits =
      Application.get_env(:git_core, :limits, [])
      |> Keyword.put(:content_deadline_ms, 25)

    Application.put_env(:git_core, :limits, limits)
    on_exit(fn -> restore_env(:git_core, :limits, original_limits) end)
    parent = self()

    first =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :long, self()})

        receive do
          :release -> {:ok, [{"refs/heads/main", "ok", nil}]}
        end
      end)

    assert_receive {:native_entered, :long, first_worker}
    on_exit(fn -> send(first_worker, :release) end)
    Process.sleep(30)

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, {:native_entered, :timed_out_waiter})
        {:ok, []}
      end)

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             Task.await(second)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"
    refute_receive {:native_entered, :timed_out_waiter}
    assert Task.yield(first, 0) == nil

    send(first_worker, :release)

    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
             Task.await(first)

    assert response =~ "ng refs/heads/main Git receive-pack unavailable"
    assert [%GitWriteOperation{state: :prepared}] = Repo.all(GitWriteOperation)

    restore_env(:git_core, :limits, original_limits)
    assert :ok = ForgeRepos.GitWriteRecovery.reconcile_repository(repository)
    commands = successful_commands(repository)

    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} =
             response_task(
               repository,
               request(commands),
               fn path, _pack, ^commands ->
                 apply_commands(path, commands)
                 {:ok, [{"refs/heads/main", "ok", nil}]}
               end,
               "PACK"
             )
             |> Task.await()
  end

  @tag :tmp_dir
  test "caller death cannot release a repository while its dirty NIF is still running", %{
    owner: owner,
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "dirty-nif-entered")
    release_path = Path.join(tmp_dir, "dirty-nif-release")
    on_exit(fn -> File.write(release_path, "release") end)
    parent = self()

    dirty_native = fn _path, _pack, _commands ->
      {:ok, {}} = GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)
      {:ok, [{"refs/heads/main", "ok", nil}]}
    end

    caller =
      spawn(fn ->
        result =
          ReceivePack.with_test_native(dirty_native, fn ->
            receive_pack_response(repository, request(), "PACK")
          end)

        send(parent, {:first_response, result})
      end)

    caller_monitor = Process.monitor(caller)
    wait_for_file(entered_path)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 500

    other_repository = repository_fixture(owner, "other")

    assert {:ok, _response, _statuses} =
             response_task(other_repository, fn _path, _pack, _commands ->
               send(parent, :other_repository_entered)
               {:ok, [{"refs/heads/main", "ok", nil}]}
             end)
             |> Task.await()

    assert_receive :other_repository_entered

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, :second_native_entered)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_waiters(1)
    refute_receive :second_native_entered
    File.write!(release_path, "release")
    assert_receive :second_native_entered
    assert {:ok, _response, _statuses} = Task.await(second)
    refute_receive {:first_response, _result}
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "dirty NIF worker and fence survive worker supervisor crash and restart", %{
    owner: owner,
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "supervisor-crash-dirty-nif-entered")
    release_path = Path.join(tmp_dir, "supervisor-crash-dirty-nif-release")
    on_exit(fn -> File.write(release_path, "release") end)
    parent = self()

    first =
      response_task(repository, fn _path, _pack, _commands ->
        {:ok, {}} = GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_file(entered_path)
    original_manager = Process.whereis(GitTransport.ReceivePackWorkerManager)
    manager_monitor = Process.monitor(original_manager)
    Process.exit(original_manager, :kill)
    assert_receive {:DOWN, ^manager_monitor, :process, ^original_manager, :killed}
    wait_for_worker_manager_restart(original_manager)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 1
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 1

    original_supervisor = Process.whereis(GitTransport.ReceivePackWorkerSupervisor)
    supervisor_monitor = Process.monitor(original_supervisor)
    Process.exit(original_supervisor, :kill)
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^original_supervisor, :killed}
    wait_for_worker_supervisor_restart(original_supervisor)
    assert Task.yield(first, 0) == nil
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 1

    restarted_supervisor = Process.whereis(GitTransport.ReceivePackWorkerSupervisor)
    restarted_monitor = Process.monitor(restarted_supervisor)
    Process.exit(restarted_supervisor, :kill)

    assert_receive {:DOWN, ^restarted_monitor, :process, ^restarted_supervisor, :killed}
    wait_for_worker_supervisor_restart(restarted_supervisor)
    assert Task.yield(first, 0) == nil
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 1

    other_repository = repository_fixture(owner, "supervisor-crash-other")

    assert {:ok, _response, _statuses} =
             response_task(other_repository, fn _path, _pack, _commands ->
               send(parent, :supervisor_crash_other_entered)
               {:ok, [{"refs/heads/main", "ok", nil}]}
             end)
             |> Task.await()

    assert_receive :supervisor_crash_other_entered

    second =
      response_task(repository, fn _path, _pack, _commands ->
        send(parent, :supervisor_crash_same_entered)
        {:ok, [{"refs/heads/main", "ok", nil}]}
      end)

    wait_for_waiters(1)
    refute_receive :supervisor_crash_same_entered
    File.write!(release_path, "release")
    assert {:ok, _response, _statuses} = Task.await(first)
    assert_receive :supervisor_crash_same_entered
    assert {:ok, _response, _statuses} = Task.await(second)
    wait_for_workers(0)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 0
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 0
  end

  @tag :tmp_dir
  test "native ok without a ref effect is rendered as durable ng", %{repository: repository} do
    assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack failed"}]} =
             ReceivePack.with_test_native(
               fn _path, _pack, _commands ->
                 {:ok, [{"refs/heads/main", "ok", nil}]}
               end,
               fn -> receive_pack_response(repository, request(), "PACK") end
             )

    assert response =~ "ng refs/heads/main Git receive-pack failed"

    assert [%GitWriteOperation{state: :failed, failure_reason: "effect_not_started"}] =
             Repo.all(GitWriteOperation)

    assert is_nil(Repo.get!(Repository, repository.id).last_pushed_at)
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  @tag :tmp_dir
  test "native errors and raises render ng and release the writer lease", %{
    repository: repository
  } do
    assert {:ok, _response, [{"refs/heads/main", "ng", "Git receive-pack failed"}]} =
             ReceivePack.with_test_native(
               fn _path, _pack, _commands -> {:error, :native_failed} end,
               fn -> receive_pack_response(repository, request(), "PACK") end
             )

    assert {:ok, _response, [{"refs/heads/main", "ng", "Git receive-pack failed"}]} =
             ReceivePack.with_test_native(
               fn _path, _pack, _commands -> raise "native crashed" end,
               fn -> receive_pack_response(repository, request(), "PACK") end
             )

    assert [first, second] =
             GitWriteOperation
             |> order_by([operation], asc: operation.id)
             |> Repo.all()

    for operation <- [first, second] do
      assert operation.state == :failed
      assert operation.failure_reason == "effect_not_started"
    end

    assert is_nil(Repo.get!(Repository, repository.id).last_pushed_at)
    assert Repo.aggregate(AuditEvent, :count, :id) == 0

    assert {:ok, lease} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :ok = GitCore.RepositoryWriteLimiter.release(lease)
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "worker crashes before a result render ng and release the writer lease", %{
    repository: repository
  } do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
                 ReceivePack.with_test_native(
                   fn _path, _pack, _commands -> exit(:simulated_worker_crash) end,
                   fn -> receive_pack_response(repository, request(), "PACK") end
                 )

        assert response =~ "ng refs/heads/main Git receive-pack unavailable"
      end)

    refute log =~ "PACK"

    assert {:ok, lease} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :ok = GitCore.RepositoryWriteLimiter.release(lease)
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "worker replies are correlated and completed workers leave no mailbox or child residue", %{
    repository: repository
  } do
    decoy = make_ref()
    send(self(), {decoy, :keep})

    assert {:ok, _response, _statuses} =
             ReceivePack.with_test_native(
               fn _path, _pack, _commands ->
                 {:ok, [{"refs/heads/main", "ok", nil}]}
               end,
               fn -> receive_pack_response(repository, request(), "PACK") end
             )

    assert_receive {^decoy, :keep}
    wait_for_workers(0)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  @tag :tmp_dir
  test "repeated worker start and supervisor crash races leave no monitor or mailbox residue", %{
    repository: repository
  } do
    decoy = make_ref()
    send(self(), {decoy, :keep})

    for _iteration <- 1..3 do
      supervisor = Process.whereis(GitTransport.ReceivePackWorkerSupervisor)
      monitor = Process.monitor(supervisor)

      response =
        response_task(repository, fn _path, _pack, _commands ->
          {:ok, [{"refs/heads/main", "ok", nil}]}
        end)

      Process.exit(supervisor, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, :killed}
      wait_for_worker_supervisor_restart(supervisor)

      assert {:ok, _response, [{"refs/heads/main", status, _message}]} = Task.await(response)
      assert status in ["ok", "ng"]
      wait_for_tracked_workers(0)
      wait_for_workers(0)
    end

    assert_receive {^decoy, :keep}
    assert {:messages, []} = Process.info(self(), :messages)
  end

  @tag :tmp_dir
  test "worker completion during manager downtime removes its persistent registry entry", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "manager-downtime-dirty-nif-entered")
    release_path = Path.join(tmp_dir, "manager-downtime-dirty-nif-release")
    root_supervisor = Process.whereis(GitTransport.Supervisor)
    commands = successful_commands(repository)

    on_exit(fn ->
      File.write(release_path, "release")
      safe_resume(root_supervisor)
      Application.ensure_all_started(:git_transport)
    end)

    response =
      response_task(
        repository,
        request(commands),
        fn path, _pack, ^commands ->
          {:ok, {}} =
            GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)

          apply_commands(path, commands)
          {:ok, [{"refs/heads/main", "ok", nil}]}
        end,
        "PACK"
      )

    wait_for_file(entered_path)
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 1
    :ok = :sys.suspend(root_supervisor)
    manager = Process.whereis(GitTransport.ReceivePackWorkerManager)
    monitor = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^manager, :killed}
    assert Process.whereis(GitTransport.ReceivePackWorkerManager) == nil

    File.write!(release_path, "release")
    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(response)
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 0

    :ok = :sys.resume(root_supervisor)
    wait_for_worker_manager_restart(manager)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 0
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 0
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "manager crashes at readiness and activation boundaries never leak or mutate invisibly", %{
    repository: repository
  } do
    on_exit(fn -> GitTransport.ReceivePackWorkerManager.set_test_fault(nil) end)
    parent = self()
    commands = successful_commands(repository)

    for phase <- [
          :after_ready,
          :after_persist,
          :after_active_persist,
          :after_reply,
          :after_go
        ] do
      manager = Process.whereis(GitTransport.ReceivePackWorkerManager)
      monitor = Process.monitor(manager)
      :ok = GitTransport.ReceivePackWorkerManager.set_test_fault(phase)

      response =
        response_task(
          repository,
          request(commands),
          fn path, _pack, ^commands ->
            apply_commands(path, commands)
            send(parent, {:boundary_native_entered, phase})
            {:ok, [{"refs/heads/main", "ok", nil}]}
          end,
          "PACK"
        )

      assert_receive {:DOWN, ^monitor, :process, ^manager, :killed}
      :ok = GitTransport.ReceivePackWorkerManager.set_test_fault(nil)
      wait_for_worker_manager_restart(manager)

      assert {:ok, _response, [{"refs/heads/main", status, _message}]} = Task.await(response)

      if phase == :after_go do
        assert status == "ok"
        assert_receive {:boundary_native_entered, :after_go}
      else
        assert status == "ng"
        refute_receive {:boundary_native_entered, ^phase}
      end

      wait_for_tracked_workers(0)
      wait_for_persisted_workers(0)
      wait_for_workers(0)
    end

    assert {:messages, []} = Process.info(self(), :messages)
  end

  @tag :tmp_dir
  test "receive-pack worker supervision waits indefinitely and precedes SSH admission" do
    [worker_spec, manager_spec | daemon_specs] = GitTransport.Application.child_specs()
    assert worker_spec.id == GitTransport.ReceivePackWorkerSupervisor
    assert worker_spec.shutdown == :infinity
    assert manager_spec.id == GitTransport.ReceivePackWorkerManager
    assert manager_spec.shutdown == :infinity

    assert Enum.all?(daemon_specs, fn spec ->
             Supervisor.child_spec(spec, []).id == GitTransport.Daemon
           end)
  end

  @tag :tmp_dir
  test "application shutdown waits for an admitted dirty NIF without reopening the lease", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "shutdown-dirty-nif-entered")
    release_path = Path.join(tmp_dir, "shutdown-dirty-nif-release")
    commands = successful_commands(repository)

    on_exit(fn ->
      File.write(release_path, "release")
      Application.ensure_all_started(:git_transport)
    end)

    response =
      response_task(
        repository,
        request(commands),
        fn path, _pack, ^commands ->
          {:ok, {}} =
            GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)

          apply_commands(path, commands)
          {:ok, [{"refs/heads/main", "ok", nil}]}
        end,
        "PACK"
      )

    wait_for_file(entered_path)
    stopper = Task.async(fn -> Application.stop(:git_transport) end)
    assert Task.yield(stopper, 30) == nil

    assert {:error, :timeout} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 25
             )

    File.write!(release_path, "release")
    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(response)
    assert :ok = Task.await(stopper)
    assert {:ok, _started} = Application.ensure_all_started(:git_transport)
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "application shutdown waits for a dirty NIF orphaned by supervisor restart", %{
    repository: repository,
    tmp_dir: tmp_dir
  } do
    entered_path = Path.join(tmp_dir, "orphan-shutdown-dirty-nif-entered")
    release_path = Path.join(tmp_dir, "orphan-shutdown-dirty-nif-release")
    commands = successful_commands(repository)

    on_exit(fn ->
      File.write(release_path, "release")
      Application.ensure_all_started(:git_transport)
    end)

    response =
      response_task(
        repository,
        request(commands),
        fn path, _pack, ^commands ->
          {:ok, {}} =
            GitTransport.TestDirtyIoNative.test_dirty_io_wait(entered_path, release_path)

          apply_commands(path, commands)
          {:ok, [{"refs/heads/main", "ok", nil}]}
        end,
        "PACK"
      )

    wait_for_file(entered_path)
    original_manager = Process.whereis(GitTransport.ReceivePackWorkerManager)
    manager_monitor = Process.monitor(original_manager)
    Process.exit(original_manager, :kill)
    assert_receive {:DOWN, ^manager_monitor, :process, ^original_manager, :killed}
    wait_for_worker_manager_restart(original_manager)
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 1

    original_supervisor = Process.whereis(GitTransport.ReceivePackWorkerSupervisor)
    monitor = Process.monitor(original_supervisor)
    Process.exit(original_supervisor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^original_supervisor, :killed}
    wait_for_worker_supervisor_restart(original_supervisor)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 1

    stopper = Task.async(fn -> Application.stop(:git_transport) end)
    assert Task.yield(stopper, 30) == nil

    assert {:error, :timeout} =
             GitCore.RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 25
             )

    File.write!(release_path, "release")
    assert {:ok, _response, [{"refs/heads/main", "ok", nil}]} = Task.await(response)
    assert :ok = Task.await(stopper)
    assert {:ok, _started} = Application.ensure_all_started(:git_transport)
    assert GitTransport.ReceivePackWorkerManager.tracked_worker_count() == 0
    assert GitTransport.ReceivePackWorkerManager.persisted_worker_count() == 0
    wait_for_workers(0)
  end

  @tag :tmp_dir
  test "an unavailable writer limiter renders ng without invoking native", %{
    repository: repository
  } do
    parent = self()

    native = fn _path, _pack, _commands ->
      send(parent, :native_invoked)
      {:ok, []}
    end

    try do
      assert :ok = Application.stop(:git_core)

      assert {:ok, response, [{"refs/heads/main", "ng", "Git receive-pack unavailable"}]} =
               ReceivePack.with_test_native(native, fn ->
                 receive_pack_response(repository, request(), "PACK")
               end)

      assert response =~ "ng refs/heads/main Git receive-pack unavailable"
      refute_receive :native_invoked
    after
      assert {:ok, _started} = Application.ensure_all_started(:git_core)
    end
  end

  @tag :tmp_dir
  test "HTTP and SSH mutation flows share the only native receive-pack callsite" do
    app_libs = Path.expand("../../*/lib/**/*.ex", __DIR__) |> Path.wildcard()

    native_calls =
      for path <- app_libs,
          source = File.read!(path),
          Regex.match?(~r/GitCore\.receive_pack(?:\s*\(|\/3)/, source),
          do: path

    assert native_calls == [Path.expand("../lib/git_transport/receive_pack.ex", __DIR__)]

    ssh_channel = File.read!(Path.expand("../lib/git_transport/channel.ex", __DIR__))

    http_controller =
      File.read!(
        Path.expand(
          "../../fornacast_web/lib/fornacast_web/controllers/git_http_controller.ex",
          __DIR__
        )
      )

    assert ssh_channel =~ "GitTransport.ReceivePack.response("
    assert ssh_channel =~ "state.receive_pack_request_id"
    assert http_controller =~ "GitTransport.ReceivePack.response("
    assert http_controller =~ "RequestMetadata.external_request_id(conn)"
    assert http_controller =~ "ReceivePack.http_operation_batch_id("
    refute ssh_channel =~ "record_push"
    refute http_controller =~ "record_push"
  end

  defp request(commands \\ [{@zero_oid, @one_oid, "refs/heads/main"}]) do
    %{
      commands:
        commands
        |> Enum.reverse()
        |> Enum.map(fn {old, new, ref} -> %{old: old, new: new, ref: ref} end),
      capabilities: MapSet.new(["report-status"]),
      phase: :pack
    }
  end

  defp create_commits(path) do
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    main = git!(path, ["commit-tree", tree, "-m", "main"])
    feature = git!(path, ["commit-tree", tree, "-p", main, "-m", "feature"])
    {main, feature}
  end

  defp successful_commands(repository) do
    path = ForgeRepos.absolute_storage_path(repository)
    {proposed_oid, _other_oid} = create_commits(path)
    [{@zero_oid, proposed_oid, "refs/heads/main"}]
  end

  defp apply_commands(path, commands) do
    Enum.each(commands, fn {_old_oid, proposed_oid, target_ref} ->
      update_ref(path, proposed_oid, target_ref)
    end)
  end

  defp update_ref(path, oid, ref), do: git!(path, ["update-ref", ref, oid])

  defp git!(path, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Receive Pack Fence"},
      {"GIT_AUTHOR_EMAIL", "receive-pack@example.test"},
      {"GIT_COMMITTER_NAME", "Receive Pack Fence"},
      {"GIT_COMMITTER_EMAIL", "receive-pack@example.test"}
    ]

    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args], env: env, stderr_to_stdout: true)

    String.trim(output)
  end

  defp repository_fixture(owner, slug) do
    unique_slug = "#{slug}-#{System.unique_integer([:positive])}"

    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{name: unique_slug, slug: unique_slug})

    repository
  end

  defp response_task(repository, native, pack \\ "PACK") do
    response_task(repository, request(), native, pack)
  end

  defp response_task(repository, request, native, pack) do
    Task.async(fn ->
      ReceivePack.with_test_native(native, fn ->
        receive_pack_response(repository, request, pack)
      end)
    end)
  end

  defp receive_pack_response(repository, request, pack) do
    actor = ForgeRepos.repository_owner(repository)
    request_id = "receive-fence-#{System.unique_integer([:positive])}"
    ReceivePack.response(actor, repository, request, pack, request_id)
  end

  defp write_deadline do
    System.monotonic_time(:millisecond) + 10_000
  end

  defp wait_for_waiters(expected, attempts \\ 100)

  defp wait_for_waiters(expected, attempts) when attempts > 0 do
    if map_size(:sys.get_state(GitCore.RepositoryWriteLimiter).waiters) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_waiters(expected, attempts - 1)
    end
  end

  defp wait_for_waiters(expected, 0),
    do: flunk("expected #{expected} repository write waiter(s)")

  defp wait_for_file(path, attempts \\ 200)

  defp wait_for_file(path, attempts) when attempts > 0 do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(5)
      wait_for_file(path, attempts - 1)
    end
  end

  defp wait_for_file(path, 0), do: flunk("expected #{path} to exist")

  defp wait_for_workers(expected, attempts \\ 100)

  defp wait_for_workers(expected, attempts) when attempts > 0 do
    if length(Task.Supervisor.children(GitTransport.ReceivePackWorkerSupervisor)) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_workers(expected, attempts - 1)
    end
  end

  defp wait_for_workers(expected, 0), do: flunk("expected #{expected} receive-pack worker(s)")

  defp wait_for_tracked_workers(expected, attempts \\ 100)

  defp wait_for_tracked_workers(expected, attempts) when attempts > 0 do
    if GitTransport.ReceivePackWorkerManager.tracked_worker_count() == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_tracked_workers(expected, attempts - 1)
    end
  end

  defp wait_for_tracked_workers(expected, 0),
    do: flunk("expected #{expected} manager-tracked receive-pack worker(s)")

  defp wait_for_persisted_workers(expected, attempts \\ 100)

  defp wait_for_persisted_workers(expected, attempts) when attempts > 0 do
    if GitTransport.ReceivePackWorkerManager.persisted_worker_count() == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_persisted_workers(expected, attempts - 1)
    end
  end

  defp wait_for_persisted_workers(expected, 0),
    do: flunk("expected #{expected} persisted receive-pack worker(s)")

  defp wait_for_worker_supervisor_restart(previous, attempts \\ 100)

  defp wait_for_worker_supervisor_restart(previous, attempts) when attempts > 0 do
    case Process.whereis(GitTransport.ReceivePackWorkerSupervisor) do
      pid when is_pid(pid) and pid != previous ->
        :ok

      _other ->
        Process.sleep(5)
        wait_for_worker_supervisor_restart(previous, attempts - 1)
    end
  end

  defp wait_for_worker_supervisor_restart(_previous, 0),
    do: flunk("expected receive-pack worker supervisor to restart")

  defp wait_for_worker_manager_restart(previous, attempts \\ 100)

  defp wait_for_worker_manager_restart(previous, attempts) when attempts > 0 do
    case Process.whereis(GitTransport.ReceivePackWorkerManager) do
      pid when is_pid(pid) and pid != previous ->
        :ok

      _other ->
        Process.sleep(5)
        wait_for_worker_manager_restart(previous, attempts - 1)
    end
  end

  defp wait_for_worker_manager_restart(_previous, 0),
    do: flunk("expected receive-pack worker manager to restart")

  defp safe_resume(supervisor) do
    try do
      :sys.resume(supervisor)
    catch
      :exit, _reason -> :ok
    end
  end

  defp restore_env(application, key, {:ok, value}),
    do: Application.put_env(application, key, value)

  defp restore_env(application, key, :error), do: Application.delete_env(application, key)
end
