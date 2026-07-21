defmodule FornacastAPI.Pagination do
  import Plug.Conn, only: [put_resp_header: 3]

  alias Fornacast.Page

  @defaults [page: 1, per_page: 30]
  @validation_fields [
    {:page, "page", nil},
    {:per_page, "per_page", 100}
  ]

  def parse(params) when is_map(params) do
    {values, errors} =
      Enum.reduce(@validation_fields, {[], []}, fn {key, field, maximum}, {values, errors} ->
        case parse_field(params, field, Keyword.fetch!(@defaults, key), maximum) do
          {:ok, value} -> {[{key, value} | values], errors}
          :error -> {values, [validation_error(field) | errors]}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(values)}
      errors -> {:error, {:validation, Enum.reverse(errors)}}
    end
  end

  def put_link_header(conn, %Page{} = page, canonical_public_url)
      when is_binary(canonical_public_url) do
    total_pages = Page.total_pages(page)

    relations =
      [
        {"next", if(page.page < total_pages, do: page.page + 1)},
        {"prev", if(page.page > 1, do: min(page.page - 1, total_pages))},
        {"first", if(page.page > 1, do: 1)},
        {"last", if(page.page < total_pages, do: total_pages)}
      ]
      |> Enum.reject(fn {_relation, target_page} -> is_nil(target_page) end)

    case relations do
      [] ->
        conn

      relations ->
        uri = URI.parse(canonical_public_url)
        query_pairs = pagination_independent_query(uri.query)

        value =
          relations
          |> Enum.map_join(", ", fn {relation, target_page} ->
            "<#{page_url(uri, query_pairs, target_page, page.per_page)}>; rel=\"#{relation}\""
          end)

        put_resp_header(conn, "link", value)
    end
  end

  defp parse_field(params, field, default, maximum) do
    case Map.fetch(params, field) do
      :error ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        if Regex.match?(~r/^[0-9]+\z/, value) do
          parsed = String.to_integer(value)

          if parsed > 0 and (is_nil(maximum) or parsed <= maximum),
            do: {:ok, parsed},
            else: :error
        else
          :error
        end

      {:ok, _value} ->
        :error
    end
  end

  defp validation_error(field) do
    %{resource: "Pagination", field: field, code: :invalid}
  end

  defp pagination_independent_query(nil), do: []

  defp pagination_independent_query(query) do
    query
    |> URI.query_decoder()
    |> Enum.reject(fn {key, _value} -> key in ["page", "per_page"] end)
  end

  defp page_url(uri, query_pairs, page, per_page) do
    query =
      [
        {"page", Integer.to_string(page)},
        {"per_page", Integer.to_string(per_page)}
        | query_pairs
      ]
      |> Enum.sort()
      |> URI.encode_query(:rfc3986)

    %{uri | query: query}
    |> URI.to_string()
  end
end
