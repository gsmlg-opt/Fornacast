defmodule GitTransport.ReceivePack do
  @moduledoc """
  Minimal Git receive-pack write-side protocol support.

  This implements the protocol-v0 write path needed for initial pushes, new
  branches, fast-forward branch updates, and tag creation.

  A supervised worker owns the write fence independently of the HTTP or SSH
  caller. The deadline bounds admission, reconciliation, and later durable CAS
  operations. Legacy native receive-pack is not cancellable, so once it is
  admitted its worker and writer lease remain alive until the native call
  returns or raises, even if the caller exits or the deadline passes.
  """

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  require Logger

  @zero_oid String.duplicate("0", 40)
  @object_id_pattern ~r/\A[0-9a-fA-F]{40}\z/
  @max_target_ref_bytes 255
  @sideband_payload_size 65_515
  @default_max_request_bytes 4 * 1024 * 1024 * 1024
  @http_operation_batch_domain "fornacast:git-http-receive-pack:v1"
  @http_operation_batch_prefix "git-http-rp-"
  @max_external_request_id_bytes 255
  @capabilities [
    "report-status",
    "side-band-64k",
    "ofs-delta",
    "object-format=sha1",
    "agent=fornacast/0.1"
  ]

  def advertise_refs(%Repository{} = repository) do
    result =
      ForgeRepos.with_write_fence(repository, :receive_pack, fn path, _remaining ->
        with {:ok, refs} <- GitCore.list_refs(path) do
          refs =
            refs
            |> Enum.filter(&advertisable_ref?/1)
            |> Enum.sort_by(& &1.name)

          {:ok, render_advertisement(refs)}
        end
      end)

    result
  end

  def new_request do
    %{commands: [], command_count: 0, capabilities: MapSet.new(), phase: :commands}
  end

  def max_request_bytes do
    case Application.fetch_env(:git_transport, :receive_pack_max_bytes) do
      {:ok, nil} -> nil
      {:ok, max} when is_integer(max) and max > 0 -> max
      _ -> @default_max_request_bytes
    end
  end

  @spec http_operation_batch_id(User.t(), Repository.t(), String.t() | nil) :: String.t()
  def http_operation_batch_id(
        %User{id: actor_id},
        %Repository{id: repository_id},
        external_request_id
      )
      when is_integer(actor_id) and actor_id > 0 and is_integer(repository_id) and
             repository_id > 0 do
    digest =
      if usable_external_request_id?(external_request_id) do
        :crypto.hash(:sha256, [
          @http_operation_batch_domain,
          <<0, repository_id::unsigned-64, actor_id::unsigned-64, 0>>,
          external_request_id
        ])
      else
        :crypto.strong_rand_bytes(32)
      end

    @http_operation_batch_prefix <> Base.url_encode64(digest, padding: false)
  end

  def parse_request_data(buffer, request \\ new_request())
      when is_binary(buffer) and is_map(request) do
    case request.phase do
      :commands -> parse_command_buffer(buffer, request)
      :pack -> {:pack, buffer, request}
    end
  end

  def response(
        %User{} = actor,
        %Repository{} = repository,
        request,
        pack,
        request_id
      )
      when is_map(request) and is_binary(pack) and is_binary(request_id) and
             byte_size(request_id) in 1..255 do
    command_limit = GitCore.Limits.get(:receive_pack_commands)

    case bounded_normalize_request(request, command_limit) do
      {:too_many, request} ->
        unavailable_response(request)

      {:ok, request} ->
        commands = Enum.map(request.commands, &command_to_native/1)

        case supervised_receive_pack(actor, repository, request_id, pack, commands) do
          {:durable, durable_statuses, native_result} ->
            statuses = merge_native_diagnostics(durable_statuses, native_result)

            {:ok, render_status_report(request, durable_unpack_status(native_result), statuses),
             statuses}

          {:error, {:unavailable, _reason}} ->
            Logger.warning("Git receive-pack write fence unavailable")
            unavailable_response(request)
        end
    end
  end

  if Mix.env() == :test do
    @native_hook_key {__MODULE__, :native_hook}

    @doc false
    def with_test_native(native, fun) when is_function(native, 3) and is_function(fun, 0) do
      previous = Process.get(@native_hook_key)
      Process.put(@native_hook_key, native)

      try do
        fun.()
      after
        if previous == nil,
          do: Process.delete(@native_hook_key),
          else: Process.put(@native_hook_key, previous)
      end
    end

    defp native_adapter, do: Process.get(@native_hook_key, &GitCore.receive_pack/3)
  else
    defp native_adapter, do: &GitCore.receive_pack/3
  end

  defp supervised_receive_pack(actor, repository, request_id, pack, commands) do
    caller = self()
    reply = make_ref()
    native = native_adapter()

    case GitTransport.ReceivePackWorkerManager.start_worker(fn ->
           GitTransport.ReceivePackWorker.run(
             caller,
             reply,
             actor,
             repository,
             request_id,
             pack,
             commands,
             native
           )
         end) do
      {:ok, worker} -> await_worker(worker, reply)
      {:error, _reason} -> {:error, {:unavailable, :receive_pack_worker}}
    end
  end

  defp await_worker(worker, reply) do
    monitor = Process.monitor(worker)

    receive do
      {^reply, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        receive do
          {^reply, result} -> result
        after
          0 -> {:error, {:unavailable, :receive_pack_worker}}
        end
    end
  end

  defp unavailable_response(request) do
    message = "Git receive-pack unavailable"

    statuses =
      Enum.map(request.commands, fn command ->
        {command.ref, "ng", message}
      end)

    {:ok, render_status_report(request, message, statuses), statuses}
  end

  defp merge_native_diagnostics(durable_statuses, {:ok, native_statuses})
       when is_list(native_statuses) do
    diagnostics =
      native_statuses
      |> Enum.reduce(%{}, fn
        {target_ref, "ng", message}, diagnostics
        when is_binary(target_ref) and is_binary(message) ->
          Map.put_new(diagnostics, target_ref, sanitize_status(message))

        _status, diagnostics ->
          diagnostics
      end)

    Enum.map(durable_statuses, fn
      {target_ref, "ng", _message} ->
        {target_ref, "ng", Map.get(diagnostics, target_ref, "Git receive-pack failed")}

      status ->
        status
    end)
  end

  defp merge_native_diagnostics(durable_statuses, _native_result), do: durable_statuses

  defp durable_unpack_status({:ok, _statuses}), do: "ok"
  defp durable_unpack_status(_native_result), do: "Git receive-pack failed"

  defp render_advertisement([]) do
    [
      GitTransport.PktLine.encode("#{@zero_oid} capabilities^{}\0#{capabilities()}\n"),
      GitTransport.PktLine.flush()
    ]
    |> IO.iodata_to_binary()
  end

  defp render_advertisement([first | rest]) do
    [
      GitTransport.PktLine.encode("#{first.target} #{first.name}\0#{capabilities()}\n"),
      Enum.map(rest, &advertise_ref/1),
      GitTransport.PktLine.flush()
    ]
    |> IO.iodata_to_binary()
  end

  defp advertise_ref(ref) do
    GitTransport.PktLine.encode("#{ref.target} #{ref.name}\n")
  end

  defp capabilities do
    Enum.join(@capabilities, " ")
  end

  defp advertisable_ref?(%{kind: kind}) when kind in [:branch, :tag], do: true
  defp advertisable_ref?(_ref), do: false

  defp parse_command_buffer(buffer, request) when byte_size(buffer) < 4 do
    {:cont, buffer, request}
  end

  defp parse_command_buffer(<<"0000", rest::binary>>, request) do
    {:pack, rest, %{request | phase: :pack}}
  end

  defp parse_command_buffer(<<header::binary-size(4), rest::binary>> = buffer, request) do
    with {length, ""} <- Integer.parse(header, 16),
         true <- length >= 4 do
      payload_length = length - 4

      if byte_size(rest) < payload_length do
        {:cont, buffer, request}
      else
        {payload, tail} = :erlang.split_binary(rest, payload_length)

        payload
        |> String.trim_trailing("\n")
        |> parse_command_line(request)
        |> case do
          {:cont, request} -> parse_command_buffer(tail, request)
          {:error, _message} = error -> error
        end
      end
    else
      _ -> {:error, "ERROR: Invalid Git protocol packet.\n"}
    end
  end

  defp parse_command_line("", request), do: {:cont, request}

  defp parse_command_line(line, request) do
    {command_line, capabilities} = split_capabilities(line)

    with true <- request.command_count < GitCore.Limits.get(:receive_pack_commands),
         {:ok, command} <- parse_ref_command(command_line) do
      request =
        request
        |> Map.update!(:commands, &[command | &1])
        |> Map.update!(:command_count, &(&1 + 1))
        |> Map.update!(:capabilities, &MapSet.union(&1, MapSet.new(capabilities)))

      {:cont, request}
    else
      false -> {:error, "ERROR: Too many Git receive-pack commands.\n"}
      {:error, _message} = error -> error
    end
  end

  defp split_capabilities(line) do
    case String.split(line, <<0>>, parts: 2) do
      [command_line, capabilities] -> {command_line, String.split(capabilities)}
      [command_line] -> {command_line, []}
    end
  end

  defp parse_ref_command(command_line) do
    case String.split(command_line, " ", parts: 3) do
      [old, new, ref] ->
        cond do
          not Regex.match?(@object_id_pattern, old) ->
            {:error, "ERROR: Invalid Git object id.\n"}

          not Regex.match?(@object_id_pattern, new) ->
            {:error, "ERROR: Invalid Git object id.\n"}

          ref == "" or byte_size(ref) > @max_target_ref_bytes ->
            {:error, "ERROR: Invalid Git reference.\n"}

          true ->
            {:ok, %{old: String.downcase(old), new: String.downcase(new), ref: ref}}
        end

      _ ->
        {:error, "ERROR: Invalid Git receive-pack command.\n"}
    end
  end

  defp bounded_normalize_request(%{commands: commands} = request, command_limit)
       when is_list(commands) do
    bounded_commands = Enum.take(commands, command_limit + 1)
    request = %{request | commands: Enum.reverse(bounded_commands)}

    if length(bounded_commands) > command_limit,
      do: {:too_many, request},
      else: {:ok, request}
  end

  defp command_to_native(command) do
    {command.old, command.new, command.ref}
  end

  defp usable_external_request_id?(request_id) do
    is_binary(request_id) and request_id != "" and request_id != "unassigned" and
      byte_size(request_id) <= @max_external_request_id_bytes
  end

  defp render_status_report(request, unpack_status, statuses) do
    payload =
      [
        GitTransport.PktLine.encode("unpack #{sanitize_status(unpack_status)}\n"),
        Enum.map(statuses, &status_line/1),
        GitTransport.PktLine.flush()
      ]
      |> IO.iodata_to_binary()

    if MapSet.member?(request.capabilities, "side-band-64k") do
      payload
      |> sideband()
      |> IO.iodata_to_binary()
    else
      payload
    end
  end

  defp status_line({ref, "ok", _message}) do
    GitTransport.PktLine.encode("ok #{ref}\n")
  end

  defp status_line({ref, "ng", message}) do
    GitTransport.PktLine.encode("ng #{ref} #{sanitize_status(message)}\n")
  end

  defp sideband(payload), do: sideband(payload, [])

  defp sideband(<<>>, acc) do
    Enum.reverse([GitTransport.PktLine.flush() | acc])
  end

  defp sideband(payload, acc) do
    size = min(byte_size(payload), @sideband_payload_size)
    {chunk, rest} = :erlang.split_binary(payload, size)
    packet = GitTransport.PktLine.encode(<<1>> <> chunk)

    sideband(rest, [packet | acc])
  end

  defp sanitize_status(reason) when is_binary(reason) do
    reason
    |> String.replace(["\r", "\n"], " ")
    |> String.trim()
    |> case do
      "" -> "failed"
      sanitized -> sanitized
    end
    |> String.slice(0, 240)
  end

  defp sanitize_status(reason), do: reason |> inspect() |> sanitize_status()
end
