defmodule FornacastWeb.RepositoryRaw do
  @moduledoc false

  @octet_stream "application/octet-stream"
  @raster_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".avif" => "image/avif"
  }

  def headers(filename) do
    [
      {"content-type", content_type(filename)},
      {"content-disposition", content_disposition(filename)},
      {"x-content-type-options", "nosniff"}
    ]
  end

  def content_type(filename) do
    filename
    |> to_string()
    |> Path.extname()
    |> String.downcase()
    |> then(&Map.get(@raster_types, &1, @octet_stream))
  end

  def content_disposition(filename) do
    filename = sanitize_filename(filename)
    fallback = filename |> ascii_fallback() |> escape_quoted_string()
    encoded = URI.encode(filename, &rfc5987_attr_char?/1)

    ~s(inline; filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end

  defp sanitize_filename(filename) do
    filename = to_string(filename)

    if String.valid?(filename) do
      String.replace(filename, ~r/[\x00-\x1F\x7F-\x9F]/u, "")
    else
      filename
      |> :binary.bin_to_list()
      |> Enum.map_join(fn byte -> if byte in 0x20..0x7E, do: <<byte>>, else: "_" end)
    end
    |> case do
      "" -> "download"
      sanitized -> sanitized
    end
  end

  defp ascii_fallback(filename) do
    filename
    |> String.to_charlist()
    |> Enum.map_join(fn
      codepoint when codepoint in 0x20..0x7E -> <<codepoint>>
      _codepoint -> "_"
    end)
  end

  defp escape_quoted_string(filename) do
    filename
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp rfc5987_attr_char?(character)
       when character in ?a..?z or character in ?A..?Z or character in ?0..?9,
       do: true

  defp rfc5987_attr_char?(character)
       when character in [?!, ?#, ?$, ?&, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~],
       do: true

  defp rfc5987_attr_char?(_character), do: false
end
