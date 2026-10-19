defmodule FornacastAPI.PathValue do
  @moduledoc "The single percent-decoding boundary for raw Git-data route segments."

  def decode(segments, resource, field) when is_list(segments) do
    value = Enum.join(segments, "/")

    with true <- String.valid?(value),
         false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value),
         decoded <- URI.decode(value),
         true <- String.valid?(decoded),
         true <- decoded == String.normalize(decoded, :nfc),
         false <- String.contains?(decoded, ["%", "\\", <<0>>]),
         false <- String.starts_with?(decoded, "/"),
         true <- valid_segments?(decoded, resource, field),
         true <- valid_ref_value?(decoded, resource) do
      {:ok, decoded}
    else
      _ -> {:error, {:validation, [%{resource: resource, field: field, code: :invalid}]}}
    end
  end

  defp valid_segments?("", "Content", "path"), do: true

  defp valid_segments?(value, _, _),
    do: Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."]))

  defp valid_ref_value?(_value, "Content"), do: true

  defp valid_ref_value?(value, _) do
    not Regex.match?(~r/[\x00-\x20\x7f~^:?*\[]/, value) and
      not String.contains?(value, ["..", "@{"]) and
      not String.ends_with?(value, [".", ".lock"]) and
      Enum.all?(String.split(value, "/"), &(not String.starts_with?(&1, ".")))
  end
end
