defmodule ForgeImports.GitHub.Pagination do
  @moduledoc false

  @max_link_bytes 8_192
  @max_links 20
  @token ~r/^[!#$%&'*+\-.^_|~0-9A-Za-z]+$/u
  @parameter ~r/^([!#$%&'*+\-.^_|~0-9A-Za-z]+)\s*=\s*(?:"([^"\\]*)"|([!#$%&'*+\-.^_|~0-9A-Za-z]+))$/u

  @spec next_url(Req.Response.t(), [String.t()]) ::
          {:ok, String.t() | nil} | {:error, :invalid_pagination}
  def next_url(%Req.Response{} = response, allowed_paths) when is_list(allowed_paths) do
    values = Req.Response.get_header(response, "link")

    with true <- valid_allowed_paths?(allowed_paths) do
      parse_values(values, allowed_paths)
    else
      _invalid -> {:error, :invalid_pagination}
    end
  end

  def next_url(_response, _allowed_paths), do: {:error, :invalid_pagination}

  defp parse_values(values, allowed_paths) do
    case values do
      [] ->
        {:ok, nil}

      values ->
        with true <- Enum.all?(values, &is_binary/1),
             encoded <- Enum.join(values, ","),
             :ok <- validate_encoded(encoded, values),
             {:ok, entries} <- split_entries(encoded),
             true <- length(entries) <= @max_links,
             {:ok, next_paths} <- parse_entries(entries, allowed_paths) do
          case next_paths do
            [] -> {:ok, nil}
            [next_path] -> {:ok, next_path}
            _duplicates -> {:error, :invalid_pagination}
          end
        else
          _invalid -> {:error, :invalid_pagination}
        end
    end
  end

  defp valid_allowed_paths?(paths) do
    paths != [] and length(paths) <= 2 and length(paths) == length(Enum.uniq(paths)) and
      Enum.all?(paths, fn path ->
        is_binary(path) and byte_size(path) <= 2_048 and String.starts_with?(path, "/") and
          not String.starts_with?(path, "//")
      end)
  end

  defp validate_encoded(encoded, _values) do
    if encoded != "" and byte_size(encoded) <= @max_link_bytes and String.valid?(encoded) and
         Enum.all?([<<0>>, "\r", "\n"], &(:binary.match(encoded, &1) == :nomatch)),
       do: :ok,
       else: :error
  end

  defp split_entries(encoded) do
    encoded
    |> :binary.bin_to_list()
    |> Enum.reduce_while({:ok, [], [], false, false, false}, fn
      byte, {:ok, entries, current, quoted?, angled?, escaped?} ->
        cond do
          escaped? ->
            {:cont, {:ok, entries, [byte | current], quoted?, angled?, false}}

          quoted? and byte == ?\\ ->
            {:cont, {:ok, entries, [byte | current], true, angled?, true}}

          not angled? and byte == ?" ->
            {:cont, {:ok, entries, [byte | current], not quoted?, false, false}}

          not quoted? and byte == ?< and not angled? ->
            {:cont, {:ok, entries, [byte | current], false, true, false}}

          not quoted? and byte == ?> and angled? ->
            {:cont, {:ok, entries, [byte | current], false, false, false}}

          not quoted? and byte in [?<, ?>] ->
            {:halt, :error}

          byte == ?, and not quoted? and not angled? ->
            case finish_part(current) do
              {:ok, entry} -> {:cont, {:ok, [entry | entries], [], false, false, false}}
              :error -> {:halt, :error}
            end

          true ->
            {:cont, {:ok, entries, [byte | current], quoted?, angled?, false}}
        end
    end)
    |> case do
      {:ok, entries, current, false, false, false} ->
        case finish_part(current) do
          {:ok, entry} -> {:ok, Enum.reverse([entry | entries])}
          :error -> :error
        end

      _invalid ->
        :error
    end
  end

  defp finish_part(bytes) do
    value = bytes |> Enum.reverse() |> :erlang.list_to_binary() |> String.trim()
    if value == "", do: :error, else: {:ok, value}
  end

  defp parse_entries(entries, allowed_paths) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, next_paths} ->
      with {:ok, target, parameters} <- parse_entry(entry),
           {:ok, relation_tokens} <- parse_parameters(parameters),
           {:ok, path} <- validate_target(target, allowed_paths) do
        next_paths =
          if "next" in relation_tokens,
            do: [path | next_paths],
            else: next_paths

        {:cont, {:ok, next_paths}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp parse_entry("<" <> rest) do
    case :binary.match(rest, ">") do
      {index, 1} when index > 0 ->
        <<target::binary-size(^index), ">", parameters::binary>> = rest

        if :binary.match(target, "<") == :nomatch,
          do: {:ok, target, String.trim(parameters)},
          else: :error

      _missing ->
        :error
    end
  end

  defp parse_entry(_entry), do: :error

  defp parse_parameters(""), do: {:ok, []}

  defp parse_parameters(parameters) do
    with true <- String.starts_with?(parameters, ";"),
         {:ok, parts} <- split_parameters(String.trim_leading(parameters, ";")),
         true <- parts != [] do
      Enum.reduce_while(parts, {:ok, %{}}, fn part, {:ok, parsed} ->
        case Regex.run(@parameter, String.trim(part), capture: :all_but_first) do
          [name, quoted] ->
            put_parameter(parsed, name, quoted)

          [name, quoted, token] ->
            put_parameter(parsed, name, if(quoted == "", do: token, else: quoted))

          _invalid ->
            {:halt, :error}
        end
      end)
      |> relation_tokens()
    else
      _invalid -> :error
    end
  end

  defp put_parameter(parsed, name, value) do
    name = String.downcase(name)

    if Map.has_key?(parsed, name),
      do: {:halt, :error},
      else: {:cont, {:ok, Map.put(parsed, name, value)}}
  end

  defp split_parameters(parameters) do
    parameters
    |> :binary.bin_to_list()
    |> Enum.reduce_while({:ok, [], [], false}, fn
      ?", {:ok, parts, current, quoted?} ->
        {:cont, {:ok, parts, [?" | current], not quoted?}}

      ?;, {:ok, parts, current, false} ->
        case finish_part(current) do
          {:ok, part} -> {:cont, {:ok, [part | parts], [], false}}
          :error -> {:halt, :error}
        end

      byte, {:ok, parts, current, quoted?} ->
        {:cont, {:ok, parts, [byte | current], quoted?}}
    end)
    |> case do
      {:ok, parts, current, false} ->
        case finish_part(current) do
          {:ok, part} -> {:ok, Enum.reverse([part | parts])}
          :error -> :error
        end

      _invalid ->
        :error
    end
  end

  defp relation_tokens({:ok, parameters}) do
    case Map.get(parameters, "rel") do
      nil ->
        {:ok, []}

      relation ->
        tokens = String.split(relation)

        if tokens != [] and Enum.all?(tokens, &Regex.match?(@token, &1)),
          do: {:ok, Enum.map(tokens, &String.downcase/1)},
          else: :error
    end
  end

  defp relation_tokens(:error), do: :error

  defp validate_target(target, allowed_paths) do
    with true <- byte_size(target) <= 4_096 and String.valid?(target),
         {:ok, uri} <- URI.new(target),
         "https" <- String.downcase(uri.scheme || ""),
         "api.github.com" <- String.downcase(uri.host || ""),
         443 <- uri.port,
         nil <- uri.userinfo,
         true <- uri.path in allowed_paths,
         nil <- uri.fragment do
      {:ok, uri.path <> if(uri.query, do: "?" <> uri.query, else: "")}
    else
      _invalid -> :error
    end
  end
end
