defmodule ForgeGitHub.LFSSyncTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.LFSSync
  alias ForgeMirrors.MirrorOperation
  alias ForgeRepos.Repository
  alias GitCore.Ref
  alias GitLFS.PointerScanner.{Scan, WorkItem}

  @old String.duplicate("1", 40)
  @target String.duplicate("2", 40)
  @tag_oid String.duplicate("3", 40)

  test "inbound gate only transfers its target and does not require unpushed local refs on GitHub" do
    parent = self()

    options =
      callbacks(
        begin_scan: fn repository, scan_key, baselines, batch_limit: 100 ->
          assert repository.id == 10
          send(parent, {:baselines, baselines})
          {:ok, scan(scan_key, :complete)}
        end,
        transfer_page: fn repository,
                          scan,
                          :inbound,
                          "installation-secret",
                          "acme",
                          "project",
                          nil,
                          gate_key: {:github_installation, 44} ->
          assert repository.id == 10
          assert scan.state == :complete
          send(parent, :transferred)
          {:ok, nil}
        end,
        publish_scan: fn scan ->
          assert_received :transferred
          send(parent, :published)
          {:ok, %{scan | state: :published}}
        end
      )

    assert :ok =
             LFSSync.ensure(
               operation(),
               sync(),
               :inbound,
               @target,
               "installation-secret",
               %{},
               options
             )

    assert_received {:baselines,
                     [
                       %{ref_kind: :branch, ref_name: "refs/heads/main", oid: @target}
                     ]}

    assert_received :published
  end

  test "one durable object expansion yields a bounded credential-free checkpoint" do
    parent = self()
    work = %WorkItem{object_oid: @target, object_kind: :commit, tree_offset: 0}
    scanning = scan("scan-key", :scanning)

    options =
      callbacks(
        begin_scan: fn _repository, _scan_key, _baselines, _options -> {:ok, scanning} end,
        claim_work: fn ^scanning, "git-ref-lfs:7:1", limit: 1, lease_seconds: 300 ->
          {:ok, [work]}
        end,
        expand_object: fn "/repos/example.git", @target, :commit, 0, 100 ->
          send(parent, :expanded)

          {:ok, %{object_kind: :commit, children: [], candidate: nil, next_offset: nil}}
        end,
        record_expansion: fn ^work, "git-ref-lfs:7:1", expansion ->
          assert expansion.object_kind == :commit
          {:ok, %{work_item: work, scan: scanning}}
        end,
        transfer_page: fn _repo, _scan, _direction, _token, _owner, _remote, _cursor, _opts ->
          flunk("transfer must wait for scan completion")
        end
      )

    assert {:incomplete, checkpoint} =
             LFSSync.ensure(
               operation(),
               sync(),
               :outbound,
               @target,
               "installation-secret",
               %{},
               options
             )

    assert_received :expanded
    assert checkpoint["phase"] == "scan"
    assert checkpoint["scan_key"] == "scan-key"
    refute inspect(checkpoint) =~ "installation-secret"
    refute inspect(checkpoint) =~ "https://"
  end

  test "a deletion scans the future ref set without the deleted ref" do
    parent = self()

    options =
      callbacks(
        begin_scan: fn _repository, scan_key, baselines, _options ->
          send(parent, {:baselines, baselines})
          {:ok, scan(scan_key, :complete)}
        end,
        transfer_page: fn _repo, _scan, :outbound, _token, _owner, _remote, nil, _options ->
          {:ok, nil}
        end,
        publish_scan: fn scan -> {:ok, %{scan | state: :published}} end
      )

    assert :ok =
             LFSSync.ensure(
               operation(),
               sync(),
               :outbound,
               nil,
               "installation-secret",
               %{},
               options
             )

    assert_received {:baselines, baselines}
    refute Enum.any?(baselines, &(&1.ref_name == "refs/heads/main"))
  end

  test "published multi-page replay resets the cursor and rejects corruption on page one" do
    initial =
      callbacks(
        begin_scan: fn _repository, key, _baselines, _options ->
          {:ok, scan(key, :complete)}
        end,
        transfer_page: fn _repository, _scan, _direction, _token, _owner, _remote, nil, _opts ->
          {:ok, String.duplicate("a", 64)}
        end,
        publish_scan: fn _scan -> flunk("corrupt objects must prevent publication") end
      )

    assert {:incomplete, tail_checkpoint} =
             LFSSync.ensure(operation(), sync(), :inbound, @target, "token", %{}, initial)

    replay =
      Keyword.put(initial, :begin_scan, fn _repository, key, _baselines, _options ->
        {:ok, scan(key, :published)}
      end)

    operation = %{operation() | state: :effect_pending, checkpoint: tail_checkpoint}

    assert {:incomplete, restart} =
             LFSSync.ensure(operation, sync(), :inbound, @target, "token", %{}, replay)

    assert restart["requirement_cursor"] == nil
    refute restart["scan_key"] == tail_checkpoint["scan_key"]

    restarted =
      Keyword.put(initial, :transfer_page, fn
        _repository, _scan, :inbound, _token, _owner, _remote, nil, _opts ->
          {:error, ForgeGitHub.Error.new(:integrity_mismatch)}
      end)

    assert {:error, %ForgeGitHub.Error{kind: :integrity_mismatch}} =
             LFSSync.ensure(
               %{operation | checkpoint: restart},
               sync(),
               :inbound,
               @target,
               "token",
               %{},
               restarted
             )
  end

  test "a superseded publication restarts under a new durable scan identity" do
    options =
      callbacks(
        begin_scan: fn _repository, scan_key, _baselines, _options ->
          {:ok, scan(scan_key, :complete)}
        end,
        transfer_page: fn _repo, _scan, _direction, _token, _owner, _remote, nil, _options ->
          {:ok, nil}
        end,
        publish_scan: fn _scan -> {:error, :superseded} end
      )

    assert {:incomplete, checkpoint} =
             LFSSync.ensure(
               operation(),
               sync(),
               :converge,
               @target,
               "installation-secret",
               %{},
               options
             )

    assert checkpoint["phase"] == "scan"
    assert String.ends_with?(checkpoint["scan_key"], ":r91")
  end

  test "authority expired during bounded expansion stops recording and transfer" do
    work = %WorkItem{object_oid: @target, object_kind: :commit, tree_offset: 0}

    options =
      callbacks(
        authorize: fn -> if Process.get(:expired), do: {:error, :lease_expired}, else: :ok end,
        begin_scan: fn _, key, _, _ -> {:ok, scan(key, :scanning)} end,
        claim_work: fn _, _, _ -> {:ok, [work]} end,
        expand_object: fn _, _, _, _, _ ->
          Process.put(:expired, true)
          {:ok, %{object_kind: :commit, children: [], candidate: nil, next_offset: nil}}
        end,
        record_expansion: fn _, _, _ -> flunk("expired scan must stop") end,
        transfer_page: fn _, _, _, _, _, _, _, _ -> flunk("expired scan must not transfer") end
      )

    assert {:error, :lease_expired} =
             LFSSync.ensure(operation(), sync(), :outbound, @target, "token", %{}, options)
  end

  test "trusted authority callback is forwarded to transfer only as runtime options" do
    authorize = fn -> :ok end

    options =
      callbacks(
        authorize: authorize,
        begin_scan: fn _, key, _, _ -> {:ok, scan(key, :complete)} end,
        transfer_page: fn _, _, _, _, _, _, _, options ->
          assert options[:authorize] == authorize
          {:ok, nil}
        end,
        publish_scan: fn scan -> {:ok, %{scan | state: :prepared}} end
      )

    assert :ok = LFSSync.ensure(operation(), sync(), :outbound, @target, "token", %{}, options)
  end

  defp operation do
    %MirrorOperation{id: 7, attempt_count: 1, state: :processing, checkpoint: %{}}
  end

  defp sync do
    %{
      github_installation_id: 44,
      ref_kind: :branch,
      ref_name: "refs/heads/main",
      remote_owner: "acme",
      remote_repository: "project",
      repository_generation: 2,
      repository_id: 10,
      repository_path: "/repos/example.git"
    }
  end

  defp callbacks(overrides) do
    defaults = [
      fetch_repository: fn 10 -> {:ok, %Repository{id: 10, generation: 2}} end,
      list_refs: fn "/repos/example.git" ->
        {:ok,
         [
           %Ref{name: "refs/heads/main", kind: :branch, target: @old},
           %Ref{name: "refs/heads/feature", kind: :branch, target: @old},
           %Ref{name: "refs/tags/v1", kind: :tag, target: @tag_oid},
           %Ref{name: "refs/fornacast/private", kind: :legacy, target: @old}
         ]}
      end,
      resume_scan: fn _repository, _scan_key -> flunk("unexpected scan resume") end,
      claim_work: fn _scan, _owner, _options -> flunk("unexpected work claim") end,
      expand_object: fn _path, _oid, _kind, _offset, _limit ->
        flunk("unexpected object expansion")
      end,
      record_expansion: fn _work, _owner, _expansion ->
        flunk("unexpected expansion record")
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp scan(scan_key, state) do
    %Scan{
      id: 91,
      repository_id: 10,
      repository_generation: 2,
      scan_key: scan_key,
      baseline_fingerprint: String.duplicate("a", 64),
      state: state,
      batch_limit: 100
    }
  end
end
