defmodule FornacastAPI.Plugs.MediaType do
  import Plug.Conn

  alias FornacastAPI.{Error, Response}

  @supported_media_types ["application/vnd.github+json", "application/json"]
  @always_body_methods ["POST", "PUT", "PATCH"]
  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/getting-started-with-the-rest-api#media-types"

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not acceptable?(conn) and not binary_acceptable?(conn) ->
        reject(conn, 406, "Not Acceptable")

      body_bearing?(conn) and not supported_content_type?(conn) and not asset_upload?(conn) ->
        reject(conn, 415, "Unsupported Media Type")

      true ->
        conn
    end
  end

  def binary_asset_request?(conn) do
    ranges = parse_ranges(get_req_header(conn, "accept"))

    Enum.any?(ranges, &(&1.media_type == "application/octet-stream" and &1.quality > 0.0)) and
      effective_quality("application/octet-stream", ranges) >=
        Enum.max(Enum.map(@supported_media_types, &effective_quality(&1, ranges)))
  end

  defp asset_upload?(conn) do
    conn.method == "POST" and
      Regex.match?(
        ~r/\A\/api\/uploads\/repos\/[^\/]+\/[^\/]+\/releases\/[0-9]+\/assets\z/,
        conn.request_path
      ) and
      case get_req_header(conn, "content-type") do
        [value] ->
          byte_size(value) <= 255 and
            Regex.match?(
              ~r/\A[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]+(?:;[^\r\n]*)?\z/,
              value
            )

        _ ->
          false
      end
  end

  defp binary_acceptable?(conn) do
    media_types =
      case Regex.run(
             ~r/\A\/api\/v3\/repos\/[^\/]+\/[^\/]+\/releases\/(assets\/[0-9]+(?:\/download)?|[0-9]+\/archives\/(?:tar|zip))\z/,
             conn.request_path
           ) do
        [_, "assets/" <> _] ->
          ["application/octet-stream"]

        [_, resource] ->
          archive_type =
            if String.ends_with?(resource, "/zip"),
              do: "application/zip",
              else: "application/x-tar"

          ["application/octet-stream", archive_type]

        _ ->
          []
      end

    ranges = parse_ranges(get_req_header(conn, "accept"))
    conn.method == "GET" and Enum.any?(media_types, &(effective_quality(&1, ranges) > 0.0))
  end

  defp acceptable?(conn) do
    case get_req_header(conn, "accept") do
      [] ->
        true

      values ->
        ranges = parse_ranges(values)
        Enum.any?(@supported_media_types, &(effective_quality(&1, ranges) > 0.0))
    end
  end

  defp parse_ranges(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&parse_range/1)
  end

  defp parse_range(range) do
    [media_type | parameters] = String.split(range, ";")

    %{
      media_type: String.downcase(String.trim(media_type)),
      quality: quality(parameters)
    }
  end

  defp effective_quality(media_type, ranges) do
    selected =
      Enum.find(ranges, &(&1.media_type == media_type)) ||
        Enum.find(ranges, &(&1.media_type == "*/*"))

    case selected do
      %{quality: quality} -> quality
      nil -> 0.0
    end
  end

  defp quality(parameters) do
    case Enum.find(parameters, fn parameter ->
           parameter
           |> String.trim()
           |> String.downcase()
           |> String.starts_with?("q=")
         end) do
      nil ->
        1.0

      parameter ->
        parameter
        |> String.trim()
        |> String.split("=", parts: 2)
        |> List.last()
        |> parse_quality()
    end
  end

  defp parse_quality(value) do
    case Float.parse(value) do
      {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
      _invalid -> 0.0
    end
  end

  defp body_bearing?(%{method: method}) when method in @always_body_methods, do: true

  defp body_bearing?(%{method: "DELETE"} = conn) do
    positive_content_length?(conn) or transfer_encoded?(conn)
  end

  defp body_bearing?(_conn), do: false

  defp positive_content_length?(conn) do
    Enum.any?(get_req_header(conn, "content-length"), fn value ->
      case Integer.parse(String.trim(value)) do
        {length, ""} when length > 0 -> true
        _not_positive -> false
      end
    end)
  end

  defp transfer_encoded?(conn) do
    Enum.any?(get_req_header(conn, "transfer-encoding"), &(String.trim(&1) != ""))
  end

  defp supported_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        value
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()
        |> then(&(&1 in ["application/vnd.github+json", "application/json"]))

      _missing_or_multiple ->
        false
    end
  end

  defp reject(conn, status, message) do
    conn
    |> Response.error(Error.new(status, message, @documentation_url))
    |> halt()
  end
end
