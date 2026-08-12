defmodule ForgeReleases.AssetStorage.LocalCAS do
  @moduledoc false

  alias ForgeReleases.AssetStorage.{Config, FileSystem}

  @spec preflight(Config.t(), module()) :: :ok
  def preflight(%Config{} = config, fs \\ FileSystem) do
    Config.validate!(config)
    roots = [config.root, config.blob_root, config.tmp_root]

    Enum.each(roots, &reject_existing_symlinks!(fs, &1))

    for root <- roots do
      mkdir!(fs, root)
      reject_symlinks!(fs, root)
    end

    assert_same_device!(fs, config.blob_root, config.tmp_root)

    for root <- [config.blob_root, config.tmp_root] do
      probe_write_sync_remove!(fs, root)
    end

    :ok
  end

  defp mkdir!(fs, path) do
    case fs.mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "cannot create storage root #{path}: #{inspect(reason)}"
    end
  end

  defp reject_existing_symlinks!(fs, path) do
    Enum.reduce_while(Path.split(path), "/", fn segment, parent ->
      current = join_component(parent, segment)

      case fs.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} ->
          raise ArgumentError, "storage root contains symlink component: #{current}"

        {:ok, %File.Stat{}} ->
          {:cont, current}

        {:error, :enoent} ->
          {:halt, current}

        {:error, reason} ->
          raise ArgumentError, "cannot inspect storage root #{current}: #{inspect(reason)}"
      end
    end)

    :ok
  end

  defp reject_symlinks!(fs, path) do
    Enum.reduce(Path.split(path), "/", fn segment, parent ->
      current = join_component(parent, segment)

      case fs.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} ->
          raise ArgumentError, "storage root contains symlink component: #{current}"

        {:ok, %File.Stat{}} ->
          current

        {:error, reason} ->
          raise ArgumentError, "cannot inspect storage root #{current}: #{inspect(reason)}"
      end

      current
    end)

    :ok
  end

  defp join_component(_parent, "/"), do: "/"
  defp join_component(parent, segment), do: Path.join(parent, segment)

  defp assert_same_device!(fs, left, right) do
    with {:ok, %File.Stat{major_device: major, minor_device: minor}} <- fs.stat(left),
         {:ok, %File.Stat{major_device: ^major, minor_device: ^minor}} <- fs.stat(right) do
      :ok
    else
      _error -> raise ArgumentError, "CAS and temporary roots must share a filesystem"
    end
  end

  defp probe_write_sync_remove!(fs, root) do
    path = Path.join(root, ".fornacast-write-probe-#{random_suffix()}")

    case fs.open(path, [:write, :raw, :binary, :exclusive]) do
      {:ok, io} ->
        io
        |> run_open_probe(fs, path)
        |> raise_probe_error!(root)

      {:error, reason} ->
        raise_probe_error!({:error, reason}, root)
    end
  end

  defp run_open_probe(io, fs, path) do
    write_sync_result = with :ok <- fs.write(io, <<0>>), do: fs.sync(io)
    close_result = fs.close(io)

    if close_result != :ok do
      _ = fs.close(io)
    end

    remove_result = fs.rm(path)

    case {write_sync_result, close_result, remove_result} do
      {:ok, :ok, :ok} -> :ok
      {{:error, reason}, _, _} -> {:error, reason}
      {_, {:error, reason}, _} -> {:error, reason}
      {_, _, {:error, reason}} -> {:error, reason}
    end
  end

  defp raise_probe_error!(:ok, _root), do: :ok

  defp raise_probe_error!({:error, reason}, root) do
    raise ArgumentError, "storage write probe failed for #{root}: #{inspect(reason)}"
  end

  defp random_suffix do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
