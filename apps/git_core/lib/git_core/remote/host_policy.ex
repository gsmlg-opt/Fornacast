defmodule GitCore.Remote.HostPolicy do
  @moduledoc false

  import Bitwise

  @host "github.com"
  @ipv4_blocked [
    {0x00000000, 8},
    {0x0A000000, 8},
    {0x64400000, 10},
    {0x7F000000, 8},
    {0xA9FE0000, 16},
    {0xAC100000, 12},
    {0xC0000000, 24},
    {0xC0000200, 24},
    {0xC0586300, 24},
    {0xC0A80000, 16},
    {0xC6120000, 15},
    {0xC6336400, 24},
    {0xCB007100, 24},
    {0xE0000000, 4},
    {0xF0000000, 4}
  ]
  @ipv6_blocked [
    {0x00000000000000000000000000000000, 128},
    {0x00000000000000000000000000000001, 128},
    {0x00000000000000000000FFFF00000000, 96},
    {0x0064FF9B000000000000000000000000, 96},
    {0x0064FF9B000100000000000000000000, 48},
    {0x01000000000000000000000000000000, 64},
    {0x20010000000000000000000000000000, 23},
    {0x20010DB8000000000000000000000000, 32},
    {0x20020000000000000000000000000000, 16},
    {0x3FFF0000000000000000000000000000, 20},
    {0xFC000000000000000000000000000000, 7},
    {0xFE800000000000000000000000000000, 10},
    {0xFF000000000000000000000000000000, 8}
  ]
  @ipv6_global_unicast {0x20000000000000000000000000000000, 3}

  defmodule Result do
    @moduledoc false
    @enforce_keys [:addresses, :curlopt_resolve]
    defstruct @enforce_keys
  end

  @doc false
  def resolve_github(resolver \\ &__MODULE__.system_resolve/2)

  def resolve_github(resolver) when is_function(resolver, 2) do
    with {:ok, ipv4} <- resolve_family(resolver, :a),
         {:ok, ipv6} <- resolve_family(resolver, :aaaa),
         addresses when addresses != [] <- Enum.uniq(ipv4 ++ ipv6),
         true <- Enum.all?(addresses, &public_address?/1) do
      rendered = addresses |> Enum.map(&render_address/1) |> Enum.sort()

      {:ok,
       %Result{
         addresses: addresses,
         curlopt_resolve: "#{@host}:443:#{Enum.join(rendered, ",")}"
       }}
    else
      _unsafe -> {:error, :host_policy}
    end
  end

  def resolve_github(_resolver), do: {:error, :host_policy}

  @doc false
  def system_resolve(host, family) when host == @host and family in [:a, :aaaa] do
    :inet_res.lookup(String.to_charlist(host), :in, family)
  end

  @doc false
  def public_address?({a, b, c, d} = address)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    value = ipv4_integer(address)
    not Enum.any?(@ipv4_blocked, &in_prefix?(value, 32, &1))
  end

  def public_address?({a, b, c, d, e, f, g, h} = address)
      when a in 0..0xFFFF and b in 0..0xFFFF and c in 0..0xFFFF and d in 0..0xFFFF and
             e in 0..0xFFFF and f in 0..0xFFFF and g in 0..0xFFFF and h in 0..0xFFFF do
    value = ipv6_integer(address)

    in_prefix?(value, 128, @ipv6_global_unicast) and
      not Enum.any?(@ipv6_blocked, &in_prefix?(value, 128, &1))
  end

  def public_address?(_address), do: false

  defp resolve_family(resolver, family) do
    case resolver.(@host, family) do
      addresses when is_list(addresses) -> {:ok, addresses}
      {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
      _error -> {:error, :dns_unavailable}
    end
  rescue
    _error -> {:error, :dns_unavailable}
  catch
    _kind, _reason -> {:error, :dns_unavailable}
  end

  defp render_address({_, _, _, _} = address), do: address |> :inet.ntoa() |> to_string()

  defp render_address({_, _, _, _, _, _, _, _} = address),
    do: "[#{address |> :inet.ntoa() |> to_string()}]"

  defp ipv4_integer({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp ipv6_integer({a, b, c, d, e, f, g, h}) do
    Enum.reduce([a, b, c, d, e, f, g, h], 0, fn segment, value ->
      value <<< 16 ||| segment
    end)
  end

  defp in_prefix?(value, bits, {base, prefix}) do
    shift = bits - prefix
    value >>> shift == base >>> shift
  end
end
