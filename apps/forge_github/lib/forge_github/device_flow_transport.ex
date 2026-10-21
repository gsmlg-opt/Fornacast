defmodule ForgeGitHub.DeviceFlow.Transport do
  @moduledoc false

  @max_body 65_536
  @timeout 20_000
  @paths ["/login/device/code", "/login/oauth/access_token"]

  defmodule ResponseTooLarge do
    @moduledoc false
    defexception message: "GitHub Device Flow response exceeds the byte limit"
  end

  def post(path, form, opts) when path in @paths do
    timeout = Keyword.get(opts, :request_timeout, @timeout)

    if is_integer(timeout) and timeout in 1..@timeout do
      bounded_request(path, form, opts, timeout)
    else
      {:error, :invalid_request}
    end
  end

  defp bounded_request(path, form, opts, timeout) do
    parent = self()
    callers = Process.get(:"$callers", [])
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", [parent | callers])
        caller_monitor = Process.monitor(parent)
        worker = self()
        watchdog = spawn(fn -> watch_caller(parent, worker, reference) end)

        receive do
          {^reference, :watchdog_ready, ^watchdog} ->
            if Process.alive?(parent) do
              send(parent, {reference, request(path, form, opts, timeout)})
            end

          {:DOWN, ^caller_monitor, :process, ^parent, _reason} ->
            :ok
        end
      end)

    receive do
      {^reference, result} ->
        await_down(monitor, worker)
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :transport_error}
    after
      timeout ->
        Process.exit(worker, :kill)
        await_down(monitor, worker)

        receive do
          {^reference, _result} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp watch_caller(parent, worker, reference) do
    owner_monitor = Process.monitor(parent)
    worker_monitor = Process.monitor(worker)
    send(worker, {reference, :watchdog_ready, self()})

    receive do
      {:DOWN, ^owner_monitor, :process, ^parent, _reason} ->
        Process.exit(worker, :kill)
        await_down(worker_monitor, worker)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        Process.demonitor(owner_monitor, [:flush])
    end
  end

  defp await_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp request(path, form, opts, timeout) do
    request_options = [
      url: "https://github.com" <> path,
      method: :post,
      form: form,
      headers: [
        {"accept", "application/json"},
        {"accept-encoding", "identity"},
        {"user-agent", "Fornacast"}
      ],
      redirect: false,
      retry: false,
      compressed: false,
      raw: true,
      decode_body: false,
      finch: [
        conn_opts: [transport_opts: [timeout: min(5000, timeout)]],
        receive_timeout: timeout,
        pool_timeout: timeout,
        request_timeout: timeout
      ],
      into: &collect/2
    ]

    request_options =
      case Keyword.fetch(opts, :plug) do
        {:ok, plug} -> Keyword.put(request_options, :plug, plug)
        :error -> request_options
      end

    case Req.request(request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status == 200 ->
        decode(body)

      {:ok, %Req.Response{status: status, body: body}} when status in [400, 401, 403] ->
        case decode(body) do
          {:ok, %{"error" => _error} = json} -> {:ok, json}
          {:ok, _json} -> {:error, :invalid_response}
          error -> error
        end

      {:ok, %Req.Response{}} ->
        {:error, :provider_unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %ResponseTooLarge{}} ->
        {:error, :response_too_large}

      {:error, _error} ->
        {:error, :transport_error}
    end
  rescue
    ResponseTooLarge -> {:error, :response_too_large}
    _exception -> {:error, :transport_error}
  catch
    _kind, _reason -> {:error, :transport_error}
  end

  defp collect({:data, data}, {request, response}) do
    body = response.body || ""

    if byte_size(body) + byte_size(data) > @max_body do
      raise ResponseTooLarge
    else
      {:cont, {request, %{response | body: body <> data}}}
    end
  end

  defp decode(body) when is_binary(body) and byte_size(body) <= @max_body do
    case JSON.decode(body) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _invalid -> {:error, :invalid_response}
    end
  end

  defp decode(body) when is_binary(body), do: {:error, :response_too_large}
  defp decode(_body), do: {:error, :invalid_response}
end
