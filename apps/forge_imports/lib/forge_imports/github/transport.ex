defmodule ForgeImports.GitHub.Transport do
  @moduledoc false

  alias ForgeImports.GitHub.HostPolicy

  @host "api.github.com"
  @port 443
  @connect_timeout 5_000
  @total_timeout 20_000
  @max_body_bytes 2_000_000
  @max_header_bytes 65_536

  defmodule Error do
    @moduledoc false
    defexception [:kind]

    @impl Exception
    def message(%__MODULE__{kind: :invalid_request}), do: "invalid GitHub transport request"
    def message(%__MODULE__{kind: :connect}), do: "GitHub connection failed"
    def message(%__MODULE__{kind: :send}), do: "GitHub request send failed"
    def message(%__MODULE__{kind: :receive}), do: "GitHub response receive failed"
    def message(%__MODULE__{kind: :timeout}), do: "GitHub request timed out"
    def message(%__MODULE__{kind: :response_too_large}), do: "GitHub response was too large"
    def message(%__MODULE__{}), do: "GitHub transport failed"
  end

  defimpl Inspect, for: Error do
    import Inspect.Algebra

    def inspect(error, opts),
      do: concat(["#GitHub.Transport.Error<", to_doc(error.kind, opts), ">"])
  end

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    with :ok <- validate_request(request),
         {:ok, addresses} <- addresses(request),
         {:ok, timeout} <- timeout(request) do
      api = Req.Request.get_private(request, :forge_imports_transport_api, Mint.HTTP)
      deadline = monotonic_ms() + timeout
      run_with_deadline(request, api, addresses, deadline)
    else
      _invalid -> {request, %Error{kind: :invalid_request}}
    end
  rescue
    _exception -> {request, %Error{kind: :connect}}
  catch
    _kind, _reason -> {request, %Error{kind: :connect}}
  end

  defp run_with_deadline(request, api, addresses, deadline) do
    parent = self()
    reference = make_ref()
    callers = Process.get(:"$callers", [])

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", [parent | callers])

        receive do
          {^reference, :start} ->
            result = execute_transport(request, api, addresses, deadline)
            send(parent, {reference, :result, result})
        end
      end)

    watchdog = spawn(fn -> watch_caller(parent, worker, reference) end)

    case await_watchdog(reference, watchdog, worker, monitor, deadline) do
      :ok ->
        send(worker, {reference, :start})
        await_result(request, reference, worker, monitor, deadline)

      {:error, kind} ->
        {request, %Error{kind: kind}}
    end
  end

  defp execute_transport(request, api, addresses, deadline) do
    case connect(request, api, addresses, deadline) do
      {^request, response_or_error} -> response_or_error
      _invalid -> %Error{kind: :connect}
    end
  rescue
    _exception -> %Error{kind: :connect}
  catch
    _kind, _reason -> %Error{kind: :connect}
  end

  defp await_result(request, reference, worker, monitor, deadline) do
    timeout = remaining(deadline)

    receive do
      {^reference, :result, result} ->
        await_down(monitor, worker)

        if remaining(deadline) == 0,
          do: {request, %Error{kind: :timeout}},
          else: {request, result}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {request, %Error{kind: :connect}}
    after
      timeout ->
        stop_worker(worker, monitor, reference)
        {request, %Error{kind: :timeout}}
    end
  end

  defp await_watchdog(reference, watchdog, worker, monitor, deadline) do
    timeout = remaining(deadline)

    receive do
      {^reference, :watchdog_ready, ^watchdog} ->
        :ok

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :connect}
    after
      timeout ->
        stop_worker(worker, monitor, reference)
        {:error, :timeout}
    end
  end

  defp watch_caller(parent, worker, reference) do
    parent_monitor = Process.monitor(parent)
    worker_monitor = Process.monitor(worker)
    send(parent, {reference, :watchdog_ready, self()})

    receive do
      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        Process.exit(worker, :kill)
        await_down(worker_monitor, worker)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        Process.demonitor(parent_monitor, [:flush])
        :ok
    end
  end

  defp stop_worker(worker, monitor, reference) do
    Process.exit(worker, :kill)
    await_down(monitor, worker)
    flush(reference)
  end

  defp await_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp flush(reference) do
    receive do
      {^reference, _state, _value} -> flush(reference)
    after
      0 -> :ok
    end
  end

  defp connect(request, api, addresses, deadline) do
    connect_addresses(request, api, addresses, deadline)
  end

  defp connect_addresses(request, _api, [], deadline) do
    {request, %Error{kind: deadline_or(deadline, :connect)}}
  end

  defp connect_addresses(request, api, [address | rest], deadline) do
    case remaining(deadline) do
      0 ->
        {request, %Error{kind: :timeout}}

      remaining ->
        options = [
          hostname: @host,
          mode: :passive,
          protocols: [:http1],
          log: false,
          max_header_list_size: @max_header_bytes,
          transport_opts: transport_options(address, remaining)
        ]

        case api.connect(:https, address, @port, options) do
          {:ok, connection} ->
            connected_result(request, api, connection, deadline)

          {:error, reason} when rest == [] ->
            {request, %Error{kind: transport_error_kind(reason, :connect, deadline)}}

          {:error, _reason} ->
            connect_addresses(request, api, rest, deadline)

          _invalid when rest == [] ->
            {request, %Error{kind: deadline_or(deadline, :connect)}}

          _invalid ->
            connect_addresses(request, api, rest, deadline)
        end
    end
  end

  defp connected_result(request, api, connection, deadline) do
    result =
      try do
        perform_request(request, api, connection, deadline)
      rescue
        _exception -> %Error{kind: :receive}
      catch
        _kind, _reason -> %Error{kind: :receive}
      after
        safe_close(api, connection)
      end

    {request, result}
  end

  defp perform_request(request, api, connection, deadline) do
    headers =
      request.headers
      |> Req.Fields.get_list()
      |> put_host_header()

    case remaining(deadline) do
      0 ->
        %Error{kind: :timeout}

      _remaining ->
        case api.request(connection, "GET", request_target(request.url), headers, nil) do
          {:ok, connection, reference} ->
            receive_response(api, connection, reference, deadline, empty_response())

          {:error, _connection, reason} ->
            %Error{kind: transport_error_kind(reason, :send, deadline)}

          _invalid ->
            %Error{kind: :send}
        end
    end
  end

  defp receive_response(api, connection, reference, deadline, state) do
    case remaining(deadline) do
      0 ->
        %Error{kind: :timeout}

      timeout ->
        case api.recv(connection, 0, timeout) do
          {:ok, next_connection, responses} ->
            case consume(responses, reference, state) do
              {:done, state} -> build_response(state)
              {:cont, state} -> receive_response(api, next_connection, reference, deadline, state)
              {:error, kind} -> %Error{kind: kind}
            end

          {:error, _next_connection, reason, responses} ->
            case consume(responses, reference, state) do
              {:error, :response_too_large} -> %Error{kind: :response_too_large}
              _other -> %Error{kind: transport_error_kind(reason, :receive, deadline)}
            end

          _invalid ->
            %Error{kind: :receive}
        end
    end
  end

  defp consume(responses, reference, state) when is_list(responses) do
    Enum.reduce_while(responses, {:cont, state}, fn
      {:status, ^reference, status}, {:cont, %{status: nil} = state}
      when is_integer(status) and status in 100..599 ->
        {:cont, {:cont, %{state | status: status}}}

      {:headers, ^reference, headers}, {:cont, state} when is_list(headers) ->
        header_size = state.header_size + header_bytes(headers)

        if header_size <= @max_header_bytes do
          {:cont,
           {:cont, %{state | headers: [headers | state.headers], header_size: header_size}}}
        else
          {:halt, {:error, :receive}}
        end

      {:data, ^reference, data}, {:cont, state} when is_binary(data) ->
        size = state.size + byte_size(data)

        if size > @max_body_bytes do
          {:halt, {:error, :response_too_large}}
        else
          {:cont, {:cont, %{state | size: size, chunks: [data | state.chunks]}}}
        end

      {:done, ^reference}, {:cont, state} ->
        {:halt, {:done, state}}

      {:error, ^reference, _reason}, {:cont, _state} ->
        {:halt, {:error, :receive}}

      _unexpected, {:cont, _state} ->
        {:halt, {:error, :receive}}
    end)
  end

  defp consume(_responses, _reference, _state), do: {:error, :receive}

  defp build_response(%{status: status} = state) when is_integer(status) do
    Req.Response.new(
      status: status,
      headers: state.headers |> Enum.reverse() |> List.flatten(),
      body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    )
  end

  defp build_response(_state), do: %Error{kind: :receive}

  defp empty_response, do: %{status: nil, headers: [], header_size: 0, chunks: [], size: 0}

  defp validate_request(%Req.Request{
         method: :get,
         body: nil,
         url:
           %URI{
             scheme: "https",
             host: @host,
             port: @port,
             userinfo: nil,
             fragment: nil,
             path: path
           } = uri
       })
       when is_binary(path) and path != "" and byte_size(path) <= 2_048 do
    target = request_target(uri)

    if byte_size(target) <= 4_096 and String.valid?(target) and
         Enum.all?([<<0>>, "\r", "\n"], &(:binary.match(target, &1) == :nomatch)),
       do: :ok,
       else: :error
  end

  defp validate_request(_request), do: :error

  defp addresses(request) do
    case Req.Request.get_private(request, :forge_imports_github_addresses) do
      addresses when is_list(addresses) and addresses != [] ->
        if Enum.all?(addresses, &HostPolicy.public_address?/1),
          do: {:ok, addresses},
          else: :error

      _invalid ->
        :error
    end
  end

  defp timeout(request) do
    case Req.Request.get_private(request, :forge_imports_transport_timeout, @total_timeout) do
      timeout when is_integer(timeout) and timeout in 1..@total_timeout -> {:ok, timeout}
      _invalid -> :error
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

  defp put_host_header(headers) do
    headers =
      Enum.reject(headers, fn
        {name, _value} when is_binary(name) -> String.downcase(name) == "host"
        _invalid -> false
      end)

    [{"host", @host} | headers]
  end

  defp request_target(%URI{path: path, query: nil}), do: path
  defp request_target(%URI{path: path, query: query}), do: path <> "?" <> query

  defp header_bytes(headers) do
    Enum.reduce(headers, 0, fn
      {name, value}, total when is_binary(name) and is_binary(value) ->
        total + byte_size(name) + byte_size(value)

      _invalid, _total ->
        @max_header_bytes + 1
    end)
  end

  defp transport_error_kind(%Mint.TransportError{reason: :timeout}, _fallback, _deadline),
    do: :timeout

  defp transport_error_kind(:timeout, _fallback, _deadline), do: :timeout
  defp transport_error_kind(_reason, fallback, deadline), do: deadline_or(deadline, fallback)

  defp deadline_or(deadline, fallback),
    do: if(remaining(deadline) == 0, do: :timeout, else: fallback)

  defp remaining(deadline), do: max(deadline - monotonic_ms(), 0)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp safe_close(api, connection) do
    _ = api.close(connection)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
