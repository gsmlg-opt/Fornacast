defmodule ForgeAccounts.GitHubCredentialCallback do
  @moduledoc false

  @max_reason_depth 6
  @max_reason_nodes 64
  @max_reason_atom_bytes 120
  @max_stack_depth 12
  @max_stack_nodes 512
  @max_exception_binary_bytes 65_536

  @type result :: :ok | {:error, atom() | tuple() | list()} | :unsafe

  @spec invoke((binary() -> term()), binary(), module()) :: result()
  def invoke(callback, credential, sanitized_exception)
      when is_function(callback, 1) and is_binary(credential) and is_atom(sanitized_exception) do
    callback
    |> invoke_callback(credential, sanitized_exception)
    |> validate_result(credential)
  end

  defp invoke_callback(callback, credential, sanitized_exception) do
    callback.(credential)
  rescue
    error ->
      stacktrace = __STACKTRACE__

      if credential_in_exception?(error, credential) or
           credential_in_stacktrace?(stacktrace, credential) do
        raise_sanitized(sanitized_exception)
      else
        reraise error, stacktrace
      end
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      if credential_in_term?(reason, credential) != false or
           credential_in_stacktrace?(stacktrace, credential) do
        raise_sanitized(sanitized_exception)
      else
        :erlang.raise(kind, reason, stacktrace)
      end
  end

  defp raise_sanitized(exception), do: raise(exception)

  defp validate_result(:ok, _credential), do: :ok

  defp validate_result({:error, reason} = result, credential) do
    if safe_reason?(reason, credential), do: result, else: :unsafe
  end

  defp validate_result(_result, _credential), do: :unsafe

  defp safe_reason?(reason, credential) when is_atom(reason) do
    safe_reason_atom?(reason, credential)
  end

  defp safe_reason?(reason, credential) when is_tuple(reason) or is_list(reason) do
    match?(
      {:ok, _remaining},
      scan_safe_reason(reason, credential, @max_reason_depth, @max_reason_nodes)
    )
  end

  defp safe_reason?(_reason, _credential), do: false

  defp scan_safe_reason(_term, _credential, _depth, remaining) when remaining <= 0, do: :error
  defp scan_safe_reason(_term, _credential, depth, _remaining) when depth < 0, do: :error

  defp scan_safe_reason(term, credential, _depth, remaining) when is_atom(term) do
    if safe_reason_atom?(term, credential), do: {:ok, remaining - 1}, else: :error
  end

  defp scan_safe_reason(term, _credential, _depth, remaining) when is_integer(term) do
    {:ok, remaining - 1}
  end

  defp scan_safe_reason(term, credential, depth, remaining) when is_tuple(term) and depth > 0 do
    size = tuple_size(term)

    if size + 1 <= remaining do
      scan_safe_reason_tuple(term, credential, depth - 1, remaining - 1, 0, size)
    else
      :error
    end
  end

  defp scan_safe_reason(term, credential, depth, remaining) when is_list(term) and depth > 0 do
    with {:ok, next_remaining} <-
           scan_safe_reason_list(term, credential, depth - 1, remaining - 1),
         false <- credential_charlist?(term, credential) do
      {:ok, next_remaining}
    else
      _ -> :error
    end
  end

  defp scan_safe_reason(_term, _credential, _depth, _remaining), do: :error

  defp scan_safe_reason_list([], _credential, _depth, remaining), do: {:ok, remaining}

  defp scan_safe_reason_list([head | tail], credential, depth, remaining) do
    with {:ok, after_head} <- scan_safe_reason(head, credential, depth, remaining) do
      scan_safe_reason_list(tail, credential, depth, after_head)
    end
  end

  defp scan_safe_reason_list(_improper_tail, _credential, _depth, _remaining), do: :error

  defp scan_safe_reason_tuple(_tuple, _credential, _depth, remaining, size, size),
    do: {:ok, remaining}

  defp scan_safe_reason_tuple(tuple, credential, depth, remaining, index, size) do
    with {:ok, next_remaining} <-
           scan_safe_reason(elem(tuple, index), credential, depth, remaining) do
      scan_safe_reason_tuple(tuple, credential, depth, next_remaining, index + 1, size)
    end
  end

  defp safe_reason_atom?(atom, credential) do
    value = Atom.to_string(atom)

    byte_size(value) <= @max_reason_atom_bytes and
      :binary.match(value, credential) == :nomatch
  end

  defp credential_charlist?(list, credential) do
    case IO.iodata_to_binary(list) do
      binary -> :binary.match(binary, credential) != :nomatch
    end
  rescue
    ArgumentError -> false
  end

  defp credential_in_exception?(error, credential) do
    message_status =
      try do
        credential_in_binary?(Exception.message(error), credential)
      rescue
        _error -> :unknown
      end

    message_status != false or credential_in_term?(error, credential) != false
  end

  defp credential_in_stacktrace?(stacktrace, credential) do
    credential_in_term?(
      stacktrace,
      credential,
      @max_stack_depth,
      @max_stack_nodes
    ) != false
  end

  defp credential_in_term?(
         term,
         credential,
         depth \\ @max_reason_depth,
         nodes \\ @max_reason_nodes
       ) do
    case scan_exception_term(term, credential, depth, nodes) do
      {:found, _remaining} -> true
      {:clear, _remaining} -> false
      :unknown -> :unknown
    end
  end

  defp scan_exception_term(_term, _credential, _depth, remaining) when remaining <= 0,
    do: :unknown

  defp scan_exception_term(_term, _credential, depth, _remaining) when depth < 0,
    do: :unknown

  defp scan_exception_term(term, credential, _depth, remaining) when is_binary(term) do
    case credential_in_binary?(term, credential) do
      true -> {:found, remaining - 1}
      false -> {:clear, remaining - 1}
      :unknown -> :unknown
    end
  end

  defp scan_exception_term(term, credential, _depth, remaining) when is_atom(term) do
    status =
      if :binary.match(Atom.to_string(term), credential) == :nomatch, do: :clear, else: :found

    {status, remaining - 1}
  end

  defp scan_exception_term(term, _credential, _depth, remaining)
       when is_integer(term) or is_float(term) do
    {:clear, remaining - 1}
  end

  defp scan_exception_term(term, credential, depth, remaining)
       when is_list(term) and depth > 0 do
    with {:clear, next_remaining} <-
           scan_exception_list(term, credential, depth - 1, remaining - 1) do
      if credential_charlist?(term, credential),
        do: {:found, next_remaining},
        else: {:clear, next_remaining}
    end
  end

  defp scan_exception_term(term, credential, depth, remaining)
       when is_tuple(term) and depth > 0 do
    size = tuple_size(term)

    if size + 1 <= remaining do
      scan_exception_tuple(term, credential, depth - 1, remaining - 1, 0, size)
    else
      :unknown
    end
  end

  defp scan_exception_term(term, credential, depth, remaining)
       when is_map(term) and depth > 0 do
    if map_size(term) * 2 + 1 <= remaining do
      term
      |> Map.to_list()
      |> Enum.reduce_while({:clear, remaining - 1}, fn {key, value}, {:clear, budget} ->
        with {:clear, after_key} <- scan_exception_term(key, credential, depth - 1, budget),
             {:clear, after_value} <-
               scan_exception_term(value, credential, depth - 1, after_key) do
          {:cont, {:clear, after_value}}
        else
          {:found, next_budget} -> {:halt, {:found, next_budget}}
          :unknown -> {:halt, :unknown}
        end
      end)
    else
      :unknown
    end
  end

  defp scan_exception_term(_term, _credential, _depth, _remaining), do: :unknown

  defp scan_exception_list([], _credential, _depth, remaining), do: {:clear, remaining}

  defp scan_exception_list([head | tail], credential, depth, remaining) do
    with {:clear, after_head} <- scan_exception_term(head, credential, depth, remaining) do
      scan_exception_list(tail, credential, depth, after_head)
    end
  end

  defp scan_exception_list(_tail, _credential, _depth, _remaining), do: :unknown

  defp scan_exception_tuple(_tuple, _credential, _depth, remaining, size, size),
    do: {:clear, remaining}

  defp scan_exception_tuple(tuple, credential, depth, remaining, index, size) do
    with {:clear, next_remaining} <-
           scan_exception_term(elem(tuple, index), credential, depth, remaining) do
      scan_exception_tuple(tuple, credential, depth, next_remaining, index + 1, size)
    end
  end

  defp credential_in_binary?(binary, _credential)
       when byte_size(binary) > @max_exception_binary_bytes,
       do: :unknown

  defp credential_in_binary?(binary, credential),
    do: :binary.match(binary, credential) != :nomatch
end
