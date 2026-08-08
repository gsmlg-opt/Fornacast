defmodule GitTransport.ReceivePackWorker do
  @moduledoc false

  require Logger

  @doc false
  def run(caller, reply, repository, pack, commands, native)
      when is_pid(caller) and is_reference(reply) and is_binary(pack) and is_list(commands) and
             is_function(native, 3) do
    result =
      ForgeRepos.with_write_fence(repository, :receive_pack, fn path, remaining ->
        if remaining > 0 do
          {:native, invoke_native(native, path, pack, commands)}
        else
          {:error, {:unavailable, :write_timeout}}
        end
      end)

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
end
