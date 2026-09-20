defmodule ForgeGitHub.LFS.TransferCoordinatorTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.Error
  alias ForgeGitHub.LFS.{Action, Object, TransferCoordinator}
  alias ForgeRepos.Repository
  alias GitLFS.PointerScanner.Scan

  test "import credential gates are preserved for LFS Batch requests" do
    for gate_key <- [{:saved_credential, 21}, {:one_time_run, 34}] do
      [requirement | _] = requirements()

      callbacks =
        callbacks(
          list_requirements: fn _, _ ->
            {:ok, %{objects: [requirement], next_cursor: nil}}
          end,
          batch: fn "import-token", "octocat", "repo", :download, objects, options ->
            assert options[:gate_key] == gate_key
            {:ok, Enum.map(objects, &remote_download/1)}
          end,
          verify_local: fn _, _, _ -> :ok end
        )

      assert {:ok, nil} =
               TransferCoordinator.process_page(
                 repository(),
                 scan(),
                 :inbound,
                 "import-token",
                 "octocat",
                 "repo",
                 nil,
                 gate_key: gate_key,
                 callbacks: callbacks
               )
    end
  end

  test "unrelated and invalid credential gates fail before scan or provider access" do
    parent = self()

    callbacks =
      callbacks(
        list_requirements: fn _, _ ->
          send(parent, :unexpected_scan)
          {:ok, %{objects: [], next_cursor: nil}}
        end,
        batch: fn _, _, _, _, _, _ ->
          send(parent, :unexpected_batch)
          {:error, Error.new(:invalid_request)}
        end
      )

    for gate_key <- [
          {:import_setup, 1},
          {:account_setup, 1},
          {:github_app, 1},
          {:saved_credential, 0},
          {:one_time_run, -1},
          {:github_installation, "1"},
          {:saved_credential, 9_223_372_036_854_775_808}
        ] do
      assert {:error, %Error{kind: :invalid_request}} =
               TransferCoordinator.process_page(
                 repository(),
                 scan(),
                 :inbound,
                 "import-token",
                 "octocat",
                 "repo",
                 nil,
                 gate_key: gate_key,
                 callbacks: callbacks
               )
    end

    refute_received :unexpected_scan
    refute_received :unexpected_batch
  end

  test "inbound proves the remote page before directly staging each missing local object" do
    parent = self()
    [ready, missing] = requirements()
    missing_oid = missing.oid

    callbacks =
      callbacks(
        list_requirements: fn _scan, options ->
          send(parent, {:list, options})
          {:ok, %{objects: [ready, missing], next_cursor: missing.oid}}
        end,
        batch: fn _token, _owner, _repo, operation, objects, options ->
          Process.put(:inbound_batch_proven, true)
          send(parent, {:batch, operation, Enum.map(objects, & &1.oid), options})
          {:ok, Enum.map(objects, &remote_download/1)}
        end,
        verify_local: fn _repo, oid, _size ->
          assert Process.get(:inbound_batch_proven)
          send(parent, {:verify_local, oid})
          if oid == ready.oid, do: :ok, else: {:error, :not_found}
        end,
        ensure_local: fn _repo, oid, _size, first_seen_ref ->
          send(parent, {:ensure_local, oid, first_seen_ref})
          {:error, :not_found}
        end,
        with_upload_lock: fn _repo, oid, fun ->
          send(parent, {:lock, oid})
          fun.()
        end,
        reserve_upload: fn _repo, oid, size ->
          send(parent, {:reserve, oid, size})
          {:ok, {:reservation, oid}}
        end,
        recover_upload: fn reservation ->
          send(parent, {:recover, reservation})
          {:error, :not_found}
        end,
        consume_download: fn _action, object, consumer, _options ->
          send(parent, {:download, object.oid})
          {:ok, staged, :source} = consumer.(:reader, :source)
          {:ok, staged}
        end,
        stage_upload: fn reservation, :reader, :source ->
          send(parent, {:stage, reservation})
          {:ok, {:staged, reservation}, :source}
        end,
        commit_download: fn staged, first_seen_ref ->
          send(parent, {:commit, staged, first_seen_ref})
          {:ok, :object}
        end
      )

    assert {:ok, ^missing_oid} =
             TransferCoordinator.process_page(
               repository(),
               scan(),
               :inbound,
               "installation-token",
               "octocat",
               "repo",
               nil,
               gate_key: {:github_installation, 77},
               callbacks: callbacks
             )

    assert_received {:list, [after_oid: nil, limit: 100]}

    assert_received {:batch, :download, [ready_oid, missing_oid],
                     [gate_key: {:github_installation, 77}]}

    assert ready_oid == ready.oid
    assert missing_oid == missing.oid
    assert_received {:verify_local, ^ready_oid}
    assert_received {:verify_local, ^missing_oid}
    assert_received {:ensure_local, ^missing_oid, "refs/tags/v1.0.0"}
    assert_received {:lock, ^missing_oid}
    assert_received {:download, ^missing_oid}
    assert_received {:stage, {:reservation, ^missing_oid}}
    assert_received {:commit, {:staged, {:reservation, ^missing_oid}}, "refs/tags/v1.0.0"}
  end

  test "inbound remote absence and local corruption stop publication work" do
    [requirement | _rest] = requirements()
    parent = self()

    absent_callbacks =
      callbacks(
        list_requirements: fn _scan, _options ->
          {:ok, %{objects: [requirement], next_cursor: nil}}
        end,
        batch: fn _token, _owner, _repo, :download, _objects, _options ->
          object = remote_download(requirement)
          {:ok, [%{object | actions: %{}, error: Error.new(:object_missing)}]}
        end,
        verify_local: fn _repo, _oid, _size ->
          send(parent, :unexpected_local_access)
          :ok
        end
      )

    assert {:error, %Error{kind: :object_missing}} =
             process(:inbound, absent_callbacks)

    refute_received :unexpected_local_access

    corrupt_callbacks =
      callbacks(
        list_requirements: fn _scan, _options ->
          {:ok, %{objects: [requirement], next_cursor: nil}}
        end,
        batch: fn _token, _owner, _repo, :download, objects, _options ->
          {:ok, Enum.map(objects, &remote_download/1)}
        end,
        verify_local: fn _repo, _oid, _size -> {:error, :integrity_mismatch} end,
        reserve_upload: fn _repo, _oid, _size ->
          send(parent, :unexpected_reservation)
          {:error, :not_found}
        end
      )

    assert {:error, %Error{kind: :integrity_mismatch}} =
             process(:inbound, corrupt_callbacks)

    refute_received :unexpected_reservation
  end

  test "outbound verifies all local objects before Batch and uploads then verifies absences" do
    [present, absent] = requirements()
    parent = self()

    callbacks =
      callbacks(
        list_requirements: fn _scan, _options ->
          {:ok, %{objects: [present, absent], next_cursor: nil}}
        end,
        verify_local: fn _repo, oid, _size ->
          Process.put({:outbound_verified, oid}, true)
          send(parent, {:verify_local, oid})
          :ok
        end,
        batch: fn _token, _owner, _repo, :upload, objects, _options ->
          assert Enum.all?(objects, &Process.get({:outbound_verified, &1.oid}))
          send(parent, {:batch, Enum.map(objects, & &1.oid)})

          {:ok,
           [
             remote_present(present),
             remote_upload(absent, verify?: true)
           ]}
        end,
        open_local: fn _repo, oid, size, :all ->
          send(parent, {:open, oid, size})
          {:ok, {:source, oid}, %{size: size}}
        end,
        upload: fn _action, object, reader, source, _options ->
          send(parent, {:upload, object.oid})
          assert {:ok, "bytes", source} = reader.(5, source)
          assert {:eof, source} = reader.(5, source)
          {:ok, source}
        end,
        read_local: fn
          {:source, oid}, _length ->
            send(parent, {:read, oid})

            case Process.get({:read, oid}, false) do
              false ->
                Process.put({:read, oid}, true)
                {:ok, "bytes", {:source, oid}}

              true ->
                :eof
            end
        end,
        close_local: fn source ->
          send(parent, {:close, source})
          :ok
        end,
        verify_remote: fn _action, object, _options ->
          send(parent, {:verify_remote, object.oid})
          :ok
        end
      )

    assert {:ok, nil} = process(:outbound, callbacks)

    assert_received {:verify_local, present_oid}
    assert_received {:verify_local, absent_oid}
    assert present_oid == present.oid
    assert absent_oid == absent.oid
    assert_received {:batch, [^present_oid, ^absent_oid]}
    assert_received {:open, ^absent_oid, 20}
    assert_received {:upload, ^absent_oid}
    assert_received {:close, {:source, ^absent_oid}}
    assert_received {:verify_remote, ^absent_oid}
  end

  test "outbound does not adopt globally shared bytes without repository authorization" do
    [requirement | _] = requirements()
    parent = self()

    callbacks =
      callbacks(
        list_requirements: fn _scan, _opts ->
          {:ok, %{objects: [requirement], next_cursor: nil}}
        end,
        verify_local: fn _repo, _oid, _size -> {:error, :not_found} end,
        ensure_local: fn _repo, _oid, _size, _ref ->
          send(parent, :unauthorized_global_adoption)
          :ok
        end
      )

    assert {:error, %Error{kind: :object_missing}} = process(:outbound, callbacks)
    refute_received :unauthorized_global_adoption
  end

  test "converge sends ready objects outbound and missing objects inbound" do
    [ready, missing] = requirements()
    parent = self()

    callbacks =
      callbacks(
        list_requirements: fn _scan, _options ->
          {:ok, %{objects: [ready, missing], next_cursor: nil}}
        end,
        verify_local: fn _repo, oid, _size ->
          send(parent, {:verify_local, oid})
          if oid == ready.oid, do: :ok, else: {:error, :not_found}
        end,
        ensure_local: fn _repo, _oid, _size, _ref ->
          assert Process.get(:converge_remote_proven)
          {:error, :not_found}
        end,
        batch: fn _token, _owner, _repo, operation, objects, _options ->
          if operation == :download, do: Process.put(:converge_remote_proven, true)
          send(parent, {:batch, operation, Enum.map(objects, & &1.oid)})

          case operation do
            :upload -> {:ok, Enum.map(objects, &remote_present/1)}
            :download -> {:ok, Enum.map(objects, &remote_download/1)}
          end
        end,
        with_upload_lock: fn _repo, _oid, fun -> fun.() end,
        reserve_upload: fn _repo, oid, _size -> {:ok, {:reservation, oid}} end,
        recover_upload: fn _reservation -> {:error, :not_found} end,
        consume_download: fn _action, _object, consumer, _options ->
          {:ok, staged, :source} = consumer.(:reader, :source)
          {:ok, staged}
        end,
        stage_upload: fn reservation, :reader, :source ->
          {:ok, {:staged, reservation}, :source}
        end,
        commit_download: fn _staged, _ref -> {:ok, :object} end
      )

    assert {:ok, nil} = process(:converge, callbacks)
    assert_received {:batch, :upload, [ready_oid]}
    assert_received {:batch, :download, [missing_oid]}
    assert ready_oid == ready.oid
    assert missing_oid == missing.oid
  end

  test "refreshes Batch exactly once when an action expires" do
    [requirement | _rest] = requirements()
    counter = :counters.new(1, [])

    callbacks =
      callbacks(
        list_requirements: fn _scan, _options ->
          {:ok, %{objects: [requirement], next_cursor: nil}}
        end,
        batch: fn _token, _owner, _repo, :download, objects, _options ->
          :counters.add(counter, 1, 1)
          {:ok, Enum.map(objects, &remote_download/1)}
        end,
        verify_local: fn _repo, _oid, _size -> {:error, :not_found} end,
        ensure_local: fn _repo, _oid, _size, _ref -> {:error, :not_found} end,
        with_upload_lock: fn _repo, _oid, fun -> fun.() end,
        reserve_upload: fn _repo, oid, _size -> {:ok, {:reservation, oid}} end,
        recover_upload: fn _reservation -> {:error, :not_found} end,
        consume_download: fn _action, _object, consumer, _options ->
          if :counters.get(counter, 1) == 1 do
            {:error, Error.new(:action_expired)}
          else
            {:ok, staged, :source} = consumer.(:reader, :source)
            {:ok, staged}
          end
        end,
        stage_upload: fn reservation, :reader, :source ->
          {:ok, {:staged, reservation}, :source}
        end,
        commit_download: fn _staged, _ref -> {:ok, :object} end
      )

    assert {:ok, nil} = process(:inbound, callbacks)
    assert :counters.get(counter, 1) == 2

    always_expired =
      Map.put(callbacks, :consume_download, fn _action, _object, _consumer, _options ->
        {:error, Error.new(:action_expired)}
      end)

    :counters.put(counter, 1, 0)

    assert {:error, %Error{kind: :action_expired}} =
             process(:inbound, always_expired)

    assert :counters.get(counter, 1) == 2
  end

  for revoke_at <- [:batch, :upload] do
    test "revocation after #{revoke_at} prevents further uploads and verification" do
      revoke_at = revocation_stage(unquote(revoke_at))
      parent = self()

      callbacks =
        callbacks(
          list_requirements: fn _, _ -> {:ok, %{objects: requirements(), next_cursor: nil}} end,
          verify_local: fn _, _, _ -> :ok end,
          batch: fn _, _, _, :upload, objects, _ ->
            if revoke_at == :batch, do: Process.put(:revoked, true)
            {:ok, Enum.map(objects, &remote_upload(&1, verify?: true))}
          end,
          open_local: fn _, oid, size, _ -> {:ok, oid, %{size: size}} end,
          upload: fn _, object, _, source, _ ->
            send(parent, {:uploaded, object.oid})
            Process.put(:revoked, true)
            {:ok, source}
          end,
          close_local: fn _ -> :ok end,
          verify_remote: fn _, _, _ ->
            send(parent, :verified)
            :ok
          end
        )

      assert {:error, :lease_expired} =
               process(:outbound, callbacks,
                 authorize: fn ->
                   if Process.get(:revoked), do: {:error, :lease_expired}, else: :ok
                 end
               )

      if revoke_at == :upload, do: assert_received({:uploaded, _})
      refute_received {:uploaded, _}
      refute_received :verified
    end
  end

  defp revocation_stage(stage), do: stage

  test "revocation while opening the local source closes it without uploading" do
    parent = self()

    callbacks =
      callbacks(
        list_requirements: fn _, _ -> {:ok, %{objects: requirements(), next_cursor: nil}} end,
        verify_local: fn _, _, _ -> :ok end,
        batch: fn _, _, _, _, objects, _ ->
          {:ok, Enum.map(objects, &remote_upload(&1, verify?: true))}
        end,
        open_local: fn _, oid, size, _ ->
          Process.put(:revoked, true)
          {:ok, oid, %{size: size}}
        end,
        close_local: fn oid ->
          send(parent, {:closed, oid})
          :ok
        end
      )

    assert {:error, :lease_expired} =
             process(:outbound, callbacks,
               authorize: fn ->
                 if Process.get(:revoked), do: {:error, :lease_expired}, else: :ok
               end
             )

    assert_received {:closed, _}
  end

  test "invalid or crashing authority fails closed before Batch" do
    for authorize <- [
          nil,
          :absent,
          fn -> true end,
          fn -> raise "revoked" end,
          fn -> throw(:revoked) end
        ] do
      assert {:error, :invalid_authorization} =
               process(:outbound, callbacks([]), authorize: authorize)
    end
  end

  defp process(direction, callbacks, options \\ []) do
    TransferCoordinator.process_page(
      repository(),
      scan(),
      direction,
      "installation-token",
      "octocat",
      "repo",
      nil,
      [gate_key: {:github_installation, 77}, callbacks: callbacks] ++ options
    )
  end

  defp requirements do
    [
      %{oid: String.duplicate("a", 64), size: 10, first_seen_ref: "refs/heads/main"},
      %{oid: String.duplicate("b", 64), size: 20, first_seen_ref: "refs/tags/v1.0.0"}
    ]
  end

  defp remote_download(requirement) do
    %Object{
      oid: requirement.oid,
      size: requirement.size,
      authenticated: true,
      actions: %{download: action(:download)},
      error: nil
    }
  end

  defp remote_present(requirement) do
    %Object{
      oid: requirement.oid,
      size: requirement.size,
      authenticated: true,
      actions: %{},
      error: nil
    }
  end

  defp remote_upload(requirement, options) do
    actions = %{upload: action(:upload)}
    actions = if options[:verify?], do: Map.put(actions, :verify, action(:verify)), else: actions

    %Object{
      oid: requirement.oid,
      size: requirement.size,
      authenticated: true,
      actions: actions,
      error: nil
    }
  end

  defp action(operation) do
    Action.new!(operation, "https://objects.example.test/object", %{}, nil)
  end

  defp repository, do: struct!(Repository, id: 1, generation: 1)

  defp scan do
    struct!(Scan,
      id: 1,
      repository_id: 1,
      repository_generation: 1,
      state: :complete,
      batch_limit: 100
    )
  end

  defp callbacks(overrides) do
    defaults = %{
      list_requirements: fn _scan, _options -> flunk("unexpected list_requirements") end,
      batch: fn _token, _owner, _repo, _operation, _objects, _options ->
        flunk("unexpected batch")
      end,
      verify_local: fn _repo, _oid, _size -> flunk("unexpected verify_local") end,
      ensure_local: fn _repo, _oid, _size, _ref -> flunk("unexpected ensure_local") end,
      with_upload_lock: fn _repo, _oid, _fun -> flunk("unexpected with_upload_lock") end,
      reserve_upload: fn _repo, _oid, _size -> flunk("unexpected reserve_upload") end,
      recover_upload: fn _reservation -> flunk("unexpected recover_upload") end,
      cleanup_upload: fn _reservation -> flunk("unexpected cleanup_upload") end,
      consume_download: fn _action, _object, _consumer, _options ->
        flunk("unexpected consume_download")
      end,
      stage_upload: fn _reservation, _reader, _source -> flunk("unexpected stage_upload") end,
      commit_download: fn _staged, _ref -> flunk("unexpected commit_download") end,
      open_local: fn _repo, _oid, _size, _range -> flunk("unexpected open_local") end,
      read_local: fn _source, _length -> flunk("unexpected read_local") end,
      close_local: fn _source -> flunk("unexpected close_local") end,
      upload: fn _action, _object, _reader, _source, _options -> flunk("unexpected upload") end,
      verify_remote: fn _action, _object, _options -> flunk("unexpected verify_remote") end
    }

    Map.merge(defaults, Map.new(overrides))
  end
end
