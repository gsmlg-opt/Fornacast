defmodule GitTransport.Channel do
  @moduledoc false

  @behaviour :ssh_server_channel

  require Logger

  defstruct cm: nil,
            channel_id: nil,
            operation: nil,
            actor: nil,
            repository: nil,
            buffer: "",
            request: nil,
            receive_pack_bytes: 0

  @impl :ssh_server_channel
  def init(_args) do
    {:ok, %__MODULE__{request: GitTransport.UploadPack.new_request()}}
  end

  @impl :ssh_server_channel
  def handle_msg({:ssh_channel_up, channel_id, cm}, state) do
    {:ok, %{state | cm: cm, channel_id: channel_id}}
  end

  def handle_msg(_message, state), do: {:ok, state}

  @impl :ssh_server_channel
  def handle_ssh_msg({:ssh_cm, cm, {:exec, channel_id, want_reply, command}}, state) do
    username = connection_value(cm, :user) |> to_string()
    command = to_string(command)

    case GitTransport.Exec.prepare(username, command) do
      {:ok, _actor, %{operation: :upload_pack}, repository} ->
        start_upload_pack(cm, channel_id, want_reply, repository, state)

      {:ok, actor, %{operation: :receive_pack}, repository} ->
        start_receive_pack(cm, channel_id, want_reply, actor, repository, state)

      {:error, reason} ->
        reject(cm, channel_id, want_reply, GitTransport.Exec.error_message(reason), state)
    end
  end

  def handle_ssh_msg({:ssh_cm, cm, {:data, channel_id, _type, data}}, state) do
    case state.operation do
      :upload_pack ->
        continue_upload_pack(cm, channel_id, data, state)

      :receive_pack ->
        continue_receive_pack(cm, channel_id, data, state)

      _ ->
        {:ok, state}
    end
  end

  def handle_ssh_msg({:ssh_cm, cm, {:eof, channel_id}}, state) do
    case state.operation do
      :upload_pack -> finish_upload_pack(cm, channel_id, state.request, state)
      :receive_pack -> finish_receive_pack(cm, channel_id, state.request, state.buffer, state)
      _ -> {:ok, state}
    end
  end

  def handle_ssh_msg({:ssh_cm, cm, {:shell, channel_id, want_reply}}, state) do
    reject(
      cm,
      channel_id,
      want_reply,
      "ERROR: Fornacast only supports Git commands over SSH.\n",
      state
    )
  end

  def handle_ssh_msg({:ssh_cm, cm, {:pty, channel_id, want_reply, _pty}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :failure, channel_id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, cm, {:env, channel_id, want_reply, _variable, _value}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :failure, channel_id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:signal, _channel_id, _signal}}, state), do: {:ok, state}

  def handle_ssh_msg({:ssh_cm, _cm, {:closed, channel_id}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg(message, state) do
    Logger.info("SSH channel ignored unsupported message: #{inspect(message)}")
    {:ok, state}
  end

  @impl :ssh_server_channel
  def terminate(_reason, _state), do: :ok

  defp start_upload_pack(cm, channel_id, want_reply, repository, state) do
    case GitTransport.UploadPack.advertise_refs(repository) do
      {:ok, advertisement} ->
        :ssh_connection.reply_request(cm, want_reply, :success, channel_id)

        with :ok <- send_data(cm, channel_id, advertisement) do
          {:ok,
           %{
             state
             | cm: cm,
               channel_id: channel_id,
               operation: :upload_pack,
               repository: repository,
               buffer: "",
               request: GitTransport.UploadPack.new_request()
           }}
        else
          {:error, _reason} -> fail_started(cm, channel_id, state)
        end

      {:error, reason} ->
        Logger.error("Git upload-pack advertisement failed: #{inspect(reason)}")
        reject(cm, channel_id, want_reply, "ERROR: Git upload-pack failed.\n", state)
    end
  end

  defp start_receive_pack(cm, channel_id, want_reply, actor, repository, state) do
    case GitTransport.ReceivePack.advertise_refs(repository) do
      {:ok, advertisement} ->
        :ssh_connection.reply_request(cm, want_reply, :success, channel_id)

        with :ok <- send_data(cm, channel_id, advertisement) do
          {:ok,
           %{
             state
             | cm: cm,
               channel_id: channel_id,
               operation: :receive_pack,
               actor: actor,
               repository: repository,
               buffer: "",
               request: GitTransport.ReceivePack.new_request(),
               receive_pack_bytes: 0
           }}
        else
          {:error, _reason} -> fail_started(cm, channel_id, state)
        end

      {:error, reason} ->
        Logger.error("Git receive-pack advertisement failed: #{inspect(reason)}")
        reject(cm, channel_id, want_reply, "ERROR: Git receive-pack failed.\n", state)
    end
  end

  defp continue_upload_pack(cm, channel_id, data, state) do
    buffer = state.buffer <> data

    case GitTransport.UploadPack.parse_request_data(buffer, state.request) do
      {:cont, buffer, request} ->
        {:ok, %{state | buffer: buffer, request: request}}

      {:done, _rest, request} ->
        finish_upload_pack(cm, channel_id, request, state)

      {:error, message} ->
        fail_started(cm, channel_id, message, state)
    end
  end

  defp continue_receive_pack(cm, channel_id, data, state) do
    if byte_size(data) > GitTransport.ReceivePack.max_request_bytes() - state.receive_pack_bytes do
      fail_started(
        cm,
        channel_id,
        "ERROR: Git receive-pack request is too large.\n",
        state
      )
    else
      continue_receive_pack_within_limit(cm, channel_id, data, state)
    end
  end

  defp continue_receive_pack_within_limit(cm, channel_id, data, state) do
    buffer = state.buffer <> data
    receive_pack_bytes = state.receive_pack_bytes + byte_size(data)

    case GitTransport.ReceivePack.parse_request_data(buffer, state.request) do
      {:cont, buffer, request} ->
        {:ok,
         %{
           state
           | buffer: buffer,
             request: request,
             receive_pack_bytes: receive_pack_bytes
         }}

      {:pack, pack, request} ->
        {:ok,
         %{
           state
           | buffer: pack,
             request: request,
             receive_pack_bytes: receive_pack_bytes
         }}

      {:error, message} ->
        fail_started(cm, channel_id, message, state)
    end
  end

  defp finish_upload_pack(cm, channel_id, request, state) do
    case GitTransport.UploadPack.response(state.repository, request) do
      {:ok, ""} ->
        exit_success(cm, channel_id, state)

      {:ok, response} ->
        with :ok <- send_data(cm, channel_id, response) do
          exit_success(cm, channel_id, state)
        else
          {:error, _reason} -> fail_started(cm, channel_id, state)
        end

      {:error, message} ->
        fail_started(cm, channel_id, message, state)
    end
  end

  defp finish_receive_pack(cm, channel_id, %{phase: :pack} = request, pack, state) do
    with {:ok, response, statuses} <-
           GitTransport.ReceivePack.response(state.repository, request, pack),
         :ok <- send_data(cm, channel_id, response),
         :ok <- GitTransport.ReceivePack.record_push(state.actor, state.repository, statuses) do
      exit_success(cm, channel_id, state)
    else
      {:error, _reason} -> fail_started(cm, channel_id, state)
    end
  end

  defp finish_receive_pack(cm, channel_id, _request, _pack, state) do
    fail_started(cm, channel_id, "ERROR: Incomplete Git receive-pack request.\n", state)
  end

  defp reject(cm, channel_id, want_reply, message, state) do
    :ssh_connection.reply_request(cm, want_reply, :success, channel_id)
    send_error(cm, channel_id, message)
    :ssh_connection.exit_status(cm, channel_id, 255)
    :ssh_connection.send_eof(cm, channel_id)
    {:stop, channel_id, %{state | cm: cm, channel_id: channel_id}}
  end

  defp fail_started(cm, channel_id, state) do
    fail_started(cm, channel_id, "ERROR: Git transport failed.\n", state)
  end

  defp fail_started(cm, channel_id, message, state) do
    send_error(cm, channel_id, message)
    :ssh_connection.exit_status(cm, channel_id, 255)
    :ssh_connection.send_eof(cm, channel_id)
    {:stop, channel_id, %{state | cm: cm, channel_id: channel_id}}
  end

  defp exit_success(cm, channel_id, state) do
    :ssh_connection.exit_status(cm, channel_id, 0)
    :ssh_connection.send_eof(cm, channel_id)
    {:stop, channel_id, %{state | cm: cm, channel_id: channel_id}}
  end

  defp send_data(cm, channel_id, data) do
    case :ssh_connection.send(cm, channel_id, data) do
      :ok ->
        :ok

      {:error, reason} = error ->
        error |> tap(fn _ -> Logger.info("SSH send failed: #{inspect(reason)}") end)
    end
  end

  defp send_error(cm, channel_id, message) do
    :ssh_connection.send(cm, channel_id, 1, message)
  end

  defp connection_value(cm, key) do
    case :ssh.connection_info(cm, [key]) do
      [{^key, value}] -> value
      {^key, value} -> value
      _ -> nil
    end
  end
end
