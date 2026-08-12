defmodule ForgeReleases.AssetStorage.LocalCASContractTest do
  use ExUnit.Case, async: true

  alias ExStorageService.BlobStore.LocalCAS

  defmodule RecordingDeleteFS do
    def rm(path) do
      record(:rm)
      File.rm(path)
    end

    def open_directory(path) do
      record(:open_directory)
      :file.open(String.to_charlist(path), [:read, :raw, :directory])
    end

    def sync(io) do
      record(:sync)

      if Process.get(:fail_delete_sync_once, false) do
        Process.put(:fail_delete_sync_once, false)
        {:error, :injected}
      else
        :file.sync(io)
      end
    end

    def close(io) do
      record(:close)
      :file.close(io)
    end

    defp record(call),
      do: Process.put(:delete_fs_calls, [call | Process.get(:delete_fs_calls, [])])
  end

  setup do
    root = Path.join(System.tmp_dir!(), "ess-contract-#{System.unique_integer([:positive])}")
    tmp_dir = Path.join(root, "tmp")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, tmp_dir: tmp_dir}
  end

  test "abrupt staging death leaves at most one bounded regular survivor", context do
    parent = self()
    config = ForgeReleases.AssetStorage.Config.load!()

    options =
      config.context
      |> ExStorageService.Context.direct_blob_store_options()
      |> Keyword.merge(root: context.root, tmp_dir: context.tmp_dir, max_size: 16)

    {pid, monitor} =
      spawn_monitor(fn ->
        LocalCAS.stage_from_reader(
          fn state ->
            send(parent, {:reader_entered, self()})

            receive do
              {:continue, chunk} -> {:ok, chunk, state}
            end
          end,
          :reader_state,
          options
        )
      end)

    assert_receive {:reader_entered, ^pid}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    survivors = Path.wildcard(Path.join(context.tmp_dir, "*"))
    assert length(survivors) <= 1

    for survivor <- survivors do
      assert {:ok, %File.Stat{type: :regular, size: size}} = File.lstat(survivor)
      assert size <= 16
      assert Path.dirname(survivor) == context.tmp_dir
    end
  end

  test "direct options and recover_stage publish a caller-owned completed stage", context do
    config = ForgeReleases.AssetStorage.Config.load!()

    options =
      config.context
      |> ExStorageService.Context.direct_blob_store_options()
      |> Keyword.merge(root: context.root, tmp_dir: context.tmp_dir, max_size: 16)

    assert options[:pack_module] == nil
    refute Keyword.has_key?(options, :bucket)

    payload = "recovered-stage"
    digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    assert {:ok, completed_stage} = LocalCAS.stage(payload, options)
    stage_path = completed_stage.path
    assert Path.dirname(stage_path) == context.tmp_dir
    assert {:ok, %File.Stat{type: :regular, size: 15}} = File.lstat(stage_path)

    assert {:ok, staged} = LocalCAS.recover_stage(stage_path, digest, byte_size(payload), options)
    assert {:ok, %{hash: ^digest, size: 15}} = LocalCAS.commit(staged, options)
    assert :ok = LocalCAS.verify(digest, options)
    refute File.exists?(stage_path)
  end

  test "delete syncs its directory and safely retries an ambiguous sync", context do
    payload = "durable-delete-contract"
    digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    config = ForgeReleases.AssetStorage.Config.load!()

    options =
      config.context
      |> ExStorageService.Context.direct_blob_store_options()
      |> Keyword.merge(root: context.root, tmp_dir: context.tmp_dir)

    path = LocalCAS.blob_path(digest, options)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, payload)
    Process.put(:delete_fs_calls, [])
    Process.put(:fail_delete_sync_once, true)

    assert {:error, {:directory_sync, :injected}} =
             LocalCAS.delete(
               digest,
               Keyword.put(options, :fs_module, RecordingDeleteFS)
             )

    refute File.exists?(path)

    assert Process.get(:delete_fs_calls) |> Enum.reverse() ==
             [:rm, :open_directory, :sync, :close]

    Process.put(:delete_fs_calls, [])

    assert :ok =
             LocalCAS.delete(
               digest,
               Keyword.put(options, :fs_module, RecordingDeleteFS)
             )

    assert Process.delete(:delete_fs_calls) |> Enum.reverse() ==
             [:rm, :open_directory, :sync, :close]

    assert {:error, :not_found} = LocalCAS.stat(digest, options)
  end
end
