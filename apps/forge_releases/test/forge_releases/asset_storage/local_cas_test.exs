defmodule ForgeReleases.AssetStorage.LocalCASTest do
  use ExUnit.Case, async: false

  alias ExStorageService.BlobStore.StagedBlob
  alias ForgeReleases.AssetStorage.{Config, FileSystem, LocalCAS, Source, StagedRef}

  defmodule CapacityFailureFS do
    def filesystem_capacity(_path), do: {:error, :eio}
  end

  defmodule FstatObserverFS do
    defdelegate open(path, modes), to: FileSystem
    defdelegate read_file_info(io), to: FileSystem

    def close(io) do
      notify_close(io)
      FileSystem.close(io)
    end

    def notify_close(io) do
      send(Process.get(:asset_storage_test_observer), {:fs_close, io})
    end
  end

  defmodule FstatFailureFS do
    defdelegate open(path, modes), to: FileSystem
    def read_file_info(_io), do: {:error, :eio}

    def close(io) do
      FstatObserverFS.notify_close(io)
      FileSystem.close(io)
    end
  end

  defmodule FstatTypeMismatchFS do
    defdelegate open(path, modes), to: FileSystem

    def read_file_info(io) do
      with {:ok, info} <- FileSystem.read_file_info(io) do
        {:ok, put_elem(info, 2, :directory)}
      end
    end

    def close(io) do
      FstatObserverFS.notify_close(io)
      FileSystem.close(io)
    end
  end

  defmodule FstatSizeMismatchFS do
    defdelegate open(path, modes), to: FileSystem

    def read_file_info(io) do
      with {:ok, info} <- FileSystem.read_file_info(io) do
        {:ok, put_elem(info, 1, elem(info, 1) + 1)}
      end
    end

    def close(io) do
      FstatObserverFS.notify_close(io)
      FileSystem.close(io)
    end
  end

  defmodule DurabilityFS do
    defdelegate lstat(path), to: FileSystem
    defdelegate ls(path), to: FileSystem
    defdelegate rm(path), to: FileSystem
    defdelegate rmdir(path), to: FileSystem

    def reset do
      Process.put(:durability_sync_order, [])
      Process.put(:durability_failure, nil)
      Process.put(:durability_directories, %{})
      :ok
    end

    def fail_once(point) when point in [:staging_directory_sync, :uploads_directory_sync] do
      Process.put(:durability_failure, point)
      :ok
    end

    def sync_order do
      :durability_sync_order
      |> Process.get([])
      |> Enum.reverse()
    end

    def open_directory(path) do
      case FileSystem.open_directory(path) do
        {:ok, io} = result ->
          kind = if Path.basename(path) == "uploads", do: :uploads, else: :staging

          Process.put(
            :durability_directories,
            Map.put(Process.get(:durability_directories, %{}), io, kind)
          )

          result

        error ->
          error
      end
    end

    def sync(io) do
      kind = Map.fetch!(Process.get(:durability_directories, %{}), io)
      Process.put(:durability_sync_order, [kind | Process.get(:durability_sync_order, [])])

      failure =
        case kind do
          :staging -> :staging_directory_sync
          :uploads -> :uploads_directory_sync
        end

      if Process.get(:durability_failure) == failure do
        Process.put(:durability_failure, nil)
        {:error, :eio}
      else
        FileSystem.sync(io)
      end
    end

    def close(io) do
      Process.put(
        :durability_directories,
        Map.delete(Process.get(:durability_directories, %{}), io)
      )

      FileSystem.close(io)
    end
  end

  defmodule SyncFailureFS do
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate stat(path), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(io, data), to: FileSystem
    defdelegate close(io), to: FileSystem
    defdelegate rm(path), to: FileSystem
    def sync(_io), do: {:error, :eio}
  end

  defmodule WriteFailureFS do
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate stat(path), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate sync(io), to: FileSystem
    defdelegate close(io), to: FileSystem
    defdelegate rm(path), to: FileSystem
    def write(_io, _data), do: {:error, :enospc}
  end

  defmodule CloseFailureFS do
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate stat(path), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(io, data), to: FileSystem
    defdelegate sync(io), to: FileSystem
    defdelegate rm(path), to: FileSystem

    def close(io) do
      _ = FileSystem.close(io)
      {:error, :eio}
    end
  end

  defmodule DeviceMismatchFS do
    defdelegate mkdir_p(path), to: FileSystem
    defdelegate lstat(path), to: FileSystem
    defdelegate open(path, modes), to: FileSystem
    defdelegate write(io, data), to: FileSystem
    defdelegate sync(io), to: FileSystem
    defdelegate close(io), to: FileSystem
    defdelegate rm(path), to: FileSystem

    def stat(path) do
      with {:ok, stat} <- FileSystem.stat(path) do
        if Path.basename(path) == "tmp" do
          {:ok, %{stat | minor_device: stat.minor_device + 1}}
        else
          {:ok, stat}
        end
      end
    end
  end

  setup do
    root =
      Path.join(
        Path.expand("../../../../../tmp/test/localcas-preflight", __DIR__),
        "fornacast-localcas-#{System.unique_integer([:positive, :monotonic])}"
      )

    config = Config.load!()
    key = "survivor-#{System.unique_integer([:positive, :monotonic])}"
    directory = Path.join([config.tmp_root, "uploads", key])

    File.mkdir_p!(directory)
    Process.put(:asset_storage_test_observer, self())
    DurabilityFS.reset()

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(directory)
    end)

    %{root: root, key: key, directory: directory}
  end

  test "loads the exact validated ESS context" do
    config = Config.load!()

    assert config.root == Fornacast.Config.release_asset_storage_root()
    assert config.instance_config.instance == :fornacast_release_assets
    assert config.context.blob_root == config.blob_root
    assert config.context.tmp_root == config.tmp_root
    assert config.max_bytes == Fornacast.Config.release_asset_max_bytes()
  end

  test "preflight writes, syncs, closes, and removes contained probes", %{root: root} do
    config = Config.for_root!(root, max_bytes: 1_024, gc_grace_seconds: 3_600)

    assert :ok = LocalCAS.preflight(config)
    assert File.ls!(config.blob_root) == []
    assert File.ls!(config.tmp_root) == []
  end

  test "preflight cleans up probes when write, sync, or close fails", %{root: root} do
    for {fs, reason} <- [
          {WriteFailureFS, :enospc},
          {SyncFailureFS, :eio},
          {CloseFailureFS, :eio}
        ] do
      case_root = Path.join(root, Atom.to_string(fs))
      config = Config.for_root!(case_root, max_bytes: 1_024, gc_grace_seconds: 3_600)

      assert_raise ArgumentError, ~r/storage write probe failed.*#{reason}/, fn ->
        LocalCAS.preflight(config, fs)
      end

      assert Path.wildcard(Path.join(config.blob_root, ".fornacast-write-probe-*")) == []
      assert Path.wildcard(Path.join(config.tmp_root, ".fornacast-write-probe-*")) == []
    end
  end

  test "configuration rejects roots outside the storage root", %{root: root} do
    assert_raise ArgumentError, ~r/blob_root must be contained/, fn ->
      Config.validate!(%Config{
        root: root,
        data_root: root,
        blob_root: Path.join(Path.dirname(root), "outside"),
        tmp_root: Path.join(root, "tmp"),
        ra_root: Path.join(root, "ra"),
        metadata_root: Path.join(root, "concord"),
        max_bytes: 1_024,
        gc_grace_seconds: 3_600
      })
    end
  end

  test "configuration rejects relative and non-canonical child roots", %{root: root} do
    config = Config.for_root!(root, max_bytes: 1_024, gc_grace_seconds: 3_600)

    assert_raise ArgumentError, ~r/blob_root must be an absolute normalized path/, fn ->
      config
      |> Map.put(:blob_root, "cas")
      |> Config.validate!()
    end

    assert_raise ArgumentError, ~r/tmp_root must be an absolute normalized path/, fn ->
      config
      |> Map.put(:tmp_root, Path.join([root, "tmp", "..", "tmp"]))
      |> Config.validate!()
    end
  end

  test "preflight rejects symlinked root components", %{root: root} do
    target = Path.join(root, "target")
    link = Path.join(root, "linked-cas")
    File.mkdir_p!(target)
    File.ln_s!(target, link)

    config =
      root
      |> Config.for_root!(max_bytes: 1_024, gc_grace_seconds: 3_600)
      |> Map.put(:blob_root, link)

    assert_raise ArgumentError, ~r/symlink/, fn -> LocalCAS.preflight(config) end
  end

  test "preflight rejects an intermediate symlink before creating outside it", %{root: root} do
    target = Path.join(root, "target")
    link = Path.join(root, "linked")
    File.mkdir_p!(target)
    File.ln_s!(target, link)

    config =
      Config.for_root!(
        Path.join(link, "must-not-be-created"),
        max_bytes: 1_024,
        gc_grace_seconds: 3_600
      )

    assert_raise ArgumentError, ~r/symlink/, fn -> LocalCAS.preflight(config) end
    refute File.exists?(Path.join(target, "must-not-be-created"))
  end

  test "preflight rejects cross-device publication", %{root: root} do
    config = Config.for_root!(root, max_bytes: 1_024, gc_grace_seconds: 3_600)

    assert_raise ArgumentError, ~r/must share a filesystem/, fn ->
      LocalCAS.preflight(config, DeviceMismatchFS)
    end
  end

  test "capacity parser accepts GNU and macOS df layouts" do
    gnu_bytes = """
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/root 1000 750 250 75% /
    """

    gnu_inodes = """
    Filesystem Inodes IUsed IFree IUse% Mounted on
    /dev/root 1000 600 400 60% /
    """

    macos_bytes = """
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk3s1 2000 500 1500 25% /
    """

    macos_inodes = """
    Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on
    /dev/disk3s1 2000 500 1500 25% 20 180 10% /
    """

    assert {:ok, %{total: 1_024_000, available: 256_000}} =
             FileSystem.parse_df_metric(gnu_bytes, :bytes)

    assert {:ok, %{total: 1_000, available: 400}} =
             FileSystem.parse_df_metric(gnu_inodes, :inodes)

    assert {:ok, %{total: 2_048_000, available: 1_536_000}} =
             FileSystem.parse_df_metric(macos_bytes, :bytes)

    assert {:ok, %{total: 200, available: 180}} =
             FileSystem.parse_df_metric(macos_inodes, :inodes)
  end

  describe "opaque adapter contract" do
    test "capacity reports only bounded byte and inode counts" do
      assert {:ok, capacity} = ForgeReleases.AssetStorage.capacity()

      for area <- [:cas, :staging] do
        assert %{bytes: bytes, inodes: inodes} = Map.fetch!(capacity, area)
        assert bytes.total >= bytes.available and bytes.available >= 0
        assert inodes.total >= inodes.available and inodes.available >= 0
      end

      refute inspect(capacity) =~ Config.load!().root
      assert {:error, :unavailable} = LocalCAS.capacity(CapacityFailureFS)
    end

    test "stage, commit, stat, ranged fd reads, verify, and delete", %{key: key} do
      assert ForgeReleases.AssetStorage.ready?()

      reader = fn
        %{chunks: [chunk | rest]} = state, read_options ->
          assert read_options[:length] <= 1_048_576
          {:more, chunk, %{state | chunks: rest}}

        %{chunks: []} = state, _read_options ->
          {:done, state}
      end

      state = %{chunks: ["forna", "cast"]}

      assert {:ok, staged, metadata, final_state} =
               ForgeReleases.AssetStorage.stage_from_reader(key, reader, state,
                 read_options: [length: 262_144, read_length: 262_144, read_timeout: 1_000]
               )

      digest = :crypto.hash(:sha256, "fornacast") |> Base.encode16(case: :lower)
      assert metadata == %{sha256_digest: digest, storage_key: digest, size: 9}
      assert final_state == %{chunks: []}
      assert inspect(staged) == "#ForgeReleases.AssetStorage.StagedRef<redacted>"

      assert {:ok, ^metadata} = ForgeReleases.AssetStorage.commit(staged)
      assert {:ok, %{storage_key: ^digest, size: 9}} = ForgeReleases.AssetStorage.stat(digest)
      assert :ok = ForgeReleases.AssetStorage.verify(digest)

      assert {:ok, source} = ForgeReleases.AssetStorage.open(digest, 9, {2, 5})
      assert inspect(source) == "#ForgeReleases.AssetStorage.Source<redacted>"
      assert {:ok, "rn", source} = ForgeReleases.AssetStorage.read(source, 2)
      assert {:ok, "aca", source} = ForgeReleases.AssetStorage.read(source, 10)
      assert :eof = ForgeReleases.AssetStorage.read(source, 1)
      assert :ok = ForgeReleases.AssetStorage.close(source)
      assert :ok = ForgeReleases.AssetStorage.close(source)

      assert :ok = ForgeReleases.AssetStorage.delete(digest)
      assert {:error, :not_found} = ForgeReleases.AssetStorage.stat(digest)
    end

    test "open owns an fd and validates the recorded size", %{key: key} do
      reader = fn state, _options -> {:ok, "descriptor", state} end

      assert {:ok, staged, %{storage_key: digest}, :state} =
               ForgeReleases.AssetStorage.stage_from_reader(key, reader, :state,
                 read_options: [length: 32, read_length: 32, read_timeout: 1_000]
               )

      assert {:ok, _metadata} = ForgeReleases.AssetStorage.commit(staged)

      assert {:error, :integrity_mismatch} =
               ForgeReleases.AssetStorage.open(digest, 99, :all)

      assert {:ok, source} = ForgeReleases.AssetStorage.open(digest, 10, :all)

      assert :ok = ForgeReleases.AssetStorage.delete(digest)
      assert {:ok, "descriptor", source} = ForgeReleases.AssetStorage.read(source, 1_048_577)
      assert :eof = ForgeReleases.AssetStorage.read(source, 1)
      assert :ok = ForgeReleases.AssetStorage.close(source)
    end

    test "reads clamp each fd operation to one MiB", %{key: key} do
      payload = :binary.copy("x", 1_048_576) <> "y"

      reader = fn
        [chunk | rest], _options -> {:more, chunk, rest}
        [], _options -> {:done, []}
      end

      assert {:ok, staged, %{storage_key: digest}, []} =
               ForgeReleases.AssetStorage.stage_from_reader(
                 key,
                 reader,
                 [:binary.copy("x", 1_048_576), "y"],
                 read_options: [
                   length: 1_048_576,
                   read_length: 1_048_576,
                   read_timeout: 1_000
                 ]
               )

      assert {:ok, _metadata} = ForgeReleases.AssetStorage.commit(staged)
      assert {:ok, source} = ForgeReleases.AssetStorage.open(digest, byte_size(payload), :all)
      assert {:ok, first, source} = ForgeReleases.AssetStorage.read(source, 2_097_152)
      assert byte_size(first) == 1_048_576
      assert {:ok, "y", source} = ForgeReleases.AssetStorage.read(source, 2_097_152)
      assert :eof = ForgeReleases.AssetStorage.read(source, 1)
      assert :ok = ForgeReleases.AssetStorage.close(source)
      assert :ok = ForgeReleases.AssetStorage.delete(digest)
    end

    test "effective lower maximum and caller input are enforced", %{key: key} do
      reader = fn state, _options -> {:ok, "four", state + 1} end

      assert {:error, :entity_too_large, 1} =
               ForgeReleases.AssetStorage.stage_from_reader(key, reader, 0,
                 max_size: 3,
                 read_options: [length: 3, read_length: 3, read_timeout: 1_000]
               )

      assert {:error, :invalid_source, 0} =
               ForgeReleases.AssetStorage.stage_from_reader("../escape", reader, 0,
                 read_options: [length: 3, read_length: 3, read_timeout: 1_000]
               )

      uppercase = String.duplicate("A", 64)
      assert {:error, :invalid_source} = ForgeReleases.AssetStorage.stat(uppercase)
      assert {:error, :invalid_source} = ForgeReleases.AssetStorage.open(uppercase, 1, :all)
    end

    test "reader ceilings are enforced and the latest classified state is retained", %{key: key} do
      oversized = fn state, options ->
        assert options[:length] <= 1_048_576
        assert options[:read_length] <= options[:length]
        assert options[:read_timeout] <= 30_000
        next = %{state | calls: state.calls + 1, reader_error: :reader}
        {:more, :binary.copy(<<0>>, options[:length] + 1), next}
      end

      initial = %{calls: 0, reader_error: nil}

      assert {:error, :invalid_source, %{calls: 1, reader_error: :reader}} =
               ForgeReleases.AssetStorage.stage_from_reader(key, oversized, initial,
                 read_options: [length: 8, read_length: 4, read_timeout: 30_000]
               )

      for classification <- [:timeout, :lost_lease] do
        reader = fn state, _options ->
          next = %{state | calls: state.calls + 1, reader_error: classification}
          {:error, :deadline, next}
        end

        assert {:error, _normalized, %{calls: 1, reader_error: ^classification}} =
                 ForgeReleases.AssetStorage.stage_from_reader(
                   "#{key}-#{classification}",
                   reader,
                   initial,
                   read_options: [length: 8, read_length: 4, read_timeout: 30_000]
                 )
      end

      assert {:error, :invalid_source, ^initial} =
               ForgeReleases.AssetStorage.stage_from_reader(
                 "#{key}-timeout",
                 oversized,
                 initial,
                 read_options: [length: 8, read_length: 4, read_timeout: 30_001]
               )
    end

    test "raw ESS and filesystem errors collapse to the storage algebra" do
      assert LocalCAS.normalize(:stat, :not_found) == :not_found
      assert LocalCAS.normalize(:stage, :entity_too_large) == :entity_too_large
      assert LocalCAS.normalize(:commit, {:directory_sync, :eio}) == :ambiguous_commit
      assert LocalCAS.normalize(:recover, :stage_changed) == :integrity_mismatch
      assert LocalCAS.normalize(:recover, {:verify, :unexpected_eof}) == :integrity_mismatch
      assert LocalCAS.normalize(:recover, :not_regular_file) == :invalid_source

      assert LocalCAS.normalize(:commit, {:commit, :existing_blob_mismatch}) ==
               :integrity_mismatch

      assert LocalCAS.normalize(:verify, :checksum_mismatch) == :integrity_mismatch
      assert LocalCAS.normalize(:open, :invalid_range) == :invalid_source
      assert LocalCAS.normalize(:delete, {:delete, :eacces}) == :unavailable
    end

    test "forged staged handles are rejected before commit or discard" do
      config = Config.load!()
      digest = String.duplicate("a", 64)
      stage_directory = Path.join([config.tmp_root, "uploads", "forged-handle"])

      options =
        config.context
        |> ExStorageService.Context.direct_blob_store_options()
        |> Keyword.merge(tmp_dir: stage_directory, max_size: 1)

      valid = %{
        inner: %StagedBlob{
          path: Path.join(stage_directory, "upload-1"),
          hash: digest,
          etag: nil,
          size: 1
        },
        options: options,
        storage_key: digest,
        size: 1
      }

      malformed = [
        %{valid | inner: nil},
        %{valid | inner: %{valid.inner | path: nil}},
        %{valid | inner: %{valid.inner | hash: String.duplicate("A", 64)}},
        %{valid | inner: %{valid.inner | hash: String.duplicate("b", 64)}},
        %{valid | inner: %{valid.inner | size: 2}},
        %{valid | inner: %{valid.inner | etag: {:unsafe, :etag}}},
        %{valid | options: :not_a_keyword},
        %{valid | storage_key: String.duplicate("A", 64)},
        %{valid | size: -1}
      ]

      for fields <- malformed do
        staged = struct!(StagedRef, fields)
        assert {:error, :invalid_source} = ForgeReleases.AssetStorage.commit(staged)
        assert {:error, :invalid_source} = ForgeReleases.AssetStorage.discard(staged)
      end

      injected =
        struct!(StagedRef, %{
          valid
          | options: [fs_module: :bogus]
        })

      assert {:error, :invalid_source} = ForgeReleases.AssetStorage.commit(injected)
      assert {:error, :invalid_source} = ForgeReleases.AssetStorage.discard(injected)
    end

    test "forged source handles cannot crash read arithmetic" do
      malformed = [
        %{io: nil, offset: 0, position: 0, remaining: 1},
        %{io: {:fake_descriptor}, offset: nil, position: 0, remaining: 1},
        %{io: {:fake_descriptor}, offset: 0, position: "zero", remaining: 1},
        %{io: {:fake_descriptor}, offset: 0, position: 0, remaining: -1},
        %{io: nil, offset: nil, position: nil, remaining: 0}
      ]

      for fields <- malformed do
        source = struct!(Source, fields)
        assert {:error, :invalid_source} = ForgeReleases.AssetStorage.read(source, 1)
        assert :ok = ForgeReleases.AssetStorage.close(source)
      end

      plausible =
        struct!(Source,
          io: {:file_descriptor, :bogus, %{}},
          offset: 0,
          position: 0,
          remaining: 1
        )

      assert {:error, :unavailable} = ForgeReleases.AssetStorage.read(plausible, 1)
      assert :ok = ForgeReleases.AssetStorage.close(plausible)
    end

    test "failed finish-open paths close exactly once", context do
      digest = publish_blob!(context, "descriptor")

      for {fs, range, error} <- [
            {FstatFailureFS, :all, :unavailable},
            {FstatTypeMismatchFS, :all, :integrity_mismatch},
            {FstatSizeMismatchFS, :all, :integrity_mismatch},
            {FstatObserverFS, {11, 0}, :invalid_source}
          ] do
        assert {:error, ^error} = LocalCAS.open(digest, 10, range, fs)
        assert_receive {:fs_close, _io}
        refute_receive {:fs_close, _io}
      end
    end
  end

  describe "staged survivor recovery boundary" do
    test "recovers one direct regular survivor and cleans it without recursion", context do
      path = Path.join(context.directory, "upload-1")
      File.write!(path, "survivor")
      digest = :crypto.hash(:sha256, "survivor") |> Base.encode16(case: :lower)

      assert {:ok, staged} = ForgeReleases.AssetStorage.recover_stage(context.key, digest, 8)
      assert inspect(staged) == "#ForgeReleases.AssetStorage.StagedRef<redacted>"

      assert {:ok, %{sha256_digest: ^digest, storage_key: ^digest, size: 8}} =
               ForgeReleases.AssetStorage.commit(staged)

      assert :ok = ForgeReleases.AssetStorage.cleanup_staging(context.key)
      refute File.exists?(context.directory)
      assert :ok = ForgeReleases.AssetStorage.cleanup_staging(context.key)
    end

    test "rejects missing, symlinked, nested, multiple, size, and digest mismatches", context do
      assert :ok = ForgeReleases.AssetStorage.cleanup_staging(context.key)

      assert {:error, :not_found} =
               ForgeReleases.AssetStorage.recover_stage(
                 context.key,
                 String.duplicate("a", 64),
                 1
               )

      File.mkdir_p!(context.directory)
      File.write!(Path.join(context.directory, "one"), "a")
      File.write!(Path.join(context.directory, "two"), "b")

      assert {:error, :invalid_source} =
               ForgeReleases.AssetStorage.recover_stage(
                 context.key,
                 String.duplicate("a", 64),
                 1
               )

      File.rm_rf!(context.directory)
      File.mkdir_p!(Path.join(context.directory, "nested"))

      assert {:error, :invalid_source} =
               ForgeReleases.AssetStorage.recover_stage(
                 context.key,
                 String.duplicate("a", 64),
                 1
               )

      File.rm_rf!(context.directory)
      File.mkdir_p!(context.directory)
      target = Path.join(context.directory, "target")
      File.write!(target, "a")
      File.ln_s!(target, Path.join(context.directory, "link"))
      File.rm!(target)

      assert {:error, :invalid_source} =
               ForgeReleases.AssetStorage.recover_stage(
                 context.key,
                 String.duplicate("a", 64),
                 1
               )

      File.rm_rf!(context.directory)
      File.mkdir_p!(context.directory)
      File.write!(Path.join(context.directory, "one"), "short")

      assert {:error, :integrity_mismatch} =
               ForgeReleases.AssetStorage.recover_stage(
                 context.key,
                 String.duplicate("a", 64),
                 99
               )

      assert {:error, :integrity_mismatch} =
               ForgeReleases.AssetStorage.recover_stage(
                 context.key,
                 String.duplicate("a", 64),
                 5
               )
    end

    test "effective configured cap applies to survivors", context do
      previous = Application.fetch_env!(:fornacast, :release_asset_max_bytes)
      Application.put_env(:fornacast, :release_asset_max_bytes, 4)

      on_exit(fn ->
        Application.put_env(:fornacast, :release_asset_max_bytes, previous)
      end)

      File.write!(Path.join(context.directory, "upload-1"), "12345")

      assert {:error, :entity_too_large} =
               ForgeReleases.AssetStorage.recover_stage(
                 context.key,
                 String.duplicate("a", 64),
                 5
               )
    end

    test "cleanup refuses a symlinked staging directory without touching its target", context do
      File.rm_rf!(context.directory)

      target =
        Path.join(System.tmp_dir!(), "cleanup-target-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target)
      File.write!(Path.join(target, "keep"), "kept")
      File.ln_s!(target, context.directory)
      on_exit(fn -> File.rm_rf!(target) end)

      assert {:error, :invalid_source} =
               ForgeReleases.AssetStorage.cleanup_staging(context.key)

      assert File.read!(Path.join(target, "keep")) == "kept"
    end

    test "cleanup durably retries after each namespace sync point", context do
      write_single_survivor!(context)
      DurabilityFS.fail_once(:staging_directory_sync)

      assert {:error, :unavailable} =
               LocalCAS.cleanup_staging(context.key, DurabilityFS)

      refute File.exists?(Path.join(context.directory, "upload-1"))
      assert File.dir?(context.directory)

      assert :ok = LocalCAS.cleanup_staging(context.key, DurabilityFS)
      refute File.exists?(context.directory)
      assert DurabilityFS.sync_order() == [:staging, :staging, :uploads]

      write_single_survivor!(context)
      DurabilityFS.fail_once(:uploads_directory_sync)

      assert {:error, :unavailable} =
               LocalCAS.cleanup_staging(context.key, DurabilityFS)

      refute File.exists?(context.directory)

      DurabilityFS.fail_once(:uploads_directory_sync)

      assert {:error, :unavailable} =
               LocalCAS.cleanup_staging(context.key, DurabilityFS)

      assert :ok = LocalCAS.cleanup_staging(context.key, DurabilityFS)
      assert List.ends_with?(DurabilityFS.sync_order(), [:uploads, :uploads, :uploads])
    end
  end

  defp publish_blob!(context, contents) do
    reader = fn state, _options -> {:ok, contents, state} end

    assert {:ok, staged, %{storage_key: digest}, :state} =
             ForgeReleases.AssetStorage.stage_from_reader(context.key, reader, :state,
               read_options: [length: 32, read_length: 32, read_timeout: 1_000]
             )

    assert {:ok, _metadata} = ForgeReleases.AssetStorage.commit(staged)
    digest
  end

  defp write_single_survivor!(context) do
    File.mkdir_p!(context.directory)
    File.write!(Path.join(context.directory, "upload-1"), "survivor")
  end
end
