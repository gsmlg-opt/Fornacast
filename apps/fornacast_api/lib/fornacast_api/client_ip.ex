defmodule FornacastAPI.ClientIP do
  import Bitwise
  import Plug.Conn, only: [get_req_header: 2]

  defmodule CIDR do
    @enforce_keys [:family, :network, :prefix]
    defstruct [:family, :network, :prefix]
  end

  @type address_family :: :ipv4 | :ipv6
  @type t :: %CIDR{
          family: address_family(),
          network: non_neg_integer(),
          prefix: non_neg_integer()
        }

  @strict_ipv4 ~r/\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/

  def parse_cidrs!(values) when is_list(values), do: Enum.map(values, &normalize_cidr/1)

  def parse_cidrs!(value) do
    raise ArgumentError, "trusted_proxy_cidrs must be a list, got: #{inspect(value)}"
  end

  def parse_cidr!(value) do
    with true <- is_binary(value),
         [address_value, prefix_value] <- :binary.split(value, "/"),
         {:ok, address} <- parse_address(address_value),
         {:ok, family, bits, integer} <- address_info(address),
         {:ok, prefix} <- parse_unsigned_decimal(prefix_value),
         true <- prefix >= 0 and prefix <= bits do
      %CIDR{
        family: family,
        network: integer &&& mask(bits, prefix),
        prefix: prefix
      }
    else
      _invalid -> invalid_cidr!(value)
    end
  rescue
    _invalid -> invalid_cidr!(value)
  end

  def effective(conn, cidrs) when is_list(cidrs) do
    remote = canonical_address(conn.remote_ip)

    if trusted?(conn.remote_ip, cidrs) do
      case forwarded_chain(conn) do
        {:ok, chain} -> chain |> select_client(cidrs) |> canonical_address()
        :error -> remote
      end
    else
      remote
    end
  end

  def trusted?(address, cidrs) when is_list(cidrs) do
    with {:ok, family, bits, integer} <- address_info(address) do
      Enum.any?(cidrs, fn value ->
        cidr = normalize_cidr(value)

        cidr.family == family and
          (integer &&& mask(bits, cidr.prefix)) == cidr.network
      end)
    else
      :error -> false
    end
  end

  defp normalize_cidr(%CIDR{} = cidr), do: cidr
  defp normalize_cidr(value), do: parse_cidr!(value)

  defp forwarded_chain(conn) do
    case get_req_header(conn, "forwarded") do
      [] -> x_forwarded_for_chain(get_req_header(conn, "x-forwarded-for"))
      [value] -> parse_forwarded(value)
      _duplicate -> :error
    end
  end

  defp x_forwarded_for_chain([value]) do
    addresses = value |> :binary.split(",", [:global]) |> Enum.map(&trim_ows/1)

    with false <- addresses == [],
         true <- Enum.all?(addresses, &(&1 != "")),
         parsed when is_list(parsed) <- Enum.map(addresses, &parse_address/1),
         true <- Enum.all?(parsed, &match?({:ok, _address}, &1)) do
      {:ok, Enum.map(parsed, fn {:ok, address} -> address end)}
    else
      _invalid -> :error
    end
  end

  defp x_forwarded_for_chain(_missing_or_duplicate), do: :error

  defp parse_forwarded(value) do
    with {:ok, elements} <- split_quoted(value, ?,),
         false <- elements == [],
         {:ok, chain} <- map_ok(elements, &parse_forwarded_element/1) do
      {:ok, chain}
    else
      _invalid -> :error
    end
  end

  defp parse_forwarded_element(element) do
    with {:ok, parameters} <- split_quoted(element, ?;),
         false <- parameters == [],
         {:ok, for_values} <- forwarded_for_values(parameters),
         [value] <- for_values do
      parse_forwarded_node(value)
    else
      _invalid -> :error
    end
  end

  defp forwarded_for_values(parameters) do
    Enum.reduce_while(parameters, {:ok, MapSet.new(), []}, fn parameter,
                                                              {:ok, names, for_values} ->
      with {:ok, pieces} <- split_quoted(parameter, ?=),
           [name, value] <- pieces,
           name <- trim_ows(name),
           value <- trim_ows(value),
           true <- token?(name),
           normalized_name <- ascii_downcase(name),
           false <- MapSet.member?(names, normalized_name),
           true <- valid_parameter_value?(normalized_name, value) do
        values =
          if normalized_name == "for", do: [value | for_values], else: for_values

        {:cont, {:ok, MapSet.put(names, normalized_name), values}}
      else
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, _names, for_values} -> {:ok, for_values}
      :error -> :error
    end
  end

  defp valid_parameter_value?(normalized_name, value) do
    case unquote_value(value) do
      {:ok, unquoted} when unquoted != "" ->
        normalized_name == "for" or quoted?(value) or token?(unquoted)

      {:ok, _empty} ->
        false

      :error ->
        false
    end
  end

  defp quoted?(<<?", _rest::binary>>), do: true
  defp quoted?(_value), do: false

  defp parse_forwarded_node(value) do
    with {:ok, node} <- unquote_value(value),
         false <- ascii_downcase(node) == "unknown",
         false <- obfuscated_node?(node),
         {:ok, address} <- parse_node_address(node) do
      {:ok, address}
    else
      _invalid -> :error
    end
  end

  defp obfuscated_node?(<<"_", _rest::binary>>), do: true
  defp obfuscated_node?(_node), do: false

  defp parse_node_address("[" <> rest) do
    with [address_value, suffix] <- :binary.split(rest, "]"),
         true <- address_value != "",
         :ok <- validate_port_suffix(suffix),
         {:ok, address} <- parse_address(address_value),
         {:ok, :ipv6, _bits, _integer} <- address_info(address) do
      {:ok, address}
    else
      _invalid -> :error
    end
  end

  defp parse_node_address(node) do
    case parse_address(node) do
      {:ok, address} ->
        case address_info(address) do
          {:ok, :ipv4, _bits, _integer} -> {:ok, address}
          _ipv6_must_be_bracketed -> :error
        end

      :error ->
        parse_ipv4_with_port(node)
    end
  end

  defp parse_ipv4_with_port(node) do
    with [address_value, port_value] <- :binary.split(node, ":"),
         :ok <- validate_port(port_value),
         {:ok, address} <- parse_address(address_value),
         {:ok, :ipv4, _bits, _integer} <- address_info(address) do
      {:ok, address}
    else
      _invalid -> :error
    end
  end

  defp validate_port_suffix(""), do: :ok
  defp validate_port_suffix(":" <> port), do: validate_port(port)
  defp validate_port_suffix(_invalid), do: :error

  defp validate_port(value) do
    case parse_unsigned_decimal(value) do
      {:ok, port} when port <= 65_535 -> :ok
      _invalid -> :error
    end
  end

  defp select_client(chain, cidrs) do
    Enum.find(Enum.reverse(chain), hd(chain), fn address ->
      not trusted?(address, cidrs)
    end)
  end

  defp split_quoted(value, delimiter) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> do_split_quoted(delimiter, false, false, [], [])
  end

  defp do_split_quoted([], _delimiter, false, false, current, parts) do
    {:ok, parts |> prepend_part(current) |> Enum.reverse()}
  end

  defp do_split_quoted([], _delimiter, _quoted, _escaped, _current, _parts), do: :error

  defp do_split_quoted([character | rest], delimiter, quoted, escaped, current, parts) do
    cond do
      escaped ->
        do_split_quoted(rest, delimiter, quoted, false, [character | current], parts)

      quoted and character == ?\\ ->
        do_split_quoted(rest, delimiter, quoted, true, [character | current], parts)

      character == ?" ->
        do_split_quoted(rest, delimiter, not quoted, false, [character | current], parts)

      not quoted and character == delimiter ->
        do_split_quoted(rest, delimiter, false, false, [], prepend_part(parts, current))

      true ->
        do_split_quoted(rest, delimiter, quoted, false, [character | current], parts)
    end
  end

  defp prepend_part(parts, current) do
    [current |> Enum.reverse() |> :erlang.list_to_binary() |> trim_ows() | parts]
  end

  defp unquote_value(<<?", rest::binary>>) do
    size = byte_size(rest)

    if size > 0 and :binary.at(rest, size - 1) == ?" do
      rest |> binary_part(0, size - 1) |> unescape_quoted()
    else
      :error
    end
  end

  defp unquote_value(value) do
    if :binary.match(value, "\"") != :nomatch or :binary.match(value, "\\") != :nomatch do
      :error
    else
      {:ok, value}
    end
  end

  defp unescape_quoted(value) do
    value
    |> :binary.bin_to_list()
    |> do_unescape_quoted([])
  end

  defp do_unescape_quoted([], result),
    do: {:ok, result |> Enum.reverse() |> :erlang.list_to_binary()}

  defp do_unescape_quoted([?\\, character | rest], result) do
    if valid_quoted_pair_character?(character) do
      do_unescape_quoted(rest, [character | result])
    else
      :error
    end
  end

  defp do_unescape_quoted([?\\], _result), do: :error

  defp do_unescape_quoted([character | rest], result) do
    if valid_quoted_text_character?(character) do
      do_unescape_quoted(rest, [character | result])
    else
      :error
    end
  end

  defp valid_quoted_text_character?(character) do
    character == ?\t or character == ?\s or character == ?! or
      character in ?#..?\[ or character in ?\]..?~ or character >= 128
  end

  defp valid_quoted_pair_character?(character) do
    character == ?\t or character in ?\s..?~ or character >= 128
  end

  defp trim_ows(value), do: value |> trim_leading_ows() |> trim_trailing_ows()

  defp trim_leading_ows(<<character, rest::binary>>) when character in [?\s, ?\t],
    do: trim_leading_ows(rest)

  defp trim_leading_ows(value), do: value

  defp trim_trailing_ows(<<>>), do: ""

  defp trim_trailing_ows(value) do
    last_index = byte_size(value) - 1

    if :binary.at(value, last_index) in [?\s, ?\t] do
      value |> binary_part(0, last_index) |> trim_trailing_ows()
    else
      value
    end
  end

  defp token?(value) when is_binary(value) and byte_size(value) > 0 do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&token_character?/1)
  end

  defp token?(_value), do: false

  defp token_character?(character) do
    character in ?0..?9 or character in ?A..?Z or character in ?a..?z or
      character in [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126]
  end

  defp ascii_downcase(value) do
    for <<character <- value>>, into: <<>> do
      if character in ?A..?Z, do: <<character + 32>>, else: <<character>>
    end
  end

  defp ascii?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 <= 127))
  end

  defp map_ok(values, function) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case function.(value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | result]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      :error -> :error
    end
  end

  defp parse_address(value) when is_binary(value) do
    if ascii?(value) do
      if :binary.match(value, ":") == :nomatch do
        parse_ipv4_address(value)
      else
        parse_ipv6_address(value)
      end
    else
      :error
    end
  end

  defp parse_ipv4_address(value) do
    with true <- ascii?(value),
         true <- Regex.match?(@strict_ipv4, value),
         {:ok, octets} <-
           map_ok(:binary.split(value, ".", [:global]), &parse_unsigned_decimal/1),
         true <- Enum.all?(octets, &(&1 <= 255)) do
      {:ok, List.to_tuple(octets)}
    else
      _invalid -> :error
    end
  end

  defp parse_ipv6_address(value) do
    with :ok <- validate_embedded_ipv4(value),
         {:ok, address} <- inet_parse_address(value),
         true <- tuple_size(address) == 8 do
      {:ok, address}
    else
      _invalid -> :error
    end
  end

  defp validate_embedded_ipv4(value) do
    if :binary.match(value, ".") != :nomatch do
      value
      |> :binary.split(":", [:global])
      |> List.last()
      |> parse_ipv4_address()
      |> case do
        {:ok, _address} -> :ok
        :error -> :error
      end
    else
      :ok
    end
  end

  defp inet_parse_address(value) do
    case :inet.parse_address(:binary.bin_to_list(value)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp parse_unsigned_decimal(value) do
    if unsigned_decimal?(value) do
      case Integer.parse(value) do
        {integer, ""} -> {:ok, integer}
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp unsigned_decimal?(value) when is_binary(value) and byte_size(value) > 0 do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in ?0..?9))
  end

  defp unsigned_decimal?(_value), do: false

  defp address_info(address) when is_tuple(address) and tuple_size(address) == 4 do
    parts = Tuple.to_list(address)

    if Enum.all?(parts, &valid_part?(&1, 255)) do
      {:ok, :ipv4, 32, to_integer(parts, 8)}
    else
      :error
    end
  end

  defp address_info(address) when is_tuple(address) and tuple_size(address) == 8 do
    parts = Tuple.to_list(address)

    if Enum.all?(parts, &valid_part?(&1, 65_535)) do
      {:ok, :ipv6, 128, to_integer(parts, 16)}
    else
      :error
    end
  end

  defp address_info(_invalid), do: :error

  defp valid_part?(part, maximum), do: is_integer(part) and part >= 0 and part <= maximum

  defp to_integer(parts, width) do
    Enum.reduce(parts, 0, fn part, integer -> integer <<< width ||| part end)
  end

  defp mask(_bits, 0), do: 0
  defp mask(bits, prefix), do: ((1 <<< prefix) - 1) <<< (bits - prefix)

  defp canonical_address(address) do
    address
    |> :inet.ntoa()
    |> List.to_string()
    |> String.downcase()
  end

  defp invalid_cidr!(value) do
    raise ArgumentError, "invalid trusted proxy CIDR #{inspect(value)}"
  end
end
