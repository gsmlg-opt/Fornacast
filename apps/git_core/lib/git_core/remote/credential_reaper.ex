defmodule GitCore.Remote.CredentialReaper do
  @moduledoc false

  import Bitwise

  @directory_pattern ~r/\Aop-[A-Za-z0-9_-]{22}\z/
  @metadata_file "operation.json"
  @metadata_bytes 1_024

  def root do
    Application.get_env(
      :git_core,
      :remote_credential_root,
      Path.join(System.tmp_dir!(), "fornacast-git-credentials")
    )
  end

  @doc false
  def safe_existing_directory_path(path) when is_binary(path) do
    with :ok <- canonical_path(path),
         true <- Enum.all?(ancestor_paths(path), &directory_not_symlink?/1) do
      :ok
    else
      _unsafe -> {:error, :unsafe_credential_state}
    end
  end

  def safe_existing_directory_path(_path), do: {:error, :unsafe_credential_state}

  def reap(root \\ root())

  def reap(root) when is_binary(root) do
    timeout = GitCore.Limits.get(:remote_cleanup_wait_ms)
    deadline = System.monotonic_time(:millisecond) + timeout

    bounded_call(fn -> do_reap(root, deadline) end, timeout)
  end

  def reap(_root), do: {:error, :unsafe_credential_state}

  defp do_reap(root, deadline) do
    with :ok <- canonical_root(root),
         :ok <- before_deadline(deadline),
         {:ok, entries} <- root_entries(root),
         live <- MapSet.new(GitCore.Remote.Process.which_children()) do
      Enum.reduce_while(entries, :ok, fn name, :ok ->
        operation_path = Path.join(root, name)

        with :ok <- before_deadline(deadline),
             true <- Regex.match?(@directory_pattern, name),
             :ok <- safe_directory(operation_path),
             {:ok, metadata} <- read_metadata(operation_path) do
          if MapSet.member?(live, metadata.group_leader_os_pid) do
            {:cont, :ok}
          else
            case do_remove_operation(root, operation_path, deadline) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end
          end
        else
          {:error, :cleanup_timeout} = timeout -> {:halt, timeout}
          _unsafe -> {:halt, {:error, :unsafe_credential_state}}
        end
      end)
    end
  end

  def write_metadata(operation_path, group_leader_os_pid)
      when is_binary(operation_path) and is_integer(group_leader_os_pid) and
             group_leader_os_pid > 0 do
    metadata = %{
      "version" => 1,
      "group_leader_os_pid" => group_leader_os_pid,
      "created_at" => System.system_time(:second)
    }

    encoded = JSON.encode!(metadata)
    temporary = Path.join(operation_path, ".operation-#{random_name()}.tmp")
    destination = Path.join(operation_path, @metadata_file)

    with true <- byte_size(encoded) <= @metadata_bytes,
         :ok <- File.write(temporary, encoded, [:exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      _error ->
        _result = File.rm(temporary)
        {:error, :metadata_unavailable}
    end
  end

  def write_metadata(_operation_path, _group_leader_os_pid),
    do: {:error, :metadata_unavailable}

  def remove_operation(root, operation_path)
      when is_binary(root) and is_binary(operation_path) do
    timeout = GitCore.Limits.get(:remote_cleanup_wait_ms)
    deadline = System.monotonic_time(:millisecond) + timeout

    bounded_call(fn -> do_remove_operation(root, operation_path, deadline) end, timeout)
  end

  def remove_operation(_root, _operation_path), do: {:error, :unsafe_credential_state}

  defp do_remove_operation(root, operation_path, deadline) do
    with :ok <- canonical_root(root),
         :ok <- before_deadline(deadline),
         true <- Path.dirname(operation_path) == root,
         true <- Regex.match?(@directory_pattern, Path.basename(operation_path)),
         :ok <- safe_tree(operation_path, deadline),
         :ok <- canonical_root(root),
         :ok <- before_deadline(deadline),
         {:ok, _removed} <- File.rm_rf(operation_path) do
      :ok
    else
      {:error, :cleanup_timeout} = timeout -> timeout
      _unsafe -> {:error, :unsafe_credential_state}
    end
  end

  defp root_entries(root) do
    case File.lstat(root) do
      {:error, :enoent} -> {:ok, []}
      {:ok, %File.Stat{type: :directory}} -> File.ls(root)
      _unsafe -> {:error, :unsafe_credential_state}
    end
  end

  defp read_metadata(operation_path) do
    path = Path.join(operation_path, @metadata_file)

    with {:ok, %File.Stat{type: :regular, mode: mode, size: size}} <- File.lstat(path),
         true <- band(mode, 0o777) == 0o600,
         true <- size <= @metadata_bytes,
         {:ok, encoded} <- File.read(path),
         {:ok, decoded} <- JSON.decode(encoded),
         true <- Enum.sort(Map.keys(decoded)) == ["created_at", "group_leader_os_pid", "version"],
         %{
           "version" => 1,
           "group_leader_os_pid" => group_leader_os_pid,
           "created_at" => created_at
         } <- decoded,
         true <- is_integer(group_leader_os_pid) and group_leader_os_pid > 0,
         true <- is_integer(created_at) and created_at > 0 do
      {:ok, %{group_leader_os_pid: group_leader_os_pid, created_at: created_at}}
    else
      _invalid -> {:error, :unsafe_credential_state}
    end
  end

  defp safe_tree(path, deadline) do
    with :ok <- before_deadline(deadline) do
      safe_tree_entry(path, deadline)
    end
  end

  defp safe_tree_entry(path, deadline) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case safe_tree(Path.join(path, entry), deadline) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
        end

      {:ok, %File.Stat{type: type}} when type in [:regular, :other] ->
        :ok

      _unsafe ->
        {:error, :unsafe_credential_state}
    end
  end

  defp safe_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when band(mode, 0o777) == 0o700 -> :ok
      _unsafe -> {:error, :unsafe_credential_state}
    end
  end

  defp canonical_root(root) do
    with :ok <- canonical_path(root) do
      case File.lstat(root) do
        {:error, :enoent} ->
          safe_existing_directory_path(Path.dirname(root))

        {:ok, %File.Stat{type: :directory, mode: mode}} when band(mode, 0o777) == 0o700 ->
          safe_existing_directory_path(root)

        _unsafe ->
          {:error, :unsafe_credential_state}
      end
    end
  end

  defp canonical_path(path) do
    if Path.type(path) == :absolute and path == Path.expand(path),
      do: :ok,
      else: {:error, :unsafe_credential_state}
  end

  defp ancestor_paths(path), do: ancestor_paths(path, [])

  defp ancestor_paths(path, paths) do
    parent = Path.dirname(path)
    paths = [path | paths]
    if parent == path, do: paths, else: ancestor_paths(parent, paths)
  end

  defp directory_not_symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        true

      {:ok, %File.Stat{type: :symlink}} ->
        system_symlink?(path)

      _other ->
        false
    end
  end

  defp system_symlink?(path) when path in ["/var", "/tmp", "/etc", "/run"] do
    case :os.type() do
      {:unix, :darwin} ->
        case File.read_link(path) do
          {:ok, target} when target in ["private" <> path, "private/var/run"] ->
            match?({:ok, %File.Stat{type: :directory}}, File.lstat("/" <> target))

          _other ->
            false
        end

      _other ->
        false
    end
  end

  defp system_symlink?(_path), do: false

  defp before_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, :cleanup_timeout}
  end

  defp bounded_call(fun, timeout) when is_function(fun, 0) and is_integer(timeout) do
    caller = self()
    reply = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              {:ok, fun.()}
            rescue
              _error -> {:error, :unsafe_credential_state}
            catch
              _kind, _reason -> {:error, :unsafe_credential_state}
            end

          send(caller, {reply, result})
        end,
        [:link, :monitor]
      )

    receive do
      {^reply, {:ok, result}} ->
        forget_bounded_worker(worker, monitor)
        result

      {^reply, {:error, :unsafe_credential_state}} ->
        forget_bounded_worker(worker, monitor)
        {:error, :unsafe_credential_state}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        forget_bounded_worker(worker, monitor)
        {:error, :unsafe_credential_state}

      {:EXIT, ^worker, _reason} ->
        Process.demonitor(monitor, [:flush])
        {:error, :unsafe_credential_state}
    after
      timeout ->
        Process.unlink(worker)
        Process.exit(worker, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :cleanup_timeout}
    end
  end

  defp forget_bounded_worker(worker, monitor) do
    Process.unlink(worker)
    Process.demonitor(monitor, [:flush])

    receive do
      {:EXIT, ^worker, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp random_name, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
