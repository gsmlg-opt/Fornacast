defmodule ForgeGitHub.LFS.Transport do
  @moduledoc false

  alias ForgeGitHub.LFS.{DownloadSource, EgressPolicy}

  @connect_timeout 5_000
  @total_timeout 20_000
  @maximum_request_bytes 2_000_000
  @maximum_header_bytes 65_536
  @stream_chunk_bytes 64 * 1_024
  @maximum_object_size 9_223_372_036_854_775_807
  @allowed_methods [:get, :post, :put]
  @blocked_headers ~w(connection content-length host keep-alive proxy-authenticate
                      proxy-authorization te trailer transfer-encoding upgrade)

  defmodule Error do
    @moduledoc false
    defexception [:kind]

    @impl Exception
    def message(%__MODULE__{kind: :invalid_request}), do: "invalid GitHub LFS request"
    def message(%__MODULE__{kind: :host_unavailable}), do: "GitHub LFS host unavailable"
    def message(%__MODULE__{kind: :unsafe_host}), do: "unsafe GitHub LFS host"
    def message(%__MODULE__{kind: :timeout}), do: "GitHub LFS request timed out"
    def message(%__MODULE__{kind: :response_too_large}), do: "GitHub LFS response too large"
    def message(%__MODULE__{kind: :integrity_mismatch}), do: "GitHub LFS size mismatch"
    def message(%__MODULE__{kind: :source}), do: "GitHub LFS source failed"
    def message(%__MODULE__{kind: :sink}), do: "GitHub LFS sink failed"
    def message(%__MODULE__{}), do: "GitHub LFS transport failed"
  end

  defimpl Inspect, for: Error do
    def inspect(error, _options), do: "#ForgeGitHub.LFS.Transport.Error<#{error.kind}>"
  end

  @type response :: %{status: 100..599, headers: [{String.t(), String.t()}], body: binary()}
  @type body ::
          {:buffer, binary() | nil, pos_integer()}
          | {:download, function(), term(), non_neg_integer()}
          | {:upload, function(), term(), non_neg_integer()}
          | {:consume_download, function(), non_neg_integer(), String.t()}

  @spec request(atom(), String.t(), [{String.t(), String.t()}], body(), keyword()) ::
          {:ok, response()}
          | {:ok, response(), term()}
          | {:error, Error.t()}
          | {:error, Error.t(), term()}
  def request(method, url, headers, body, opts \\ []) do
    deadline = monotonic_ms() + request_timeout(opts)

    with true <- method in @allowed_methods,
         {:ok, uri} <- validate_url(url),
         {:ok, headers} <- validate_headers(headers),
         {:ok, body} <- validate_body(method, body),
         {:ok, addresses} <- resolve_addresses(uri.host, opts, deadline) do
      api = Keyword.get(opts, :transport_api, Mint.HTTP)
      run_with_deadline(method, uri, headers, body, api, addresses, deadline)
    else
      {:error, :host_unavailable} -> {:error, %Error{kind: :host_unavailable}}
      {:error, :unsafe_host} -> {:error, %Error{kind: :unsafe_host}}
      {:error, :timeout} -> {:error, %Error{kind: :timeout}}
      _invalid -> {:error, %Error{kind: :invalid_request}}
    end
  rescue
    _exception -> {:error, %Error{kind: :connect}}
  catch
    _kind, _reason -> {:error, %Error{kind: :connect}}
  end

  defp run_with_deadline(method, uri, headers, body, api, addresses, deadline) do
    parent = self()
    reference = make_ref()
    callers = Process.get(:"$callers", [])

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", [parent | callers])

        receive do
          {^reference, :start} ->
            result = execute(method, uri, headers, body, api, addresses, deadline)
            send(parent, {reference, :result, result})
        end
      end)

    send(worker, {reference, :start})

    receive do
      {^reference, :result, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        transport_error(:connect, body)
    after
      remaining(deadline) ->
        Process.exit(worker, :kill)
        await_down(monitor, worker)
        flush(reference)
        transport_error(:timeout, body)
    end
  end

  defp execute(method, uri, headers, body, api, addresses, deadline) do
    connect(method, uri, headers, body, api, addresses, deadline)
  rescue
    _exception -> transport_error(:connect, body)
  catch
    _kind, _reason -> transport_error(:connect, body)
  end

  defp connect(_method, _uri, _headers, body, _api, [], deadline),
    do: transport_error(deadline_or(deadline, :connect), body)

  defp connect(method, uri, headers, body, api, [address | rest], deadline) do
    case remaining(deadline) do
      0 ->
        transport_error(:timeout, body)

      remaining ->
        options = [
          hostname: uri.host,
          mode: :passive,
          protocols: [:http1],
          log: false,
          max_header_list_size: @maximum_header_bytes,
          transport_opts: transport_options(address, remaining)
        ]

        case api.connect(:https, address, 443, options) do
          {:ok, connection} ->
            connected(method, uri, headers, body, api, connection, deadline)

          {:error, _reason} when rest != [] ->
            connect(method, uri, headers, body, api, rest, deadline)

          _error ->
            transport_error(deadline_or(deadline, :connect), body)
        end
    end
  end

  defp connected(method, uri, headers, body, api, connection, deadline) do
    try do
      send_and_receive(method, uri, headers, body, api, connection, deadline)
    after
      safe_close(api, connection)
    end
  end

  defp send_and_receive(method, uri, headers, body, api, connection, deadline) do
    wire_headers = request_headers(headers, uri.host, body)
    target = request_target(uri)

    case body do
      {:buffer, request_body, maximum_response} ->
        case api.request(connection, method_name(method), target, wire_headers, request_body) do
          {:ok, connection, reference} ->
            receive_response(
              api,
              connection,
              reference,
              response_state({:buffer, maximum_response}),
              deadline
            )

          _error ->
            {:error, %Error{kind: deadline_or(deadline, :send)}}
        end

      {:download, writer, state, expected_size} ->
        case api.request(connection, "GET", target, wire_headers, nil) do
          {:ok, connection, reference} ->
            receive_response(
              api,
              connection,
              reference,
              response_state({:download, writer, state, expected_size}),
              deadline
            )

          _error ->
            {:error, %Error{kind: deadline_or(deadline, :send)}, state}
        end

      {:consume_download, consumer, expected_size, expected_oid} ->
        case api.request(connection, "GET", target, wire_headers, nil) do
          {:ok, connection, reference} ->
            source = %DownloadSource{
              api: api,
              connection: connection,
              reference: reference,
              deadline: deadline,
              expected_size: expected_size,
              expected_oid: expected_oid,
              hash: :crypto.hash_init(:sha256)
            }

            consume_download(consumer, source)

          _error ->
            {:error, %Error{kind: deadline_or(deadline, :send)}}
        end

      {:upload, reader, state, expected_size} ->
        case api.request(connection, "PUT", target, wire_headers, :stream) do
          {:ok, connection, reference} ->
            case stream_upload(api, connection, reference, reader, state, expected_size, deadline) do
              {:ok, connection, state} ->
                receive_response(
                  api,
                  connection,
                  reference,
                  response_state({:upload, state}),
                  deadline
                )

              {:error, kind, state} ->
                {:error, %Error{kind: kind}, state}
            end

          _error ->
            {:error, %Error{kind: deadline_or(deadline, :send)}, state}
        end
    end
  end

  defp stream_upload(api, connection, reference, reader, state, remaining_bytes, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout, state}

      _time_available when remaining_bytes == 0 ->
        finish_upload(api, connection, reference, reader, state, deadline)

      time_available ->
        requested = min(remaining_bytes, @stream_chunk_bytes)

        case safe_read(reader, requested, state) do
          {:ok, chunk, next_state}
          when is_binary(chunk) and chunk != "" and byte_size(chunk) <= requested ->
            case api.stream_request_body(connection, reference, chunk) do
              {:ok, next_connection} ->
                if remaining(deadline) == 0 do
                  {:error, :timeout, next_state}
                else
                  stream_upload(
                    api,
                    next_connection,
                    reference,
                    reader,
                    next_state,
                    remaining_bytes - byte_size(chunk),
                    deadline
                  )
                end

              _error ->
                {:error, deadline_or(deadline, :send), next_state}
            end

          {:eof, next_state} ->
            {:error, :integrity_mismatch, next_state}

          {:error, _reason, next_state} ->
            {:error, :source, next_state}

          _invalid when time_available > 0 ->
            {:error, :source, state}
        end
    end
  end

  defp finish_upload(api, connection, reference, reader, state, deadline) do
    case safe_read(reader, @stream_chunk_bytes, state) do
      {:eof, next_state} ->
        case api.stream_request_body(connection, reference, :eof) do
          {:ok, next_connection} -> {:ok, next_connection, next_state}
          _error -> {:error, deadline_or(deadline, :send), next_state}
        end

      {:ok, _extra, next_state} ->
        {:error, :integrity_mismatch, next_state}

      {:error, _reason, next_state} ->
        {:error, :source, next_state}

      _invalid ->
        {:error, :source, state}
    end
  end

  defp safe_read(reader, requested, state) do
    reader.(requested, state)
  rescue
    _exception -> {:error, :source, state}
  catch
    _kind, _reason -> {:error, :source, state}
  end

  defp consume_download(consumer, source) do
    case safe_consume(consumer, source) do
      {:ok, value, %DownloadSource{} = final_source} ->
        finish_consumed_download(final_source, {:ok, value})

      {:error, reason, %DownloadSource{} = final_source} ->
        finish_consumed_download(final_source, {:error, reason})

      _invalid ->
        {:error, %Error{kind: :sink}}
    end
  end

  defp safe_consume(consumer, source) do
    consumer.(&read_download/2, source)
  rescue
    _exception -> {:error, :sink, source}
  catch
    _kind, _reason -> {:error, :sink, source}
  end

  @doc false
  @spec read_download(DownloadSource.t(), keyword()) ::
          {:ok, binary(), DownloadSource.t()}
          | {:eof, DownloadSource.t()}
          | {:error, atom(), DownloadSource.t()}
  def read_download(%DownloadSource{} = source, options) when is_list(options) do
    with {:ok, length, timeout} <- read_options(options) do
      read_download_source(source, length, timeout)
    else
      _invalid -> {:error, :invalid_source, source}
    end
  end

  def read_download(source, _options), do: {:error, :invalid_source, source}

  defp read_download_source(%DownloadSource{error: error} = source, _length, _timeout)
       when not is_nil(error),
       do: {:error, error, source}

  defp read_download_source(%DownloadSource{pending: pending} = source, length, _timeout)
       when pending != "" do
    size = min(byte_size(pending), length)
    <<chunk::binary-size(^size), rest::binary>> = pending

    {:ok, chunk,
     %{
       source
       | pending: rest,
         received: source.received + size,
         hash: :crypto.hash_update(source.hash, chunk)
     }}
  end

  defp read_download_source(%DownloadSource{done: true} = source, _length, _timeout) do
    finish_download_source(source)
  end

  defp read_download_source(%DownloadSource{} = source, length, timeout) do
    receive_download_source(source, length, timeout)
  end

  defp receive_download_source(source, length, timeout) do
    remaining_timeout = min(remaining(source.deadline), timeout)

    if remaining_timeout == 0 do
      source = %{source | error: :timeout}
      {:error, :timeout, source}
    else
      case source.api.recv(source.connection, 0, remaining_timeout) do
        {:ok, connection, responses} ->
          source = %{source | connection: connection}

          case consume_download_responses(responses, source) do
            {:ok, source} -> read_download_source(source, length, timeout)
            {:error, kind, source} -> {:error, kind, %{source | error: kind}}
          end

        {:error, connection, reason, responses} ->
          source = %{source | connection: connection}

          case consume_download_responses(responses, source) do
            {:error, kind, source} ->
              {:error, kind, %{source | error: kind}}

            _other ->
              kind = transport_error_kind(reason, source.deadline)
              {:error, kind, %{source | error: kind}}
          end

        _invalid ->
          {:error, :receive, %{source | error: :receive}}
      end
    end
  end

  defp consume_download_responses(responses, source) when is_list(responses) do
    Enum.reduce_while(responses, {:ok, source}, fn response, {:ok, source} ->
      case consume_download_response(response, source) do
        {:ok, source} -> {:cont, {:ok, source}}
        {:error, kind, source} -> {:halt, {:error, kind, source}}
      end
    end)
  end

  defp consume_download_responses(_responses, source), do: {:error, :receive, source}

  defp consume_download_response(
         {:status, reference, status},
         %DownloadSource{reference: reference, status: nil} = source
       )
       when status in 100..599,
       do: {:ok, %{source | status: status}}

  defp consume_download_response(
         {:headers, reference, headers},
         %DownloadSource{reference: reference} = source
       )
       when is_list(headers) do
    header_size = source.header_size + header_bytes(headers)

    if header_size <= @maximum_header_bytes,
      do: {:ok, %{source | headers: [headers | source.headers], header_size: header_size}},
      else: {:error, :receive, source}
  end

  defp consume_download_response(
         {:data, reference, data},
         %DownloadSource{reference: reference, status: status} = source
       )
       when is_binary(data) and status in 200..299 do
    buffered = byte_size(source.pending) + byte_size(data)
    total = source.received + buffered

    cond do
      buffered > @stream_chunk_bytes -> {:error, :response_too_large, source}
      total > source.expected_size -> {:error, :integrity_mismatch, source}
      true -> {:ok, %{source | pending: source.pending <> data}}
    end
  end

  defp consume_download_response(
         {:data, reference, data},
         %DownloadSource{reference: reference} = source
       )
       when is_binary(data) do
    size = source.error_size + byte_size(data)

    if size <= @maximum_header_bytes,
      do: {:ok, %{source | error_body: [data | source.error_body], error_size: size}},
      else: {:error, :response_too_large, source}
  end

  defp consume_download_response(
         {:done, reference},
         %DownloadSource{reference: reference} = source
       ),
       do: {:ok, %{source | done: true}}

  defp consume_download_response(
         {:error, reference, _reason},
         %DownloadSource{reference: reference} = source
       ),
       do: {:error, :receive, source}

  defp consume_download_response(_unexpected, source), do: {:error, :receive, source}

  defp finish_download_source(%DownloadSource{status: status} = source)
       when status not in 200..299,
       do: {:error, :upstream, source}

  defp finish_download_source(%DownloadSource{} = source) do
    response = download_source_response(source)
    digest = source.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    cond do
      source.received != source.expected_size ->
        {:error, :integrity_mismatch, %{source | error: :integrity_mismatch}}

      not valid_content_length?(
        response_headers(response, "content-length"),
        source.expected_size
      ) ->
        {:error, :integrity_mismatch, %{source | error: :integrity_mismatch}}

      validate_content_encoding(response) != :ok ->
        {:error, :integrity_mismatch, %{source | error: :integrity_mismatch}}

      not Plug.Crypto.secure_compare(digest, source.expected_oid) ->
        {:error, :integrity_mismatch, %{source | error: :integrity_mismatch}}

      true ->
        {:eof, %{source | completed: true}}
    end
  end

  defp finish_consumed_download(%DownloadSource{error: error}, _consumer_result)
       when not is_nil(error),
       do: {:error, %Error{kind: error}}

  defp finish_consumed_download(
         %DownloadSource{completed: false, status: status} = source,
         result
       )
       when status not in 200..299 and source.done do
    {:ok, download_source_response(source), result}
  end

  defp finish_consumed_download(%DownloadSource{completed: true} = source, result),
    do: {:ok, download_source_response(source), result}

  defp finish_consumed_download(_source, _result), do: {:error, %Error{kind: :sink}}

  defp download_source_response(source) do
    %{
      status: source.status,
      headers: source.headers |> Enum.reverse() |> List.flatten(),
      body: source.error_body |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp read_options(options) do
    with true <- Keyword.keyword?(options),
         [] <- Keyword.keys(options) -- [:length, :read_timeout],
         length when is_integer(length) and length in 1..1_048_576 <-
           Keyword.get(options, :length, @stream_chunk_bytes),
         timeout when is_integer(timeout) and timeout in 1..30_000 <-
           Keyword.get(options, :read_timeout, @total_timeout) do
      {:ok, min(length, @stream_chunk_bytes), timeout}
    else
      _invalid -> :error
    end
  end

  defp receive_response(api, connection, reference, state, deadline) do
    case remaining(deadline) do
      0 ->
        response_error(:timeout, state)

      timeout ->
        case api.recv(connection, 0, timeout) do
          {:ok, next_connection, responses} ->
            case consume(responses, reference, state) do
              {:done, state} -> finish_response(state)
              {:cont, state} -> receive_response(api, next_connection, reference, state, deadline)
              {:error, kind, state} -> response_error(kind, state)
            end

          {:error, _next_connection, reason, responses} ->
            case consume(responses, reference, state) do
              {:error, kind, state} -> response_error(kind, state)
              _other -> response_error(transport_error_kind(reason, deadline), state)
            end

          _invalid ->
            response_error(deadline_or(deadline, :receive), state)
        end
    end
  end

  defp consume(responses, reference, state) when is_list(responses) do
    Enum.reduce_while(responses, {:cont, state}, fn response, {:cont, state} ->
      case consume_one(response, reference, state) do
        {:cont, state} -> {:cont, {:cont, state}}
        {:done, state} -> {:halt, {:done, state}}
        {:error, kind, state} -> {:halt, {:error, kind, state}}
      end
    end)
  end

  defp consume(_responses, _reference, state), do: {:error, :receive, state}

  defp consume_one({:status, reference, status}, reference, %{status: nil} = state)
       when status in 100..599,
       do: {:cont, %{state | status: status}}

  defp consume_one({:headers, reference, headers}, reference, state) when is_list(headers) do
    header_size = state.header_size + header_bytes(headers)

    if header_size <= @maximum_header_bytes,
      do: {:cont, %{state | headers: [headers | state.headers], header_size: header_size}},
      else: {:error, :receive, state}
  end

  defp consume_one({:data, reference, data}, reference, state) when is_binary(data) do
    consume_data(data, state)
  end

  defp consume_one({:done, reference}, reference, state), do: {:done, state}

  defp consume_one({:error, reference, _reason}, reference, state),
    do: {:error, :receive, state}

  defp consume_one(_unexpected, _reference, state), do: {:error, :receive, state}

  defp consume_data(
         data,
         %{status: status, mode: {:download, writer, writer_state, expected}} = state
       )
       when status in 200..299 do
    if state.response_size + byte_size(data) <= expected do
      case write_chunks(data, writer, writer_state) do
        {:ok, next_state} ->
          {:cont,
           %{
             state
             | mode: {:download, writer, next_state, expected},
               response_size: state.response_size + byte_size(data)
           }}

        {:error, next_state} ->
          {:error, :sink, %{state | mode: {:download, writer, next_state, expected}}}
      end
    else
      {:error, :integrity_mismatch, state}
    end
  end

  defp consume_data(data, state) do
    maximum = response_limit(state)
    size = state.response_size + byte_size(data)

    if size <= maximum,
      do: {:cont, %{state | response_size: size, chunks: [data | state.chunks]}},
      else: {:error, :response_too_large, state}
  end

  defp write_chunks("", _writer, state), do: {:ok, state}

  defp write_chunks(data, writer, state) do
    size = min(byte_size(data), @stream_chunk_bytes)
    <<chunk::binary-size(^size), rest::binary>> = data

    case safe_write(writer, chunk, state) do
      {:ok, next_state} -> write_chunks(rest, writer, next_state)
      {:error, _reason, next_state} -> {:error, next_state}
      _invalid -> {:error, state}
    end
  end

  defp safe_write(writer, chunk, state) do
    writer.(chunk, state)
  rescue
    _exception -> {:error, :sink, state}
  catch
    _kind, _reason -> {:error, :sink, state}
  end

  defp finish_response(%{status: status} = state) when status in 100..599 do
    response = %{
      status: status,
      headers: state.headers |> Enum.reverse() |> List.flatten(),
      body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    }

    with :ok <- validate_content_encoding(response),
         :ok <- validate_download_size(response, state) do
      response_success(response, state)
    else
      {:error, kind} -> response_error(kind, state)
    end
  end

  defp finish_response(state), do: response_error(:receive, state)

  defp response_success(response, %{mode: {:download, _writer, state, _expected}}),
    do: {:ok, response, state}

  defp response_success(response, %{mode: {:upload, state}}), do: {:ok, response, state}
  defp response_success(response, %{mode: {:buffer, _maximum}}), do: {:ok, response}

  defp validate_content_encoding(response) do
    case response_headers(response, "content-encoding") do
      [] ->
        :ok

      [value] ->
        if String.downcase(String.trim(value)) == "identity",
          do: :ok,
          else: {:error, :integrity_mismatch}

      _multiple ->
        {:error, :integrity_mismatch}
    end
  end

  defp validate_download_size(
         %{status: status} = response,
         %{mode: {:download, _writer, _state, expected}, response_size: actual}
       )
       when status in 200..299 do
    content_lengths = response_headers(response, "content-length")

    cond do
      actual != expected -> {:error, :integrity_mismatch}
      valid_content_length?(content_lengths, expected) -> :ok
      true -> {:error, :integrity_mismatch}
    end
  end

  defp validate_download_size(_response, _state), do: :ok

  defp valid_content_length?([], _expected), do: true

  defp valid_content_length?([value], expected),
    do: parse_content_length(value) == {:ok, expected}

  defp valid_content_length?(_values, _expected), do: false

  defp response_state({:buffer, maximum}) do
    %{
      status: nil,
      headers: [],
      header_size: 0,
      chunks: [],
      response_size: 0,
      mode: {:buffer, maximum}
    }
  end

  defp response_state({:download, writer, state, expected}) do
    %{
      status: nil,
      headers: [],
      header_size: 0,
      chunks: [],
      response_size: 0,
      mode: {:download, writer, state, expected}
    }
  end

  defp response_state({:upload, state}) do
    %{
      status: nil,
      headers: [],
      header_size: 0,
      chunks: [],
      response_size: 0,
      mode: {:upload, state}
    }
  end

  defp response_limit(%{mode: {:buffer, maximum}}), do: maximum
  defp response_limit(%{mode: {:upload, _state}}), do: @maximum_header_bytes
  defp response_limit(%{mode: {:download, _writer, _state, _expected}}), do: @maximum_header_bytes

  defp response_error(kind, %{mode: {:download, _writer, state, _expected}}),
    do: {:error, %Error{kind: kind}, state}

  defp response_error(kind, %{mode: {:upload, state}}),
    do: {:error, %Error{kind: kind}, state}

  defp response_error(kind, _state), do: {:error, %Error{kind: kind}}

  defp transport_error(kind, {:download, _writer, state, _expected}),
    do: {:error, %Error{kind: kind}, state}

  defp transport_error(kind, {:upload, _reader, state, _expected}),
    do: {:error, %Error{kind: kind}, state}

  defp transport_error(kind, _body), do: {:error, %Error{kind: kind}}

  defp validate_url(url) when is_binary(url) and byte_size(url) in 1..8_192 do
    case URI.new(url) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         port: port,
         userinfo: nil,
         fragment: nil,
         path: "/" <> _rest
       } = uri}
      when is_binary(host) and port in [nil, 443] ->
        if EgressPolicy.valid_host?(host) and safe_target?(request_target(uri)),
          do: {:ok, %{uri | host: String.downcase(host), port: nil}},
          else: :error

      _invalid ->
        :error
    end
  end

  defp validate_url(_url), do: :error

  defp safe_target?(target) when byte_size(target) <= 8_192 do
    String.valid?(target) and
      Enum.all?([<<0>>, "\r", "\n"], &(:binary.match(target, &1) == :nomatch))
  end

  defp safe_target?(_target), do: false

  defp validate_headers(headers) when is_list(headers) and length(headers) <= 100 do
    Enum.reduce_while(headers, {:ok, [], MapSet.new(), 0}, fn
      {name, value}, {:ok, acc, seen, bytes} when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)
        next_bytes = bytes + byte_size(name) + byte_size(value)

        if valid_header?(name, value) and not MapSet.member?(seen, name) and
             next_bytes <= @maximum_header_bytes do
          {:cont, {:ok, [{name, value} | acc], MapSet.put(seen, name), next_bytes}}
        else
          {:halt, :error}
        end

      _invalid, _state ->
        {:halt, :error}
    end)
    |> case do
      {:ok, values, _seen, _bytes} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp validate_headers(_headers), do: :error

  defp valid_header?(name, value) do
    name != "" and name not in @blocked_headers and
      String.match?(name, ~r/\A[!#$%&'*+.^_`|~0-9a-z-]+\z/) and String.valid?(value) and
      Enum.all?([<<0>>, "\r", "\n"], &(:binary.match(value, &1) == :nomatch))
  end

  defp validate_body(method, {:buffer, body, maximum})
       when method in [:get, :post] and (is_nil(body) or is_binary(body)) and
              is_integer(maximum) and maximum in 1..@maximum_request_bytes do
    if is_nil(body) or byte_size(body) <= @maximum_request_bytes,
      do: {:ok, {:buffer, body, maximum}},
      else: :error
  end

  defp validate_body(:get, {:download, writer, state, expected})
       when is_function(writer, 2) and is_integer(expected) and
              expected in 0..@maximum_object_size,
       do: {:ok, {:download, writer, state, expected}}

  defp validate_body(:get, {:consume_download, consumer, expected, oid})
       when is_function(consumer, 2) and is_integer(expected) and
              expected in 0..@maximum_object_size and is_binary(oid) and byte_size(oid) == 64,
       do: {:ok, {:consume_download, consumer, expected, oid}}

  defp validate_body(:put, {:upload, reader, state, expected})
       when is_function(reader, 2) and is_integer(expected) and
              expected in 0..@maximum_object_size,
       do: {:ok, {:upload, reader, state, expected}}

  defp validate_body(_method, _body), do: :error

  defp resolve_addresses(host, opts, deadline) do
    case Keyword.fetch(opts, :resolver) do
      {:ok, resolver} -> EgressPolicy.resolve_public(host, resolver: resolver, deadline: deadline)
      :error -> EgressPolicy.resolve_public(host, deadline: deadline)
    end
  end

  defp request_headers(headers, host, {:buffer, nil, _maximum}),
    do: [{"host", host} | headers]

  defp request_headers(headers, host, {:buffer, body, _maximum}),
    do: [{"host", host}, {"content-length", Integer.to_string(byte_size(body))} | headers]

  defp request_headers(headers, host, {:download, _writer, _state, _expected}),
    do: [{"host", host} | headers]

  defp request_headers(headers, host, {:consume_download, _consumer, _expected, _oid}),
    do: [{"host", host} | headers]

  defp request_headers(headers, host, {:upload, _reader, _state, expected}),
    do: [{"host", host}, {"content-length", Integer.to_string(expected)} | headers]

  defp method_name(:get), do: "GET"
  defp method_name(:post), do: "POST"
  defp method_name(:put), do: "PUT"

  defp request_target(%URI{path: path, query: nil}), do: path
  defp request_target(%URI{path: path, query: query}), do: path <> "?" <> query

  defp header_bytes(headers) do
    Enum.reduce(headers, 0, fn
      {name, value}, total when is_binary(name) and is_binary(value) ->
        total + byte_size(name) + byte_size(value)

      _invalid, _total ->
        @maximum_header_bytes + 1
    end)
  end

  defp response_headers(%{headers: headers}, name) do
    Enum.flat_map(headers, fn
      {header_name, value} when is_binary(header_name) and is_binary(value) ->
        if String.downcase(header_name) == name, do: [value], else: []

      _invalid ->
        []
    end)
  end

  defp parse_content_length(value) when is_binary(value) and byte_size(value) <= 20 do
    case Integer.parse(value) do
      {length, ""} when length in 0..@maximum_object_size -> {:ok, length}
      _invalid -> :error
    end
  end

  defp parse_content_length(_value), do: :error

  defp request_timeout(opts) do
    case Keyword.get(opts, :request_timeout, @total_timeout) do
      timeout when is_integer(timeout) and timeout in 1..@total_timeout -> timeout
      _invalid -> @total_timeout
    end
  end

  defp transport_options(address, remaining) do
    family =
      case tuple_size(address) do
        4 -> [inet4: true, inet6: false]
        8 -> [inet6: true, inet4: false]
      end

    Keyword.merge(
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        timeout: max(min(@connect_timeout, remaining), 1),
        send_timeout: max(remaining, 1),
        send_timeout_close: true
      ],
      family
    )
  end

  defp transport_error_kind(%Mint.TransportError{reason: :timeout}, _deadline), do: :timeout
  defp transport_error_kind(:timeout, _deadline), do: :timeout
  defp transport_error_kind(_reason, deadline), do: deadline_or(deadline, :receive)

  defp deadline_or(deadline, fallback),
    do: if(remaining(deadline) == 0, do: :timeout, else: fallback)

  defp remaining(deadline), do: max(deadline - monotonic_ms(), 0)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp await_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp flush(reference) do
    receive do
      {^reference, :result, _result} -> flush(reference)
    after
      0 -> :ok
    end
  end

  defp safe_close(api, connection) do
    _ = api.close(connection)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
