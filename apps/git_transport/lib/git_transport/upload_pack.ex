defmodule GitTransport.UploadPack do
  @moduledoc """
  Minimal Git upload-pack read-side protocol support.

  This implements the protocol-v0 read path needed for `git ls-remote`,
  normal clone, and normal fetch.
  """

  alias ForgeRepos.Repository
  require Logger

  @zero_oid String.duplicate("0", 40)
  @object_id_pattern ~r/\A[0-9a-fA-F]{40}\z/
  @sideband_payload_size 65_515
  @capabilities [
    "side-band",
    "side-band-64k",
    "ofs-delta",
    "object-format=sha1",
    "agent=fornacast/0.1"
  ]

  if Mix.env() == :test do
    @serve_handle_hook_key {__MODULE__, :serve_handle_hook}
    @pack_objects_hook_key {__MODULE__, :pack_objects_hook}
    @global_pack_objects_hook_key {__MODULE__, :global_pack_objects_hook}

    @doc false
    def with_test_serve_handle(adapter, fun)
        when is_function(adapter, 1) and is_function(fun, 0) do
      previous = Process.get(@serve_handle_hook_key)
      Process.put(@serve_handle_hook_key, adapter)

      try do
        fun.()
      after
        if previous,
          do: Process.put(@serve_handle_hook_key, previous),
          else: Process.delete(@serve_handle_hook_key)
      end
    end

    @doc false
    def test_serve_handle_hook?, do: not is_nil(Process.get(@serve_handle_hook_key))

    @doc false
    def test_global_pack_objects_hook?,
      do: not is_nil(:persistent_term.get(@global_pack_objects_hook_key, nil))

    @doc false
    def with_test_pack_objects(adapter, fun)
        when is_function(adapter, 2) and is_function(fun, 0) do
      previous = Process.get(@pack_objects_hook_key)
      Process.put(@pack_objects_hook_key, adapter)

      try do
        fun.()
      after
        if previous,
          do: Process.put(@pack_objects_hook_key, previous),
          else: Process.delete(@pack_objects_hook_key)
      end
    end

    @doc false
    def with_test_global_pack_objects(adapter, fun)
        when is_function(adapter, 2) and is_function(fun, 0) do
      previous = :persistent_term.get(@global_pack_objects_hook_key, nil)
      :persistent_term.put(@global_pack_objects_hook_key, adapter)

      try do
        fun.()
      after
        if previous,
          do: :persistent_term.put(@global_pack_objects_hook_key, previous),
          else: :persistent_term.erase(@global_pack_objects_hook_key)
      end
    end

    defp pack_objects(path, wants) do
      adapter =
        Process.get(@pack_objects_hook_key) ||
          :persistent_term.get(@global_pack_objects_hook_key, &GitCore.pack_objects/2)

      adapter.(path, wants)
    end
  else
    defp pack_objects(path, wants), do: GitCore.pack_objects(path, wants)
  end

  def advertise_refs(%Repository{} = repository) do
    with_read_handle(repository, &advertise_refs_handle/1)
  end

  @spec advertise_refs_handle(ForgeRepos.RepositoryReadHandle.t()) ::
          {:ok, binary()} | {:error, term()}
  def advertise_refs_handle(handle) do
    path = ForgeRepos.repository_read_path(handle)
    repository = ForgeRepos.repository_read_repository(handle)

    with {:ok, refs} <- GitCore.list_refs(path) do
      refs =
        refs
        |> Enum.filter(&advertisable_ref?/1)
        |> Enum.sort_by(& &1.name)

      {:ok, render_advertisement(refs, repository.default_branch)}
    end
  end

  def serve(%Repository{} = repository) do
    with_read_handle(repository, fn handle ->
      with {:ok, advertisement} <- advertise_refs_handle(handle),
           :ok <- write(advertisement),
           {:ok, request} <- read_client_request(),
           :ok <- maybe_send_pack(handle, request) do
        :ok
      end
    end)
  end

  @spec serve_handle(ForgeRepos.RepositoryReadHandle.t()) :: :ok | {:error, term()}
  if Mix.env() == :test do
    def serve_handle(handle) do
      if Process.get(@serve_handle_hook_key) do
        Process.get(@serve_handle_hook_key).(handle)
      else
        serve_handle_stdio(handle)
      end
    end
  else
    def serve_handle(handle), do: serve_handle_stdio(handle)
  end

  defp serve_handle_stdio(handle) do
    with {:ok, advertisement} <- advertise_refs_handle(handle),
         :ok <- write(advertisement),
         {:ok, request} <- read_client_request(),
         :ok <- maybe_send_pack(handle, request) do
      :ok
    end
  end

  def new_request do
    %{wants: [], haves: [], capabilities: MapSet.new(), done?: false, flush_count: 0}
  end

  def parse_request_data(buffer, request \\ new_request())
      when is_binary(buffer) and is_map(request) do
    parse_request_buffer(buffer, request)
  end

  def response(%Repository{} = repository, request) when is_map(request) do
    with_read_handle(repository, fn handle -> response_handle(handle, request) end)
  end

  @spec response_handle(ForgeRepos.RepositoryReadHandle.t(), map()) ::
          {:ok, binary()} | {:error, term()}
  def response_handle(handle, request) when is_map(request) do
    build_pack_response(handle, normalize_request(request))
  end

  defp render_advertisement([], _default_branch) do
    [
      GitTransport.PktLine.encode("#{@zero_oid} capabilities^{}\0#{capabilities()}\n"),
      GitTransport.PktLine.flush()
    ]
    |> IO.iodata_to_binary()
  end

  defp render_advertisement(refs, default_branch) do
    {head_ref, rest_refs} = head_and_rest(refs, default_branch)

    [
      advertise_head(head_ref),
      Enum.map(rest_refs, &advertise_ref/1),
      GitTransport.PktLine.flush()
    ]
    |> IO.iodata_to_binary()
  end

  defp head_and_rest(refs, default_branch) do
    default_ref_name = "refs/heads/#{default_branch}"

    head_ref =
      Enum.find(refs, &(default_ref_name == &1.name)) ||
        Enum.find(refs, &(&1.kind == :branch)) ||
        List.first(refs)

    rest_refs =
      refs
      |> Enum.reject(&(&1.name == head_ref.name))

    {head_ref, [head_ref | rest_refs]}
  end

  defp advertise_head(ref) do
    GitTransport.PktLine.encode(
      "#{ref.target} HEAD\0#{capabilities()} #{symref_capability(ref)}\n"
    )
  end

  defp advertise_ref(ref) do
    GitTransport.PktLine.encode("#{ref.target} #{ref.name}\n")
  end

  defp symref_capability(%{kind: :branch, name: name}), do: "symref=HEAD:#{name}"
  defp symref_capability(_ref), do: ""

  defp capabilities do
    Enum.join(@capabilities, " ")
  end

  defp advertisable_ref?(%{kind: kind}) when kind in [:branch, :tag], do: true
  defp advertisable_ref?(_ref), do: false

  defp read_client_request(request \\ new_request()) do
    case read_pkt_line() do
      {:ok, :flush} ->
        {:ok, normalize_request(request)}

      {:ok, {:data, payload}} ->
        payload
        |> String.trim_trailing("\n")
        |> parse_request_line(request)
        |> case do
          {:done, request} -> {:ok, normalize_request(request)}
          {:cont, request} -> read_client_request(request)
          {:error, _reason} = error -> error
        end

      :eof ->
        {:ok, normalize_request(request)}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_request_buffer(buffer, request) when byte_size(buffer) < 4 do
    {:cont, buffer, request}
  end

  defp parse_request_buffer(<<"0000">>, request) do
    {:flush, "", record_flush(request)}
  end

  defp parse_request_buffer(<<"0000", rest::binary>>, request) do
    parse_request_buffer(rest, record_flush(request))
  end

  defp parse_request_buffer(<<header::binary-size(4), rest::binary>> = buffer, request) do
    with {length, ""} <- Integer.parse(header, 16),
         true <- length >= 4 do
      payload_length = length - 4

      if byte_size(rest) < payload_length do
        {:cont, buffer, request}
      else
        {payload, tail} = :erlang.split_binary(rest, payload_length)

        payload
        |> String.trim_trailing("\n")
        |> parse_request_line(request)
        |> case do
          {:done, request} -> {:done, tail, normalize_request(request)}
          {:cont, request} -> parse_request_buffer(tail, request)
          {:error, _reason} = error -> error
        end
      end
    else
      _ -> {:error, "ERROR: Invalid Git protocol packet.\n"}
    end
  end

  defp read_pkt_line do
    case IO.binread(:stdio, 4) do
      :eof ->
        :eof

      "0000" ->
        {:ok, :flush}

      header when is_binary(header) and byte_size(header) == 4 ->
        with {length, ""} <- Integer.parse(header, 16),
             true <- length >= 4 do
          read_pkt_payload(length - 4)
        else
          _ -> {:error, "ERROR: Invalid Git protocol packet.\n"}
        end
    end
  end

  defp read_pkt_payload(0), do: {:ok, {:data, ""}}

  defp read_pkt_payload(length) do
    case IO.binread(:stdio, length) do
      payload when is_binary(payload) and byte_size(payload) == length ->
        {:ok, {:data, payload}}

      _ ->
        {:error, "ERROR: Incomplete Git protocol packet.\n"}
    end
  end

  defp parse_request_line("done", request), do: {:done, %{request | done?: true}}

  defp parse_request_line("want " <> rest, request) do
    with {:ok, oid, capabilities} <- parse_want(rest) do
      request =
        request
        |> Map.update!(:wants, &[String.downcase(oid) | &1])
        |> Map.update!(:capabilities, &MapSet.union(&1, MapSet.new(capabilities)))

      {:cont, request}
    end
  end

  defp parse_request_line("have " <> oid, request) do
    oid = String.trim(oid)

    if Regex.match?(@object_id_pattern, oid) do
      {:cont, Map.update!(request, :haves, &[String.downcase(oid) | &1])}
    else
      {:error, "ERROR: Invalid Git object id.\n"}
    end
  end

  defp parse_request_line("deepen" <> _rest, _request) do
    {:error, "ERROR: Shallow clones are not supported in this Fornacast release.\n"}
  end

  defp parse_request_line("", request), do: {:cont, request}
  defp parse_request_line(_line, request), do: {:cont, request}

  defp parse_want(rest) do
    [oid | capability_parts] =
      rest
      |> String.replace(<<0>>, " ")
      |> String.split()

    if Regex.match?(@object_id_pattern, oid) do
      {:ok, oid, capability_parts}
    else
      {:error, "ERROR: Invalid Git object id.\n"}
    end
  end

  defp normalize_request(request) do
    %{
      request
      | wants: request.wants |> Enum.reverse() |> Enum.uniq(),
        haves: request.haves |> Enum.reverse() |> Enum.uniq()
    }
  end

  defp record_flush(request) do
    Map.update!(request, :flush_count, &(&1 + 1))
  end

  defp maybe_send_pack(_handle, %{wants: []}), do: :ok

  defp maybe_send_pack(handle, request) do
    with {:ok, response} <- build_pack_response(handle, request) do
      write(response)
    end
  end

  defp build_pack_response(_handle, %{wants: []}), do: {:ok, ""}

  defp build_pack_response(_handle, %{done?: false}) do
    {:ok, GitTransport.PktLine.encode("NAK\n")}
  end

  defp build_pack_response(handle, request) do
    path = ForgeRepos.repository_read_path(handle)

    case pack_objects(path, request.wants) do
      {:ok, pack} ->
        {:ok, pack_response(pack, request.capabilities)}

      {:error, reason} ->
        Logger.error("Native Git upload-pack error: #{inspect(reason)}")
        {:error, "ERROR: Git upload-pack failed.\n"}
    end
  end

  defp pack_response(pack, capabilities) do
    if MapSet.member?(capabilities, "side-band-64k") or
         MapSet.member?(capabilities, "side-band") do
      [GitTransport.PktLine.encode("NAK\n"), sideband_pack(pack)]
    else
      [GitTransport.PktLine.encode("NAK\n"), pack]
    end
    |> IO.iodata_to_binary()
  end

  defp sideband_pack(pack), do: sideband_pack(pack, [])

  defp sideband_pack(<<>>, acc) do
    Enum.reverse([GitTransport.PktLine.flush() | acc])
  end

  defp sideband_pack(pack, acc) do
    size = min(byte_size(pack), @sideband_payload_size)
    {chunk, rest} = :erlang.split_binary(pack, size)
    packet = GitTransport.PktLine.encode(<<1>> <> chunk)

    sideband_pack(rest, [packet | acc])
  end

  defp write(data) do
    IO.binwrite(:stdio, data)
    :ok
  end

  defp with_read_handle(repository, fun) do
    deadline = System.monotonic_time(:millisecond) + GitCore.Limits.get(:content_deadline_ms)
    ForgeRepos.with_repository_read(repository, deadline, fun)
  end
end
