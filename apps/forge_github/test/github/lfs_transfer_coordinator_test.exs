defmodule ForgeGitHub.LFS.TransferCoordinatorTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.Error
  alias ForgeGitHub.LFS.{Action, Object, TransferCoordinator}
  alias ForgeRepos.Repository
  alias GitLFS.PointerScanner.Scan

  test "public inbound LFS normalizes the shared gate and rejects remote writes" do
    [requirement | _] = requirements()
    parent = self()

    callbacks =
      callbacks(
        list_requirements: fn _, _ ->
          {:ok, %{objects: [requirement], next_cursor: nil}}
        end,
        batch: fn :public, "octocat", "repo", :download, objects, options ->
          assert options[:gate_key] == {:public, 1}
          send(parent, :public_batch)
          {:ok, Enum.map(objects, &remote_download/1)}
        end,
        verify_local: fn _, _, _ -> :ok end
      )

    assert {:ok, nil} =
             TransferCoordinator.process_page(
               repository(),
               scan(),
               :inbound,
               :public,
               "octocat",
               "repo",
               nil,
               gate_key: {:one_time_run, 91},
               callbacks: callbacks
             )

    assert_received :public_batch

    for direction <- [:outbound, :converge] do
      assert {:error, %Error{kind: :invalid_request}} =
               TransferCoordinator.process_page(
                 repository(),
                 scan(),
                 direction,
                 :public,
                 "octocat",
                 "repo",
                 nil,
                 gate_key: {:public, 1},
                 callbacks: callbacks
               )
    end

    refute_received :public_batch
  end

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
        stage_upload: fn reservation, staging_reader, :source ->
          assert is_function(staging_reader, 2)
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

  @tag :tmp_dir
  test "inbound adapts download chunks and EOF to the CAS staging reader", %{tmp_dir: tmp_dir} do
    for {chunks, index} <-
          Enum.with_index([["pay", "load"], [], [String.duplicate("a", 70_000), "tail"]]) do
      payload = Enum.join(chunks)
      oid = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
      requirement = %{oid: oid, size: byte_size(payload), first_seen_ref: "refs/heads/main"}
      committed = make_ref()

      reader = fn state, options ->
        if Keyword.keys(options) -- [:length, :read_timeout] != [] do
          {:error, :invalid_source, state}
        else
          case state do
            [chunk | rest] -> {:ok, chunk, rest}
            [] -> {:eof, []}
          end
        end
      end

      callbacks =
        callbacks(
          list_requirements: fn _, _ -> {:ok, %{objects: [requirement], next_cursor: nil}} end,
          batch: fn _, _, _, :download, objects, _ ->
            {:ok, Enum.map(objects, &remote_download/1)}
          end,
          verify_local: fn _, _, _ ->
            if Process.get(committed), do: :ok, else: {:error, :not_found}
          end,
          ensure_local: fn _, _, _, _ -> {:error, :not_found} end,
          with_upload_lock: fn _, _, fun -> fun.() end,
          reserve_upload: fn _, _, _ -> {:ok, :reservation} end,
          recover_upload: fn _ -> {:error, :not_found} end,
          consume_download: fn _, _, consumer, _ ->
            case consumer.(reader, chunks) do
              {:ok, staged, []} -> {:ok, staged}
              {:error, reason, _} -> {:error, Error.new(:sink), reason}
            end
          end,
          stage_upload: fn :reservation, adapted_reader, state ->
            ExStorageService.BlobStore.LocalCAS.stage_from_reader(
              fn source ->
                adapted_reader.(source,
                  length: 1_048_576,
                  read_length: 65_536,
                  read_timeout: 1_000
                )
              end,
              state,
              tmp_dir: Path.join(tmp_dir, Integer.to_string(index)),
              max_size: max(byte_size(payload), 1)
            )
          end,
          commit_download: fn staged, "refs/heads/main" ->
            assert File.read!(staged.path) == payload
            assert staged.hash == oid
            assert staged.size == byte_size(payload)
            Process.put(committed, true)
            {:ok, :object}
          end
        )

      assert {:ok, nil} =
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
    end
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

  @tag :tmp_dir
  test "outbound preserves raw blob ownership across the real transport worker", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    payload = String.duplicate("outbound-lfs", 17_000)
    path = Path.join(tmp_dir, "payload")
    File.write!(path, payload)
    oid = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    requirement = %{oid: oid, size: byte_size(payload), first_seen_ref: "refs/heads/main"}

    callbacks =
      callbacks(
        list_requirements: fn _, _ -> {:ok, %{objects: [requirement], next_cursor: nil}} end,
        verify_local: fn _, ^oid, _ -> :ok end,
        batch: fn _, _, _, :upload, _, _ -> {:ok, [remote_upload(requirement, [])]} end,
        open_local: fn _, ^oid, size, :all ->
          {:ok, io} = :file.open(String.to_charlist(path), [:read, :raw, :binary])
          send(parent, {:source_opened, self()})
          source = %ForgeBlobs.Source{io: io, offset: 0, position: 0, remaining: size}
          {:ok, source, %{size: size}}
        end,
        read_local: fn source, length ->
          send(parent, {:source_read, self()})
          GitLFS.read(source, length)
        end,
        close_local: fn source ->
          send(parent, {:source_closed, self()})
          GitLFS.close(source)
        end,
        upload: fn upload_action, object, reader, source, _ ->
          ForgeGitHub.LFS.upload(upload_action, object, reader, source,
            resolver: fn _ -> {:ok, [{203, 0, 114, 10}]} end,
            transport_api: __MODULE__.RawSourceMint
          )
        end
      )

    assert {:ok, nil} = process(:outbound, callbacks)
    assert_received {:source_opened, owner}
    assert_received {:source_read, ^owner}
    assert_received {:source_closed, ^owner}
    assert_received {:raw_upload_bytes, uploaded}
    assert uploaded == payload
    refute_received {:raw_upload_bytes, _}
  end

  @tag :tmp_dir
  test "outbound timeout stops a blocked raw-source owner", %{tmp_dir: tmp_dir} do
    parent = self()
    callbacks = blocked_raw_source_callbacks(tmp_dir, parent, 50)

    assert {:error, %Error{kind: :timeout}} = process(:outbound, callbacks)
    assert_received {:source_opened, owner}
    refute Process.alive?(owner)
    assert_received {:raw_transport_started, transport}
    refute Process.alive?(transport)
  end

  @tag :tmp_dir
  test "caller death stops a blocked raw-source owner and its upload", %{tmp_dir: tmp_dir} do
    parent = self()
    callbacks = blocked_raw_source_callbacks(tmp_dir, parent, 20_000)

    caller =
      spawn(fn ->
        Process.put(:"$callers", [parent])
        process(:outbound, callbacks)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:source_opened, owner}, 2_000
    assert_receive {:raw_transport_started, transport}, 2_000
    assert_receive :source_read_blocked, 2_000
    owner_monitor = Process.monitor(owner)
    transport_monitor = Process.monitor(transport)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 2_000
    assert_receive {:DOWN, ^transport_monitor, :process, ^transport, _}, 2_000
  end

  test "an expired upload action gets a fresh source owner before retry" do
    parent = self()
    [requirement | _] = requirements()
    attempts = :counters.new(1, [:atomics])

    callbacks =
      callbacks(
        list_requirements: fn _, _ -> {:ok, %{objects: [requirement], next_cursor: nil}} end,
        verify_local: fn _, _, _ -> :ok end,
        batch: fn _, _, _, _, _, _ -> {:ok, [remote_upload(requirement, [])]} end,
        open_local: fn _, oid, size, _ ->
          send(parent, {:retry_source_opened, self()})
          {:ok, oid, %{size: size}}
        end,
        close_local: fn _source ->
          send(parent, {:retry_source_closed, self()})
          :ok
        end,
        upload: fn _, _, _, source, _ ->
          :counters.add(attempts, 1, 1)

          if :counters.get(attempts, 1) == 1,
            do: {:error, Error.new(:action_expired), source},
            else: {:ok, source}
        end
      )

    assert {:ok, nil} = process(:outbound, callbacks)
    assert_received {:retry_source_opened, first}
    assert_received {:retry_source_closed, ^first}
    assert_received {:retry_source_opened, second}
    assert_received {:retry_source_closed, ^second}
    assert first != second
    refute Process.alive?(first)
    refute Process.alive?(second)
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
        stage_upload: fn reservation, staging_reader, :source ->
          assert is_function(staging_reader, 2)
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
        stage_upload: fn reservation, staging_reader, :source ->
          assert is_function(staging_reader, 2)
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
    revoked = :counters.new(1, [:atomics])

    callbacks =
      callbacks(
        list_requirements: fn _, _ -> {:ok, %{objects: requirements(), next_cursor: nil}} end,
        verify_local: fn _, _, _ -> :ok end,
        batch: fn _, _, _, _, objects, _ ->
          {:ok, Enum.map(objects, &remote_upload(&1, verify?: true))}
        end,
        open_local: fn _, oid, size, _ ->
          :counters.put(revoked, 1, 1)
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
                 if :counters.get(revoked, 1) == 1, do: {:error, :lease_expired}, else: :ok
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

  defp blocked_raw_source_callbacks(tmp_dir, parent, timeout) do
    path = Path.join(tmp_dir, "blocked-payload")
    File.write!(path, "bytes")
    oid = :crypto.hash(:sha256, "bytes") |> Base.encode16(case: :lower)
    requirement = %{oid: oid, size: 5, first_seen_ref: "refs/heads/main"}

    callbacks(
      list_requirements: fn _, _ -> {:ok, %{objects: [requirement], next_cursor: nil}} end,
      verify_local: fn _, _, _ -> :ok end,
      batch: fn _, _, _, _, _, _ -> {:ok, [remote_upload(requirement, [])]} end,
      open_local: fn _, _, size, _ ->
        {:ok, io} = :file.open(String.to_charlist(path), [:read, :raw, :binary])
        send(parent, {:source_opened, self()})
        {:ok, %ForgeBlobs.Source{io: io, offset: 0, position: 0, remaining: size}, %{size: size}}
      end,
      read_local: fn _source, _length ->
        send(parent, :source_read_blocked)

        receive do
          :release_reader -> :eof
        end
      end,
      close_local: &GitLFS.close/1,
      upload: fn upload_action, object, reader, source, _ ->
        ForgeGitHub.LFS.upload(upload_action, object, reader, source,
          resolver: fn _ -> {:ok, [{203, 0, 114, 10}]} end,
          transport_api: __MODULE__.RawSourceMint,
          request_timeout: timeout
        )
      end
    )
  end

  defmodule RawSourceMint do
    def connect(_scheme, _address, _port, _options) do
      owner = Process.get(:"$callers") |> List.last()
      send(owner, {:raw_transport_started, self()})
      {:ok, %{owner: owner, ref: nil, bytes: ""}}
    end

    def request(state, "PUT", _target, _headers, :stream) do
      ref = make_ref()
      {:ok, %{state | ref: ref}, ref}
    end

    def stream_request_body(state, _ref, :eof) do
      send(state.owner, {:raw_upload_bytes, state.bytes})
      {:ok, state}
    end

    def stream_request_body(state, _ref, bytes),
      do: {:ok, %{state | bytes: state.bytes <> bytes}}

    def recv(state, 0, _timeout),
      do:
        {:ok, state,
         [
           {:status, state.ref, 200},
           {:headers, state.ref, [{"content-length", "0"}]},
           {:done, state.ref}
         ]}

    def close(state), do: {:ok, state}
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
