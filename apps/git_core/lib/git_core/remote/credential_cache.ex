defmodule GitCore.Remote.CredentialCache do
  @moduledoc false

  alias GitCore.Remote.{Control, CredentialReaper, Process}

  def with_cache(git, credential_login, pat, opts, fun)
      when is_binary(git) and is_binary(credential_login) and is_binary(pat) and
             is_list(opts) and is_function(fun, 3) do
    root = Keyword.fetch!(opts, :credential_root)

    with {:ok, operation_path} <- create_operation_directory(root, opts) do
      socket_path = Path.join(operation_path, "credential.sock")

      try do
        result =
          with {:ok, daemon} <- start_daemon(git, socket_path, opts),
               :ok <- remember_daemon(operation_path, daemon),
               :ok <- CredentialReaper.write_metadata(operation_path, daemon.os_pid),
               :ok <- wait_for_socket(socket_path, daemon, opts),
               :ok <- approve(git, socket_path, credential_login, pat, daemon, opts) do
            fun.(socket_path, daemon, operation_path)
          end

        finish(result, cleanup(git, socket_path, operation_path, root, opts))
      rescue
        error ->
          _result = cleanup(git, socket_path, operation_path, root, opts)
          reraise error, __STACKTRACE__
      catch
        kind, reason ->
          _result = cleanup(git, socket_path, operation_path, root, opts)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp start_daemon(git, socket_path, opts) do
    Process.start(
      [git, "credential-cache--daemon", socket_path],
      process_options(opts, group: :new)
    )
  end

  defp approve(git, socket_path, credential_login, pat, daemon, opts) do
    payload =
      IO.iodata_to_binary([
        "protocol=https\n",
        "host=github.com\n",
        "username=",
        credential_login,
        "\npassword=",
        pat,
        "\n\n"
      ])

    with {:ok, approval} <-
           Process.start(
             [git, "credential-cache", "--socket=#{socket_path}", "store"],
             process_options(opts,
               group: daemon.group_id,
               kill_target: daemon.pid,
               stdin: true
             )
           ),
         :ok <- Process.send_stdin(approval, payload),
         :ok <- Process.close_stdin(approval),
         {:ok, _output} <- Process.await(approval, await_options(opts)) do
      :ok
    else
      {:error, reason}
      when reason in [:cancelled, :heartbeat_failed, :owner_down, :timeout] ->
        {:error, reason}

      _error ->
        {:error, :credential_unavailable}
    end
  end

  defp wait_for_socket(socket_path, daemon, opts) do
    startup_deadline =
      min(
        Keyword.fetch!(opts, :absolute_deadline),
        System.monotonic_time(:millisecond) +
          GitCore.Limits.get(:remote_credential_startup_ms)
      )

    wait_for_socket_loop(socket_path, daemon, startup_deadline, opts)
  end

  defp wait_for_socket_loop(socket_path, daemon, startup_deadline, opts) do
    parent_monitor = Keyword.fetch!(opts, :parent_monitor)
    owner_exit_pid = Keyword.fetch!(opts, :owner_exit_pid)

    if socket?(socket_path) do
      :ok
    else
      case Control.check(control_options(opts)) do
        :ok ->
          if System.monotonic_time(:millisecond) >= startup_deadline do
            Process.terminate(daemon)
            {:error, :credential_unavailable}
          else
            receive do
              {:DOWN, os_pid, :process, pid, _reason}
              when os_pid == daemon.os_pid and pid == daemon.pid ->
                {:error, :credential_unavailable}

              {:DOWN, monitor, :process, _parent, _reason}
              when monitor == parent_monitor ->
                Process.terminate(daemon)
                {:error, :owner_down}

              {:EXIT, pid, _reason} when pid == daemon.pid ->
                {:error, :credential_unavailable}

              {:EXIT, pid, _reason} when pid == owner_exit_pid ->
                Process.terminate(daemon)
                {:error, :owner_down}
            after
              GitCore.Limits.get(:remote_poll_interval_ms) ->
                wait_for_socket_loop(socket_path, daemon, startup_deadline, opts)
            end
          end

        {:error, reason} ->
          Process.terminate(daemon)
          {:error, reason}
      end
    end
  end

  defp cleanup(git, socket_path, operation_path, root, opts) do
    daemon = daemon_for_operation(operation_path)

    if socket?(socket_path) and daemon do
      case Process.start(
             [git, "credential-cache", "--socket=#{socket_path}", "exit"],
             process_options(opts,
               group: daemon.group_id,
               kill_target: daemon.pid
             )
           ) do
        {:ok, exit_process} -> _result = Process.await(exit_process, await_options(opts))
        {:error, _reason} -> :ok
      end
    end

    if daemon, do: Process.terminate(daemon)
    result = CredentialReaper.remove_operation(root, operation_path)
    Elixir.Process.delete({__MODULE__, operation_path})
    result
  end

  defp finish(result, :ok), do: result
  defp finish(_result, {:error, _reason}), do: {:error, :unsafe_credential_state}

  defp daemon_for_operation(operation_path) do
    Elixir.Process.get({__MODULE__, operation_path})
  end

  defp remember_daemon(operation_path, daemon) do
    Elixir.Process.put({__MODULE__, operation_path}, daemon)
    :ok
  end

  defp create_operation_directory(root, opts) do
    with true <- Path.type(root) == :absolute and root == Path.expand(root),
         :ok <- ensure_private_root(root, Keyword.fetch!(opts, :credential_root_state), opts),
         operation_path <- Path.join(root, "op-#{random_name()}"),
         :ok <- File.mkdir(operation_path),
         :ok <- File.chmod(operation_path, 0o700) do
      {:ok, operation_path}
    else
      {:error, reason}
      when reason in [:cancelled, :heartbeat_failed, :owner_down, :timeout] ->
        {:error, reason}

      _error ->
        {:error, :credential_unavailable}
    end
  end

  defp ensure_private_root(root, :existing, _opts), do: existing_private_root(root)

  defp ensure_private_root(root, :absent, opts) do
    deadline =
      min(
        Keyword.fetch!(opts, :absolute_deadline),
        System.monotonic_time(:millisecond) +
          GitCore.Limits.get(:remote_credential_startup_ms)
      )

    ensure_absent_root(root, deadline, opts)
  end

  defp ensure_private_root(_root, _state, _opts), do: {:error, :unsafe_credential_state}

  defp ensure_absent_root(root, deadline, opts) do
    with :ok <- CredentialReaper.safe_existing_directory_path(Path.dirname(root)) do
      case File.lstat(root) do
        {:ok, %File.Stat{type: :directory, mode: mode}}
        when Bitwise.band(mode, 0o777) == 0o700 ->
          CredentialReaper.safe_existing_directory_path(root)

        {:ok, %File.Stat{type: :directory}} ->
          wait_for_private_root(root, deadline, opts)

        {:error, :enoent} ->
          case File.mkdir(root) do
            :ok ->
              with :ok <- File.chmod(root, 0o700) do
                existing_private_root(root)
              end

            {:error, :eexist} ->
              ensure_absent_root(root, deadline, opts)

            _error ->
              {:error, :unsafe_credential_state}
          end

        _unsafe ->
          {:error, :unsafe_credential_state}
      end
    end
  end

  defp existing_private_root(root) do
    with {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(root),
         true <- Bitwise.band(mode, 0o777) == 0o700 do
      CredentialReaper.safe_existing_directory_path(root)
    else
      _unsafe -> {:error, :unsafe_credential_state}
    end
  end

  defp wait_for_private_root(root, deadline, opts) do
    case Control.check(control_options(opts)) do
      :ok ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :credential_unavailable}
        else
          parent_monitor = Keyword.fetch!(opts, :parent_monitor)
          owner_exit_pid = Keyword.fetch!(opts, :owner_exit_pid)

          receive do
            {:DOWN, monitor, :process, _parent, _reason} when monitor == parent_monitor ->
              {:error, :owner_down}

            {:EXIT, pid, _reason} when pid == owner_exit_pid ->
              {:error, :owner_down}
          after
            GitCore.Limits.get(:remote_poll_interval_ms) ->
              ensure_absent_root(root, deadline, opts)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_options(opts, additions) do
    base = [
      env: Keyword.fetch!(opts, :env),
      kill_wait_ms: GitCore.Limits.get(:remote_cleanup_wait_ms),
      kill_escalation_ms: GitCore.Limits.get(:remote_kill_escalation_ms)
    ]

    Keyword.merge(base, additions)
  end

  defp await_options(opts) do
    [
      output_limit: GitCore.Limits.get(:remote_output_bytes),
      poll_interval: GitCore.Limits.get(:remote_poll_interval_ms),
      absolute_deadline: Keyword.fetch!(opts, :absolute_deadline),
      cancel?: Keyword.fetch!(opts, :cancel?),
      heartbeat: Keyword.fetch!(opts, :heartbeat),
      parent_monitor: Keyword.fetch!(opts, :parent_monitor),
      owner_exit_pid: Keyword.fetch!(opts, :owner_exit_pid)
    ]
  end

  defp socket?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :other}} -> true
      _other -> false
    end
  end

  defp control_options(opts) do
    Keyword.take(opts, [
      :cancel?,
      :heartbeat,
      :absolute_deadline,
      :parent_monitor,
      :owner_exit_pid
    ])
  end

  defp random_name, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
