defmodule ForgeReleases.AssetStorage.LocalCAS do
  @moduledoc false

  @behaviour ForgeReleases.AssetStorage

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias ExStorageService.BlobStore.LocalCAS, as: ESSLocalCAS
  alias ExStorageService.BlobStore.StagedBlob
  alias ForgeReleases.AssetStorage.{Config, FileSystem, Manager, Source, StagedRef}

  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @etag_regex ~r/\A[0-9a-f]{32}\z/
  @staging_key_regex ~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/
  @maximum_file_offset 9_223_372_036_854_775_807
  @maximum_read_bytes 1_048_576
  @stage_option_keys [:max_size, :read_options]

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

  @impl true
  def capacity, do: capacity(FileSystem)

  @doc false
  def capacity(fs) when is_atom(fs) do
    with {:ok, config} <- ready_config(),
         {:ok, cas} <- fs.filesystem_capacity(config.blob_root),
         {:ok, staging} <- fs.filesystem_capacity(config.tmp_root) do
      {:ok, %{cas: cas, staging: staging}}
    else
      _reason -> {:error, :unavailable}
    end
  end

  @impl true
  def stage_from_reader(staging_key, reader, state, options)
      when is_function(reader, 2) and is_list(options) do
    with :ok <- validate_staging_key(staging_key),
         {:ok, config} <- ready_config(),
         {:ok, cas_options, read_options} <- stage_options(config, staging_key, options) do
      wrapped_reader = fn reader_state ->
        reader_state
        |> reader.(read_options)
        |> enforce_reader_chunk(read_options[:length], cas_options[:max_size])
      end

      # ExStorageService's reader contract is pinned exactly at 0.6.4.
      case ESSLocalCAS.stage_from_reader(wrapped_reader, state, cas_options) do
        {:ok, staged, final_state} ->
          ref = %StagedRef{
            inner: staged,
            options: cas_options,
            storage_key: staged.hash,
            size: staged.size
          }

          {:ok, ref, metadata(staged.hash, staged.size), final_state}

        {:error, reason, final_state} ->
          {:error, normalize(:stage, reason), final_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def stage_from_reader(_staging_key, _reader, state, _options),
    do: {:error, :invalid_source, state}

  @impl true
  def commit(%StagedRef{} = staged) do
    with {:ok, config} <- ready_config(),
         :ok <- validate_staged_ref(staged, config) do
      case ESSLocalCAS.commit(staged.inner, staged.options) do
        {:ok, ready} when ready.hash == staged.storage_key and ready.size == staged.size ->
          {:ok, metadata(staged.storage_key, staged.size)}

        {:ok, _mismatch} ->
          {:error, :integrity_mismatch}

        {:error, reason} ->
          {:error, normalize(:commit, reason)}
      end
    end
  end

  def commit(_staged), do: {:error, :invalid_source}

  @impl true
  def discard(%StagedRef{} = staged) do
    with {:ok, config} <- ready_config(),
         :ok <- validate_staged_ref(staged, config) do
      case ESSLocalCAS.discard(staged.inner, staged.options) do
        :ok -> :ok
        {:error, reason} -> {:error, normalize(:discard, reason)}
      end
    end
  end

  def discard(_staged), do: {:error, :invalid_source}

  @impl true
  def stat(storage_key) do
    with :ok <- validate_digest(storage_key),
         {:ok, config} <- ready_config() do
      case ESSLocalCAS.stat(storage_key, blob_options(config)) do
        {:ok, %{hash: ^storage_key, size: size}} ->
          {:ok, %{storage_key: storage_key, size: size}}

        {:ok, _mismatch} ->
          {:error, :integrity_mismatch}

        {:error, reason} ->
          {:error, normalize(:stat, reason)}
      end
    end
  end

  @impl true
  def verify(storage_key) do
    with :ok <- validate_digest(storage_key),
         {:ok, config} <- ready_config() do
      case ESSLocalCAS.verify(storage_key, blob_options(config)) do
        :ok -> :ok
        {:error, reason} -> {:error, normalize(:verify, reason)}
      end
    end
  end

  @impl true
  def delete(storage_key) do
    with :ok <- validate_digest(storage_key),
         {:ok, config} <- ready_config() do
      case ESSLocalCAS.delete(storage_key, blob_options(config)) do
        :ok -> :ok
        {:error, reason} -> {:error, normalize(:delete, reason)}
      end
    end
  end

  @impl true
  def open(storage_key, expected_size, range)
      when is_integer(expected_size) and expected_size >= 0,
      do: open(storage_key, expected_size, range, FileSystem)

  def open(_storage_key, _expected_size, _range), do: {:error, :invalid_source}

  @doc false
  def open(storage_key, expected_size, range, fs)
      when is_integer(expected_size) and expected_size >= 0 and is_atom(fs) do
    with :ok <- validate_digest(storage_key),
         {:ok, config} <- ready_config(),
         {:ok, {:file, path, 0, ^expected_size}} <-
           ESSLocalCAS.open(storage_key, nil, blob_options(config)),
         {:ok, io} <- fs.open(path, [:read, :raw, :binary]) do
      finish_open(fs, io, expected_size, range)
    else
      {:ok, {:file, _path, _offset, _actual_size}} -> {:error, :integrity_mismatch}
      {:error, reason} -> {:error, normalize(:open, reason)}
      _other -> {:error, :integrity_mismatch}
    end
  end

  @impl true
  def recover_stage(staging_key, expected_digest, expected_size)
      when is_integer(expected_size) and expected_size >= 0 do
    with :ok <- validate_staging_key(staging_key),
         :ok <- validate_digest(expected_digest),
         {:ok, config} <- ready_config(),
         :ok <- enforce_survivor_cap(expected_size, config.max_bytes),
         {:ok, path} <- locate_single_survivor(FileSystem, config, staging_key, expected_size),
         options = recover_options(config, staging_key),
         # ExStorageService recovery is pinned exactly at 0.6.4.
         {:ok, staged} <-
           ESSLocalCAS.recover_stage(path, expected_digest, expected_size, options) do
      {:ok,
       %StagedRef{
         inner: staged,
         options: options,
         storage_key: expected_digest,
         size: expected_size
       }}
    else
      {:error, reason} -> {:error, normalize(:recover, reason)}
    end
  end

  def recover_stage(_staging_key, _expected_digest, _expected_size),
    do: {:error, :invalid_source}

  @impl true
  def cleanup_staging(staging_key), do: cleanup_staging(staging_key, FileSystem)

  @doc false
  def cleanup_staging(staging_key, fs) when is_atom(fs) do
    with :ok <- validate_staging_key(staging_key),
         {:ok, config} <- ready_config() do
      uploads_directory = Path.join(config.tmp_root, "uploads")
      staging_directory = Path.join(uploads_directory, staging_key)

      cleanup_single_survivor(fs, uploads_directory, staging_directory)
    end
  end

  @impl true
  def read(%Source{} = source, requested_bytes)
      when is_integer(requested_bytes) and requested_bytes > 0 do
    with :ok <- validate_source(source) do
      read_valid_source(source, requested_bytes)
    end
  end

  def read(_source, _requested_bytes), do: {:error, :invalid_source}

  defp read_valid_source(%Source{remaining: 0}, _requested_bytes), do: :eof

  defp read_valid_source(%Source{} = source, requested_bytes) do
    length = min(source.remaining, min(requested_bytes, @maximum_read_bytes))

    case safe_pread(source.io, source.offset + source.position, length) do
      {:ok, bytes} when byte_size(bytes) == length ->
        {:ok, bytes,
         %{source | position: source.position + length, remaining: source.remaining - length}}

      {:ok, _short} ->
        {:error, :integrity_mismatch}

      :eof ->
        {:error, :integrity_mismatch}

      {:error, _reason} ->
        {:error, :unavailable}

      _unexpected ->
        {:error, :unavailable}
    end
  end

  @impl true
  def close(%Source{io: io}) do
    _ = safe_close(io)
    :ok
  end

  def close(_source), do: :ok

  @doc false
  def normalize(_operation, :not_found), do: :not_found

  def normalize(_operation, reason)
      when reason in [:entity_too_large, :invalid_source, :integrity_mismatch, :unavailable],
      do: reason

  def normalize(:commit, {:directory_sync, _reason}), do: :ambiguous_commit

  def normalize(:recover, reason)
      when reason in [:checksum_mismatch, :size_mismatch, :stage_changed],
      do: :integrity_mismatch

  def normalize(:recover, {:verify, :unexpected_eof}), do: :integrity_mismatch

  def normalize(:recover, reason)
      when reason in [:invalid_hash, :invalid_size, :invalid_stage_path, :not_regular_file],
      do: :invalid_source

  def normalize(_operation, reason)
      when reason in [:checksum_mismatch, :unexpected_eof],
      do: :integrity_mismatch

  def normalize(_operation, {phase, reason})
      when phase in [:commit, :verify] and
             reason in [:existing_blob_mismatch, :unexpected_eof],
      do: :integrity_mismatch

  def normalize(_operation, reason)
      when reason in [:invalid_hash, :invalid_range, :invalid_max_size],
      do: :invalid_source

  def normalize(:stage, {:invalid_reader_result, _result}), do: :invalid_source
  def normalize(:stage, {:stage, :invalid_chunk}), do: :invalid_source
  def normalize(:stage, {:reader, _reason}), do: :invalid_source
  def normalize(_operation, _reason), do: :unavailable

  defp ready_config do
    case Manager.status() do
      :ready ->
        try do
          {:ok, Config.load!()}
        rescue
          _error -> {:error, :unavailable}
        end

      {:not_ready, _reason} ->
        {:error, :unavailable}
    end
  end

  defp validate_digest(storage_key) when is_binary(storage_key) do
    if Regex.match?(@digest_regex, storage_key),
      do: :ok,
      else: {:error, :invalid_source}
  end

  defp validate_digest(_storage_key), do: {:error, :invalid_source}

  defp validate_staging_key(key) when is_binary(key) do
    if Regex.match?(@staging_key_regex, key),
      do: :ok,
      else: {:error, :invalid_source}
  end

  defp validate_staging_key(_key), do: {:error, :invalid_source}

  defp validate_staged_ref(
         %StagedRef{
           inner: %StagedBlob{
             path: path,
             hash: inner_hash,
             etag: etag,
             size: inner_size
           },
           options: options,
           storage_key: storage_key,
           size: size
         },
         %Config{} = config
       ) do
    uploads_root = Path.join(config.tmp_root, "uploads")

    with true <- is_binary(path) and path != "" and Path.type(path) == :absolute,
         true <- Path.expand(path) == path,
         stage_directory = Path.dirname(path),
         true <- Path.dirname(stage_directory) == uploads_root,
         :ok <- validate_staging_key(Path.basename(stage_directory)),
         :ok <- validate_digest(storage_key),
         true <- inner_hash == storage_key,
         true <- is_integer(size) and size >= 0,
         true <- inner_size == size,
         true <- valid_etag?(etag),
         :ok <- validate_staged_options(options, config, stage_directory) do
      :ok
    else
      _invalid -> {:error, :invalid_source}
    end
  end

  defp validate_staged_ref(%StagedRef{}, %Config{}), do: {:error, :invalid_source}

  defp validate_staged_options(options, %Config{} = config, stage_directory) do
    expected_keys = [:data_root, :max_size, :pack_module, :root, :tmp_dir]

    with true <- Keyword.keyword?(options),
         true <- options |> Keyword.keys() |> Enum.sort() == expected_keys,
         true <- Keyword.fetch!(options, :root) == config.context.blob_root,
         true <- Keyword.fetch!(options, :data_root) == config.context.data_root,
         true <- Keyword.fetch!(options, :pack_module) == nil,
         true <- Keyword.fetch!(options, :tmp_dir) == stage_directory,
         max_size <- Keyword.fetch!(options, :max_size),
         true <- is_integer(max_size) and max_size > 0 and max_size <= config.max_bytes do
      :ok
    else
      _invalid -> {:error, :invalid_source}
    end
  end

  defp valid_etag?(nil), do: true

  defp valid_etag?(etag) when is_binary(etag),
    do: Regex.match?(@etag_regex, etag)

  defp valid_etag?(_etag), do: false

  defp validate_source(%Source{} = source) do
    with true <- valid_file_descriptor?(source.io),
         true <- bounded_file_offset?(source.offset),
         true <- bounded_file_offset?(source.position),
         true <- bounded_file_offset?(source.remaining),
         true <- source.position <= @maximum_file_offset - source.offset,
         true <- source.remaining <= @maximum_file_offset - source.offset - source.position do
      :ok
    else
      _invalid -> {:error, :invalid_source}
    end
  end

  defp valid_file_descriptor?({:file_descriptor, _driver, _state}), do: true
  defp valid_file_descriptor?(_io), do: false

  defp bounded_file_offset?(value),
    do: is_integer(value) and value >= 0 and value <= @maximum_file_offset

  defp safe_pread(io, offset, length) do
    FileSystem.pread(io, offset, length)
  rescue
    _error -> {:error, :invalid_descriptor}
  catch
    _kind, _reason -> {:error, :invalid_descriptor}
  end

  defp safe_close(io) do
    FileSystem.close(io)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp stage_options(%Config{} = config, staging_key, options) do
    with true <- Keyword.keyword?(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 in @stage_option_keys)),
         read_options when is_list(read_options) <- Keyword.get(options, :read_options, []),
         :ok <- validate_read_options(read_options),
         max_size when is_integer(max_size) and max_size > 0 <-
           Keyword.get(options, :max_size, config.max_bytes),
         true <- max_size <= config.max_bytes do
      tmp_dir = Path.join([config.tmp_root, "uploads", staging_key])

      {:ok,
       config.context
       |> ExStorageService.Context.direct_blob_store_options()
       |> Keyword.merge(tmp_dir: tmp_dir, max_size: max_size), read_options}
    else
      _invalid -> {:error, :invalid_source}
    end
  end

  defp validate_read_options(options) do
    with true <- Keyword.keyword?(options),
         true <-
           options |> Keyword.keys() |> Enum.sort() == [:length, :read_length, :read_timeout],
         length when is_integer(length) and length > 0 and length <= @maximum_read_bytes <-
           Keyword.fetch!(options, :length),
         read_length when is_integer(read_length) and read_length > 0 and read_length <= length <-
           Keyword.fetch!(options, :read_length),
         timeout when is_integer(timeout) and timeout > 0 and timeout <= 30_000 <-
           Keyword.fetch!(options, :read_timeout) do
      :ok
    else
      _invalid -> {:error, :invalid_source}
    end
  end

  defp blob_options(%Config{} = config) do
    ExStorageService.Context.direct_blob_store_options(config.context)
  end

  defp recover_options(%Config{} = config, staging_key) do
    config.context
    |> ExStorageService.Context.direct_blob_store_options()
    |> Keyword.merge(
      tmp_dir: Path.join([config.tmp_root, "uploads", staging_key]),
      max_size: config.max_bytes
    )
  end

  defp enforce_reader_chunk(
         {kind, chunk, _next_state} = result,
         maximum_bytes,
         _maximum_size
       )
       when kind in [:more, :ok] and is_binary(chunk) and byte_size(chunk) <= maximum_bytes,
       do: result

  defp enforce_reader_chunk({kind, chunk, next_state}, _maximum_bytes, maximum_size)
       when kind in [:more, :ok] and is_binary(chunk) and byte_size(chunk) > maximum_size,
       do: {:error, :entity_too_large, next_state}

  defp enforce_reader_chunk({kind, _chunk, next_state}, _maximum_bytes, _maximum_size)
       when kind in [:more, :ok],
       do: {:error, :invalid_source, next_state}

  defp enforce_reader_chunk(result, _maximum_bytes, _maximum_size), do: result

  defp metadata(storage_key, size) do
    %{sha256_digest: storage_key, storage_key: storage_key, size: size}
  end

  defp finish_open(fs, io, expected_size, range) do
    result =
      case fs.read_file_info(io) do
        {:ok, info} ->
          with :regular <- file_info(info, :type),
               ^expected_size <- file_info(info, :size),
               {:ok, offset, length} <- apply_range(expected_size, range) do
            {:ok, %Source{io: io, offset: offset, position: 0, remaining: length}}
          else
            {:error, :invalid_range} -> {:error, :invalid_source}
            _type_or_size_mismatch -> {:error, :integrity_mismatch}
          end

        {:error, _os_reason} ->
          {:error, :unavailable}
      end

    case result do
      {:ok, _source} = success ->
        success

      {:error, _reason} = error ->
        _ = fs.close(io)
        error
    end
  end

  defp apply_range(size, range) when range in [nil, :all], do: {:ok, 0, size}

  defp apply_range(size, {offset, length})
       when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 and
              offset <= size and length <= size - offset,
       do: {:ok, offset, length}

  defp apply_range(_size, _range), do: {:error, :invalid_range}

  defp locate_single_survivor(fs, config, staging_key, expected_size) do
    directory = Path.join([config.tmp_root, "uploads", staging_key])

    with {:ok, %File.Stat{type: :directory}} <- fs.lstat(directory),
         {:ok, [entry]} <- fs.ls(directory),
         path = Path.join(directory, entry),
         {:ok, %File.Stat{type: :regular, size: ^expected_size}} <- fs.lstat(path) do
      {:ok, path}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:ok, []} -> {:error, :not_found}
      {:ok, %File.Stat{type: :regular}} -> {:error, :integrity_mismatch}
      {:ok, %File.Stat{}} -> {:error, :invalid_source}
      {:ok, _entries} -> {:error, :invalid_source}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp enforce_survivor_cap(size, maximum_size) when size <= maximum_size, do: :ok
  defp enforce_survivor_cap(_size, _maximum_size), do: {:error, :entity_too_large}

  defp cleanup_single_survivor(fs, uploads_directory, staging_directory) do
    case fs.lstat(staging_directory) do
      {:error, :enoent} ->
        case sync_surviving_parent(fs, uploads_directory) do
          :ok -> :ok
          {:error, _reason} -> {:error, :unavailable}
        end

      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, entries} <- fs.ls(staging_directory),
             :ok <- remove_direct_entry(fs, staging_directory, entries),
             :ok <- sync_directory(fs, staging_directory),
             :ok <- remove_empty_directory(fs, staging_directory),
             :ok <- sync_surviving_parent(fs, uploads_directory) do
          :ok
        else
          {:error, reason} when reason in [:invalid_source, :not_found] -> {:error, reason}
          {:error, _reason} -> {:error, :unavailable}
        end

      {:ok, %File.Stat{}} ->
        {:error, :invalid_source}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp remove_direct_entry(_fs, _directory, []), do: :ok

  defp remove_direct_entry(fs, directory, [entry]) do
    path = Path.join(directory, entry)

    case fs.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case fs.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        :ok

      _other ->
        {:error, :invalid_source}
    end
  end

  defp remove_direct_entry(_fs, _directory, _entries), do: {:error, :invalid_source}

  defp remove_empty_directory(fs, directory) do
    case fs.rmdir(directory) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, :enotempty} -> {:error, :invalid_source}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_surviving_parent(fs, directory) do
    case sync_directory(fs, directory) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp sync_directory(fs, directory) do
    case fs.open_directory(directory) do
      {:ok, io} ->
        sync_result = fs.sync(io)
        close_result = fs.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, reason}
          {_sync, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
