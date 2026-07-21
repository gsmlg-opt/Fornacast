defmodule FornacastAPI.Plugs.MediaType do
  import Plug.Conn

  alias FornacastAPI.{Error, Response}

  @supported_media_types ["application/vnd.github+json", "application/json"]
  @always_body_methods ["POST", "PUT", "PATCH"]
  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/getting-started-with-the-rest-api#media-types"

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not acceptable?(conn) ->
        reject(conn, 406, "Not Acceptable")

      body_bearing?(conn) and not supported_content_type?(conn) ->
        reject(conn, 415, "Unsupported Media Type")

      true ->
        conn
    end
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
