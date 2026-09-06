defmodule ForgeGitHub.LFS.EgressPolicy do
  @moduledoc "DNS and public-address policy for provider-issued LFS action URLs."

  @default_timeout 20_000
  @maximum_host_bytes 253

  @spec resolve_public(String.t(), keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, :host_unavailable | :unsafe_host | :timeout}
  def resolve_public(host, opts \\ []) do
    with true <- valid_host?(host),
         {:ok, addresses} <- resolve_before_deadline(host, opts),
         true <-
           addresses != [] and Enum.all?(addresses, &ForgeGitHub.HostPolicy.public_address?/1) do
      {:ok, Enum.uniq(addresses)}
    else
      {:error, :timeout} -> {:error, :timeout}
      {:error, :host_unavailable} -> {:error, :host_unavailable}
      _unsafe -> {:error, :unsafe_host}
    end
  end

  @doc false
  @spec valid_host?(term()) :: boolean()
  def valid_host?(host) when is_binary(host) and byte_size(host) in 1..@maximum_host_bytes do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      {:error, :einval} -> valid_dns_name?(host)
    end
  end

  def valid_host?(_host), do: false

  defp valid_dns_name?(host) do
    host == String.downcase(host) and String.contains?(host, ".") and
      not String.ends_with?(host, ".") and
      host
      |> String.split(".")
      |> Enum.all?(&valid_label?/1)
  end

  defp valid_label?(label) when byte_size(label) in 1..63 do
    String.match?(label, ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)
  end

  defp valid_label?(_label), do: false

  defp resolve_before_deadline(host, opts) do
    resolver = Keyword.get(opts, :resolver, &resolve/1)
    deadline = Keyword.get(opts, :deadline, monotonic_ms() + @default_timeout)

    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout when is_function(resolver, 1) ->
        task = Task.async(fn -> safe_resolve(resolver, host) end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, addresses}} when is_list(addresses) -> {:ok, addresses}
          {:ok, _error} -> {:error, :host_unavailable}
          nil -> {:error, :timeout}
        end

      _invalid ->
        {:error, :host_unavailable}
    end
  end

  defp safe_resolve(resolver, host) do
    resolver.(host)
  rescue
    _exception -> {:error, :host_unavailable}
  catch
    _kind, _reason -> {:error, :host_unavailable}
  end

  defp resolve(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, :einval} ->
        host = String.to_charlist(host)

        addresses =
          [:inet, :inet6]
          |> Enum.flat_map(fn family ->
            case :inet.getaddrs(host, family) do
              {:ok, values} -> values
              {:error, _reason} -> []
            end
          end)

        if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
    end
  end

  defp remaining(deadline) when is_integer(deadline), do: max(deadline - monotonic_ms(), 0)
  defp remaining(_deadline), do: 0
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
