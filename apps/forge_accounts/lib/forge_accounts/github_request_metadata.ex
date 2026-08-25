defmodule ForgeAccounts.GitHubRequestMetadata do
  @moduledoc false

  @field_pairs [
    {:request_id, "request_id"},
    {:operation_id, "operation_id"},
    {:ip_address, "ip_address"},
    {:user_agent, "user_agent"}
  ]
  @credential_markers ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "bearer "]

  @spec validate(term(), binary() | nil) ::
          {:ok, map()} | {:error, :invalid_request_metadata}
  def validate(metadata, credential \\ nil)

  def validate(metadata, credential)
      when is_map(metadata) and map_size(metadata) <= 16 and
             (is_nil(credential) or is_binary(credential)) do
    Enum.reduce_while(@field_pairs, {:ok, %{}}, fn {atom_key, string_key}, {:ok, safe} ->
      case fetch_unambiguous(metadata, atom_key, string_key) do
        :missing ->
          {:cont, {:ok, safe}}

        {:ok, nil} ->
          {:cont, {:ok, safe}}

        {:ok, value} ->
          if valid_field?(atom_key, value, credential),
            do: {:cont, {:ok, Map.put(safe, string_key, value)}},
            else: {:halt, {:error, :invalid_request_metadata}}

        :ambiguous ->
          {:halt, {:error, :invalid_request_metadata}}
      end
    end)
  end

  def validate(_metadata, _credential), do: {:error, :invalid_request_metadata}

  defp fetch_unambiguous(metadata, atom_key, string_key) do
    atom? = Map.has_key?(metadata, atom_key)
    string? = Map.has_key?(metadata, string_key)

    case {atom?, string?} do
      {true, true} -> :ambiguous
      {true, false} -> {:ok, Map.fetch!(metadata, atom_key)}
      {false, true} -> {:ok, Map.fetch!(metadata, string_key)}
      {false, false} -> :missing
    end
  end

  defp valid_field?(:request_id, value, credential),
    do: safe_string?(value, 255, credential)

  defp valid_field?(:operation_id, value, credential),
    do: safe_string?(value, 255, credential)

  defp valid_field?(:user_agent, value, credential),
    do: safe_string?(value, 2_048, credential)

  defp valid_field?(:ip_address, value, credential) do
    safe_string?(value, 64, credential) and valid_ip_address?(value)
  end

  defp safe_string?(value, max_bytes, credential) do
    is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch and not absolute_path?(value) and
      not credential_marker?(value) and not credential_overlap?(value, credential)
  end

  defp credential_marker?(value) do
    normalized = String.downcase(value)
    Enum.any?(@credential_markers, &String.contains?(normalized, &1))
  end

  defp credential_overlap?(_value, nil), do: false
  defp credential_overlap?(_value, ""), do: true

  defp credential_overlap?(value, credential) do
    value == credential or String.contains?(value, credential) or
      (byte_size(value) >= 8 and String.contains?(credential, value))
  end

  defp absolute_path?(value) do
    String.starts_with?(value, ["/", "\\"]) or
      Regex.match?(~r/^[A-Za-z]:[\\\/]/, value)
  end

  defp valid_ip_address?(value) do
    match?({:ok, _address}, value |> String.to_charlist() |> :inet.parse_address())
  end
end
