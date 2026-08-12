defmodule ForgeReleases.AssetStorage.LocalCASTest do
  use ExUnit.Case, async: true

  alias ForgeReleases.AssetStorage.{Config, FileSystem, LocalCAS}

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

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
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
end
