defmodule GitTransport.ReceivePackWorker do
  @moduledoc false

  require Logger

  @doc false
  def run(caller, reply, actor, repository, request_id, pack, commands, native)
      when is_pid(caller) and is_reference(reply) and is_binary(request_id) and is_binary(pack) and
             is_list(commands) and is_function(native, 3) do
    Process.flag(:trap_exit, true)

    result =
      if command_count_within_limit?(commands) do
        ForgeRepos.with_write_fence(repository, :receive_pack, fn path, remaining ->
          if remaining > 0 do
            absolute_deadline = System.monotonic_time(:millisecond) + remaining

            with :ok <- validate_expected_refs(path, commands, absolute_deadline),
                 {:ok, operations} <-
                   ForgeRepos.prepare_receive_pack_operations(
                     actor,
                     repository,
                     request_id,
                     commands,
                     absolute_deadline
                   ),
                 :ok <- check_deadline(absolute_deadline),
                 native_result <- invoke_native(native, path, pack, commands),
                 :ok <-
                   ForgeRepos.GitWriteRecovery.reconcile_repository_locked(
                     repository,
                     path,
                     absolute_deadline
                   ),
                 {:ok, statuses} <- ForgeRepos.receive_pack_operation_statuses(operations) do
              {:durable, statuses, native_result}
            else
              _error -> {:error, {:unavailable, :receive_pack_bookkeeping}}
            end
          else
            {:error, {:unavailable, :write_timeout}}
          end
        end)
      else
        {:error, {:unavailable, :receive_pack_bookkeeping}}
      end

    send(caller, {reply, result})
    :ok
  end

  defp invoke_native(native, path, pack, commands) do
    case native.(path, pack, commands) do
      {:error, _reason} = error ->
        Logger.error("Native Git receive-pack failed")
        error

      result ->
        result
    end
  rescue
    _error ->
      Logger.error("Native Git receive-pack failed")
      {:error, :receive_pack_failed}
  end

  @zero_oid String.duplicate("0", 40)

  defp command_count_within_limit?(commands) do
    limit = GitCore.Limits.get(:receive_pack_commands)

    commands
    |> Enum.reduce_while(0, fn _command, count ->
      if count < limit, do: {:cont, count + 1}, else: {:halt, :too_many}
    end)
    |> is_integer()
  end

  defp check_deadline(absolute_deadline) do
    if System.monotonic_time(:millisecond) < absolute_deadline,
      do: :ok,
      else: {:error, :unavailable}
  end

  defp validate_expected_refs(path, commands, absolute_deadline) do
    Enum.reduce_while(commands, :ok, fn {old_oid, _new_oid, target_ref}, :ok ->
      remaining = absolute_deadline - System.monotonic_time(:millisecond)
      expected_oid = if old_oid == @zero_oid, do: nil, else: String.downcase(old_oid)

      if remaining > 0 do
        case GitCore.exact_ref(path, target_ref, deadline_ms: remaining) do
          {:ok, ^expected_oid} -> {:cont, :ok}
          {:ok, _other_oid} -> {:halt, {:error, :stale_ref}}
          {:error, _reason} -> {:halt, {:error, :unavailable}}
        end
      else
        {:halt, {:error, :unavailable}}
      end
    end)
  end
end
