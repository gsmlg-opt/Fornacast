defmodule GitCore.Remote.Process do
  @moduledoc false

  alias GitCore.Remote.Control

  defmodule Handle do
    @moduledoc false
    defstruct [:pid, :os_pid, :group_id, :kill_target, :kill_wait_ms]
  end

  @type output :: %{stdout: binary(), stderr: binary()}

  def start(argv, opts) when is_list(argv) and is_list(opts) do
    with :ok <- validate_argv(argv),
         {:ok, command_opts} <- command_options(opts),
         {:ok, pid, os_pid} <- :exec.run_link(argv, command_opts, 5_000) do
      group_id = if Keyword.get(opts, :group) == :new, do: os_pid, else: Keyword.get(opts, :group)

      {:ok,
       %Handle{
         pid: pid,
         os_pid: os_pid,
         group_id: group_id,
         kill_target: Keyword.get(opts, :kill_target) || pid,
         kill_wait_ms: Keyword.fetch!(opts, :kill_wait_ms)
       }}
    else
      {:error, reason} -> {:error, {:process_start, safe_reason(reason)}}
    end
  catch
    :exit, reason -> {:error, {:process_start, safe_reason(reason)}}
  end

  def send_stdin(%Handle{} = handle, data) when is_binary(data) do
    :ok = :exec.send(handle.pid, data)
    :ok
  catch
    :exit, _reason -> {:error, :process_unavailable}
  end

  def close_stdin(%Handle{} = handle) do
    :ok = :exec.send(handle.pid, :eof)
    :ok
  catch
    :exit, _reason -> :ok
  end

  def await(%Handle{} = handle, opts) when is_list(opts) do
    state = %{
      stdout: <<>>,
      stderr: <<>>,
      output_bytes: 0,
      output_limit: Keyword.fetch!(opts, :output_limit),
      poll_interval: Keyword.fetch!(opts, :poll_interval),
      absolute_deadline: Keyword.fetch!(opts, :absolute_deadline),
      cancel?: Keyword.fetch!(opts, :cancel?),
      heartbeat: Keyword.fetch!(opts, :heartbeat),
      disk_check: Keyword.get(opts, :disk_check),
      repository_limit: Keyword.get(opts, :repository_limit),
      parent_monitor: Keyword.fetch!(opts, :parent_monitor),
      owner_exit_pid: Keyword.fetch!(opts, :owner_exit_pid),
      next_control_at: System.monotonic_time(:millisecond)
    }

    await_loop(handle, state)
  end

  def terminate(%Handle{} = handle) do
    stop_target(handle.kill_target, handle.kill_wait_ms)

    if handle.pid != handle.kill_target do
      stop_target(handle.pid, handle.kill_wait_ms)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  def alive?(%Handle{os_pid: os_pid}), do: os_pid in safe_which_children()

  def which_children, do: safe_which_children()

  defp await_loop(handle, state) do
    now = System.monotonic_time(:millisecond)

    case control_due(state, now) do
      {:ok, state} ->
        await_receive(handle, state, now)

      {:error, reason} ->
        terminate(handle)
        {:error, reason}
    end
  end

  defp await_receive(handle, state, now) do
    remaining = state.absolute_deadline - now
    until_control = max(state.next_control_at - now, 0)

    if remaining <= 0 do
      terminate(handle)
      {:error, :timeout}
    else
      receive do
        {:stdout, os_pid, data} when os_pid == handle.os_pid and is_binary(data) ->
          append_output(handle, state, :stdout, data)

        {:stderr, os_pid, data} when os_pid == handle.os_pid and is_binary(data) ->
          append_output(handle, state, :stderr, data)

        {:DOWN, os_pid, :process, pid, reason}
        when os_pid == handle.os_pid and pid == handle.pid ->
          process_result(reason, state)

        {:EXIT, pid, reason} when pid == handle.pid ->
          process_result(reason, state)

        {:DOWN, monitor, :process, _parent, _reason} when monitor == state.parent_monitor ->
          terminate(handle)
          {:error, :owner_down}

        {:EXIT, pid, _reason} when pid == state.owner_exit_pid ->
          terminate(handle)
          {:error, :owner_down}
      after
        min(until_control, remaining) -> await_loop(handle, state)
      end
    end
  end

  defp append_output(handle, state, stream, data) do
    output_bytes = state.output_bytes + byte_size(data)

    if output_bytes > state.output_limit do
      terminate(handle)
      {:error, :output_limit}
    else
      state =
        case stream do
          :stdout -> %{state | output_bytes: output_bytes, stdout: state.stdout <> data}
          :stderr -> %{state | output_bytes: output_bytes, stderr: state.stderr <> data}
        end

      await_loop(handle, state)
    end
  end

  defp control_due(state, now) when now >= state.next_control_at do
    case control_check(state) do
      :ok -> {:ok, %{state | next_control_at: now + state.poll_interval}}
      {:error, _reason} = error -> error
    end
  end

  defp control_due(state, _now), do: {:ok, state}

  defp process_result(:normal, state), do: {:ok, %{stdout: state.stdout, stderr: state.stderr}}
  defp process_result(_reason, _state), do: {:error, :process_exit}

  defp control_check(state) do
    with :ok <- Control.check(control_options(state)) do
      disk_check(state.disk_check, state.repository_limit)
    end
  end

  defp control_options(state) do
    [
      cancel?: state.cancel?,
      heartbeat: state.heartbeat,
      absolute_deadline: state.absolute_deadline,
      parent_monitor: state.parent_monitor,
      owner_exit_pid: state.owner_exit_pid
    ]
  end

  defp disk_check(nil, _limit), do: :ok

  defp disk_check(check, limit) when is_function(check, 0) and is_integer(limit) do
    case safe_disk_check(check) do
      {:ok, bytes} when is_integer(bytes) and bytes <= limit ->
        :ok

      {:ok, bytes} when is_integer(bytes) and bytes > limit ->
        {:error, :repository_limit}

      {:error, reason}
      when reason in [:cancelled, :heartbeat_failed, :owner_down, :timeout] ->
        {:error, reason}

      _other ->
        {:error, :disk_unavailable}
    end
  end

  defp safe_disk_check(callback) when is_function(callback, 0) do
    callback.()
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp command_options(opts) do
    env = Keyword.fetch!(opts, :env)
    kill_escalation_ms = Keyword.fetch!(opts, :kill_escalation_ms)
    kill_timeout_seconds = max(div(kill_escalation_ms + 999, 1_000), 1)

    command_opts = [
      :monitor,
      {:stdout, self()},
      {:stderr, self()},
      {:env, [:clear | env]},
      {:kill_timeout, kill_timeout_seconds}
    ]

    command_opts =
      if Keyword.get(opts, :stdin, false), do: [:stdin | command_opts], else: command_opts

    command_opts = maybe_add(command_opts, :cd, Keyword.get(opts, :cd))

    command_opts =
      case Keyword.get(opts, :group) do
        :new -> [:kill_group, {:group, 0} | command_opts]
        group_id when is_integer(group_id) and group_id > 0 -> [{:group, group_id} | command_opts]
        nil -> command_opts
        _invalid -> :invalid
      end

    if command_opts == :invalid, do: {:error, :invalid_group}, else: {:ok, command_opts}
  end

  defp maybe_add(options, _key, nil), do: options
  defp maybe_add(options, key, value), do: [{key, value} | options]

  defp validate_argv([executable | _arguments] = argv)
       when is_binary(executable) and is_list(argv) do
    if Path.type(executable) == :absolute and
         Enum.all?(argv, &(is_binary(&1) and &1 != "" and not String.contains?(&1, <<0>>))) do
      :ok
    else
      {:error, :invalid_argv}
    end
  end

  defp validate_argv(_argv), do: {:error, :invalid_argv}

  defp safe_reason(reason) when reason in [:enoent, :eacces, :invalid_argv], do: reason
  defp safe_reason(_reason), do: :unavailable

  defp safe_which_children do
    :exec.which_children()
  catch
    :exit, _reason -> []
  end

  defp stop_target(target, wait_ms) do
    _result = :exec.kill(target, :sigstop)
    _result = :exec.stop(target)
    deadline = System.monotonic_time(:millisecond) + wait_ms
    wait_for_exit(target, deadline)
  catch
    :exit, _reason -> :ok
  end

  defp wait_for_exit(target, deadline) do
    os_pid = if is_pid(target), do: safe_ospid(target), else: target

    cond do
      not is_integer(os_pid) or os_pid not in safe_which_children() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        _result = :exec.kill(target, :sigkill)
        :ok

      true ->
        receive do
        after
          20 -> wait_for_exit(target, deadline)
        end
    end
  end

  defp safe_ospid(pid) do
    :exec.ospid(pid)
  catch
    :exit, _reason -> nil
  end
end
