defmodule GitTransport.ReceivePack do
  @moduledoc """
  Minimal Git receive-pack write-side protocol support.

  This implements the protocol-v0 write path needed for initial pushes, new
  branches, fast-forward branch updates, and tag creation.
  """

  alias ForgeRepos.Repository
  require Logger

  @zero_oid String.duplicate("0", 40)
  @object_id_pattern ~r/\A[0-9a-fA-F]{40}\z/
  @sideband_payload_size 65_515
  @capabilities [
    "report-status",
    "side-band-64k",
    "ofs-delta",
    "object-format=sha1",
    "agent=fornacast/0.1"
  ]

  def advertise_refs(%Repository{} = repository) do
    path = ForgeRepos.absolute_storage_path(repository)

    with {:ok, refs} <- GitCore.list_refs(path) do
      refs =
        refs
        |> Enum.filter(&advertisable_ref?/1)
        |> Enum.sort_by(& &1.name)

      {:ok, render_advertisement(refs)}
    end
  end

  def new_request do
    %{commands: [], capabilities: MapSet.new(), phase: :commands}
  end

  def parse_request_data(buffer, request \\ new_request())
      when is_binary(buffer) and is_map(request) do
    case request.phase do
      :commands -> parse_command_buffer(buffer, request)
      :pack -> {:pack, buffer, request}
    end
  end

  def response(%Repository{} = repository, request, pack)
      when is_map(request) and is_binary(pack) do
    request = normalize_request(request)
    path = ForgeRepos.absolute_storage_path(repository)
    commands = Enum.map(request.commands, &command_to_native/1)

    case GitCore.receive_pack(path, pack, commands) do
      {:ok, statuses} ->
        {:ok, render_status_report(request, "ok", statuses), statuses}

      {:error, reason} ->
        Logger.error("Native Git receive-pack error: #{inspect(reason)}")

        statuses =
          Enum.map(request.commands, fn command ->
            {command.ref, "ng", "Git receive-pack failed"}
          end)

        {:ok, render_status_report(request, sanitize_status(reason), statuses), statuses}
    end
  end

  def record_push(actor, %Repository{} = repository, statuses) when is_list(statuses) do
    if accepted_push?(statuses) do
      refs = Enum.map(statuses, fn {ref, "ok", _message} -> ref end)

      with {:ok, _repository} <- ForgeRepos.mark_pushed(repository),
           {:ok, _event} <-
             Fornacast.Audit.record(
               actor,
               "repository.pushed",
               "repository",
               repository.id,
               %{"refs" => refs}
             ) do
        :ok
      else
        {:error, reason} ->
          Logger.error("Git receive-pack audit update failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

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

    with {:ok, command} <- parse_ref_command(command_line) do
      request =
        request
        |> Map.update!(:commands, &[command | &1])
        |> Map.update!(:capabilities, &MapSet.union(&1, MapSet.new(capabilities)))

      {:cont, request}
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

          ref == "" ->
            {:error, "ERROR: Invalid Git reference.\n"}

          true ->
            {:ok, %{old: String.downcase(old), new: String.downcase(new), ref: ref}}
        end

      _ ->
        {:error, "ERROR: Invalid Git receive-pack command.\n"}
    end
  end

  defp normalize_request(request) do
    %{request | commands: Enum.reverse(request.commands)}
  end

  defp command_to_native(command) do
    {command.old, command.new, command.ref}
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
  end

  defp sanitize_status(reason), do: reason |> inspect() |> sanitize_status()

  defp accepted_push?([]), do: false

  defp accepted_push?(statuses) do
    Enum.all?(statuses, fn
      {_ref, "ok", _message} -> true
      _status -> false
    end)
  end
end
