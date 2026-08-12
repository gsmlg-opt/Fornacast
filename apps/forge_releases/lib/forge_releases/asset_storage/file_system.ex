defmodule ForgeReleases.AssetStorage.FileSystem do
  @moduledoc false

  def mkdir_p(path), do: File.mkdir_p(path)
  def lstat(path), do: File.lstat(path)
  def stat(path), do: File.stat(path)
  def open(path, modes), do: :file.open(String.to_charlist(path), modes)
  def write(io, data), do: :file.write(io, data)
  def sync(io), do: :file.sync(io)
  def close(io), do: :file.close(io)
  def rm(path), do: File.rm(path)
  def ls(path), do: File.ls(path)
  def rmdir(path), do: File.rmdir(path)
  def open_directory(path), do: :file.open(String.to_charlist(path), [:read, :raw, :directory])
  def read_file_info(io), do: :file.read_file_info(io)
  def pread(io, offset, length), do: :file.pread(io, offset, length)

  def filesystem_capacity(path) do
    with {:ok, bytes} <- df_metric(path, "-Pk", :bytes),
         {:ok, inodes} <- df_metric(path, "-Pi", :inodes) do
      {:ok, %{bytes: bytes, inodes: inodes}}
    end
  end

  defp df_metric(path, flag, metric) do
    case System.cmd("df", [flag, path], env: [{"LC_ALL", "C"}], stderr_to_stdout: true) do
      {output, 0} -> parse_df_metric(output, metric)
      {_output, _status} -> {:error, :capacity_unavailable}
    end
  rescue
    _error -> {:error, :capacity_unavailable}
  end

  @doc false
  def parse_df_metric(output, :bytes) do
    with {:ok, headers, fields} <- parse_df_table(output),
         {total_index, unit} <- block_column(headers),
         available_index when is_integer(available_index) <-
           header_index(headers, ["available"]),
         {:ok, total} <- integer_at(fields, total_index),
         {:ok, available} <- integer_at(fields, available_index),
         true <- total >= 0 and available >= 0 and available <= total do
      {:ok, %{total: total * unit, available: available * unit}}
    else
      _invalid -> {:error, :capacity_unavailable}
    end
  end

  def parse_df_metric(output, :inodes) do
    with {:ok, headers, fields} <- parse_df_table(output),
         available_index when is_integer(available_index) <- header_index(headers, ["ifree"]),
         {:ok, available} <- integer_at(fields, available_index),
         {:ok, total} <- inode_total(headers, fields, available),
         true <- total >= 0 and available >= 0 and available <= total do
      {:ok, %{total: total, available: available}}
    else
      _invalid -> {:error, :capacity_unavailable}
    end
  end

  def parse_df_metric(_output, _metric), do: {:error, :capacity_unavailable}

  defp parse_df_table(output) do
    case String.split(output, "\n", trim: true) do
      [header | rows] when rows != [] ->
        headers = String.split(header, ~r/\s+/, trim: true)
        fields = rows |> List.last() |> String.split(~r/\s+/, trim: true)
        {:ok, headers, fields}

      _invalid ->
        {:error, :capacity_unavailable}
    end
  end

  defp block_column(headers) do
    headers
    |> Enum.with_index()
    |> Enum.find_value(fn {header, index} ->
      case String.downcase(header) do
        "1024-blocks" -> {index, 1_024}
        "1k-blocks" -> {index, 1_024}
        "512-blocks" -> {index, 512}
        _other -> nil
      end
    end)
  end

  defp inode_total(headers, fields, available) do
    case header_index(headers, ["inodes"]) do
      index when is_integer(index) ->
        integer_at(fields, index)

      nil ->
        with index when is_integer(index) <- header_index(headers, ["iused"]),
             {:ok, used} <- integer_at(fields, index) do
          {:ok, used + available}
        else
          _invalid -> {:error, :capacity_unavailable}
        end
    end
  end

  defp header_index(headers, names) do
    Enum.find_index(headers, &(String.downcase(&1) in names))
  end

  defp integer_at(fields, index) do
    case Enum.at(fields, index) do
      nil ->
        {:error, :capacity_unavailable}

      value ->
        case Integer.parse(value) do
          {integer, ""} -> {:ok, integer}
          _invalid -> {:error, :capacity_unavailable}
        end
    end
  end
end
