defmodule ForgeImports.GitHub.HostPolicy do
  @moduledoc "DNS policy for the fixed public GitHub API host."

  import Bitwise

  @host "api.github.com"
  @default_timeout 20_000

  @spec validate(keyword()) :: :ok | {:error, :host_unavailable | :unsafe_host | :timeout}
  def validate(opts \\ []) do
    case resolve_public(opts) do
      {:ok, _addresses} -> :ok
      error -> error
    end
  end

  @doc false
  @spec resolve_public(keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, :host_unavailable | :unsafe_host | :timeout}
  def resolve_public(opts \\ []) do
    resolver = Keyword.get(opts, :resolver, &resolve/1)
    deadline = Keyword.get(opts, :deadline, monotonic_ms() + @default_timeout)

    case resolve_before_deadline(resolver, deadline) do
      {:ok, addresses} when is_list(addresses) and addresses != [] ->
        if Enum.all?(addresses, &public_address?/1),
          do: {:ok, addresses},
          else: {:error, :unsafe_host}

      {:error, :timeout} ->
        {:error, :timeout}

      _error ->
        {:error, :host_unavailable}
    end
  end

  defp resolve_before_deadline(resolver, deadline)
       when is_function(resolver, 1) and is_integer(deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      _time_available ->
        parent = self()
        reference = make_ref()
        callers = Process.get(:"$callers", [])

        {worker, monitor} =
          spawn_monitor(fn ->
            Process.put(:"$callers", [parent | callers])

            receive do
              {^reference, :start} ->
                send(parent, {reference, safe_resolve(resolver)})
            end
          end)

        watchdog = spawn(fn -> watch_caller(parent, worker, reference) end)

        case await_watchdog(reference, watchdog, worker, monitor, deadline) do
          :ok ->
            send(worker, {reference, :start})
            await_resolution(reference, worker, monitor, deadline)

          error ->
            error
        end
    end
  end

  defp resolve_before_deadline(_resolver, _deadline), do: {:error, :host_unavailable}

  defp safe_resolve(resolver) do
    resolver.(@host)
  rescue
    _exception -> {:error, :host_unavailable}
  catch
    _kind, _reason -> {:error, :host_unavailable}
  end

  defp await_resolution(reference, worker, monitor, deadline) do
    timeout = remaining(deadline)

    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :host_unavailable}
    after
      timeout ->
        Process.exit(worker, :kill)
        await_down(monitor, worker)
        flush(reference)
        {:error, :timeout}
    end
  end

  defp await_watchdog(reference, watchdog, worker, monitor, deadline) do
    timeout = remaining(deadline)

    receive do
      {^reference, :watchdog_ready, ^watchdog} ->
        :ok

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :host_unavailable}
    after
      timeout ->
        Process.exit(worker, :kill)
        await_down(monitor, worker)
        flush(reference)
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

  defp await_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp flush(reference) do
    receive do
      {^reference, _result} -> flush(reference)
      {^reference, _state, _value} -> flush(reference)
    after
      0 -> :ok
    end
  end

  defp remaining(deadline), do: max(deadline - monotonic_ms(), 0)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp resolve(host) do
    host = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host, family) do
          {:ok, values} -> values
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end

  @doc false
  def public_address?({a, b, c, d} = address)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not non_public_ipv4?(address)
  end

  def public_address?({a, b, c, d, e, f, g, h})
      when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
             e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535 do
    globally_routable_ipv6?({a, b, c, d, e, f, g, h})
  end

  def public_address?(_address), do: false

  defp non_public_ipv4?({a, b, c, _d}) do
    a == 0 or a == 10 or a == 127 or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 0 and c in [0, 2]) or
      (a == 192 and b == 168) or
      (a == 192 and b == 88 and c == 99) or
      (a == 198 and b in [18, 19]) or
      (a == 198 and b == 51 and c == 100) or
      (a == 203 and b == 0 and c == 113) or
      a >= 224
  end

  defp globally_routable_ipv6?({a, b, _c, _d, _e, _f, _g, _h}) do
    (a &&& 0xE000) == 0x2000 and
      a != 0x2002 and
      not (a == 0x2001 and b <= 0x01FF) and
      not (a == 0x2001 and b == 0x0DB8) and
      not (a == 0x3FFF and (b &&& 0xF000) == 0)
  end
end
