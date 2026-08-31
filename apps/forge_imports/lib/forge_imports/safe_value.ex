defmodule ForgeImports.SafeValue do
  @moduledoc false

  @github_token_prefixes ~w(github_pat_ ghp_ gho_ ghu_ ghs_ ghr_)
  @secret_aliases ~w(
    token password pat github_pat access_token authorization credential credential_envelope
    credential_envelopes ciphertext nonce tag key_id raw_body request_body response_body
    storage_path staged_storage_path replacement_storage_path
  )
  @secret_key_pattern ~r/(?:^|_)(?:token|password|pat|credential|authorization|ciphertext|nonce|raw_body|request_body|response_body|storage_path)(?:_|$)/u
  @max_integer 9_223_372_036_854_775_807
  @max_depth 4
  @max_entries 64
  @max_string 2_048

  def safe_string?(value, max_length, opts \\ []) do
    required? = Keyword.get(opts, :required?, false)
    classified? = Keyword.get(opts, :classified?, false)

    is_binary(value) and String.valid?(value) and
      (not required? or String.trim(value) != "") and
      :binary.match(value, <<0>>) == :nomatch and String.length(value) <= max_length and
      (not classified? or classified_value?(value))
  end

  def report_value?(value) when is_boolean(value) or is_nil(value), do: true

  def report_value?(value) when is_integer(value),
    do: value >= -@max_integer and value <= @max_integer

  def report_value?(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> safe_string?(120, classified?: true)
  end

  def report_value?(value) when is_binary(value),
    do: safe_string?(value, 255, classified?: true)

  def report_value?(_value), do: false

  def safe_nested?(value), do: do_safe_nested?(value, 0)

  def classified_or_nil(value, max_length) do
    if safe_string?(value, max_length, classified?: true), do: value, else: nil
  end

  def github_source_text?(value, max_length, opts \\ []) do
    required? = Keyword.get(opts, :required?, false)

    safe_string?(value, max_length, required?: required?) and
      github_token_free?(value)
  end

  def classified_value?(value) when is_binary(value) do
    downcased = String.downcase(value)

    github_secret_free?(value) and
      String.trim(downcased) not in @secret_aliases and
      not absolute_path?(value)
  end

  def classified_value?(_value), do: false

  def github_secret_free?(value) when is_binary(value) do
    github_token_free?(value) and
      not Regex.match?(~r/\bbearer\s+\S+/iu, value)
  end

  def github_secret_free?(_value), do: false

  defp github_token_free?(value) do
    downcased = String.downcase(value)
    Enum.all?(@github_token_prefixes, &(not String.contains?(downcased, &1)))
  end

  defp absolute_path?(value) do
    String.starts_with?(value, ["/", "\\\\"]) or
      Regex.match?(~r/\bfile:\/\/\//iu, value) or
      Regex.match?(~r/(?:^|[\s"'`(<\[,{;=:])\/(?!\/)[^\s"'`)>\]},;]+/u, value) or
      Regex.match?(~r/(?:^|[\s"'`(<\[,{;=:])\\/u, value) or
      Regex.match?(
        ~r/(?:^|[\s"'`(<\[,{;=])(?:[A-Za-z]:[\\\/]|\\\\)[^\s"'`)>\]},;]+/u,
        value
      )
  end

  defp do_safe_nested?(_value, depth) when depth > @max_depth, do: false

  defp do_safe_nested?(value, _depth) when is_boolean(value) or is_nil(value), do: true

  defp do_safe_nested?(value, _depth) when is_integer(value),
    do: value >= -@max_integer and value <= @max_integer

  defp do_safe_nested?(value, _depth) when is_binary(value),
    do: safe_string?(value, @max_string, classified?: true)

  defp do_safe_nested?(value, _depth) when is_atom(value),
    do: value |> Atom.to_string() |> safe_string?(120, classified?: true)

  defp do_safe_nested?(value, depth) when is_map(value) do
    map_size(value) <= @max_entries and
      Enum.all?(value, fn {key, nested} ->
        safe_nested_key?(key) and do_safe_nested?(nested, depth + 1)
      end)
  end

  defp do_safe_nested?(value, depth) when is_list(value) do
    length(value) <= @max_entries and Enum.all?(value, &do_safe_nested?(&1, depth + 1))
  end

  defp do_safe_nested?(_value, _depth), do: false

  defp safe_nested_key?(key) when is_atom(key) or is_binary(key) do
    normalized = key |> to_string() |> String.downcase()

    safe_string?(normalized, 120, required?: true, classified?: true) and
      not Regex.match?(@secret_key_pattern, normalized)
  end

  defp safe_nested_key?(_key), do: false
end
