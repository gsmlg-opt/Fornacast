defmodule FornacastWeb.RepositoryMarkdown do
  @moduledoc """
  Renders repository README content with snapshot-preserving links.
  """

  @candidate_names ["README.md", "README", "README.txt"]
  @allowed_schemes ["http", "https", "mailto"]
  @raster_extensions ~w(.png .jpg .jpeg .gif .webp .avif)

  def candidates(directory) when is_binary(directory) do
    directory = String.trim(directory, "/")

    Enum.map(@candidate_names, fn name ->
      if directory == "", do: name, else: directory <> "/" <> name
    end)
  end

  def render(content, opts) when is_binary(content) and is_list(opts) do
    context = context!(opts)

    html =
      if markdown?(context.path) do
        content
        |> MDEx.parse_document!()
        |> MDEx.Document.update_nodes(MDEx.Link, &rewrite_link(&1, context))
        |> MDEx.Document.update_nodes(MDEx.Image, &rewrite_image(&1, context))
        |> MDEx.to_html!(sanitize: MDEx.Document.default_sanitize_options())
      else
        "<pre><code>" <> escape_html(content) <> "</code></pre>"
      end

    Phoenix.HTML.raw(html)
  end

  defp rewrite_link(%MDEx.Link{url: url} = link, context) do
    case destination(url, :src, context) do
      :unchanged -> link
      {:ok, rewritten} -> %{link | url: rewritten}
      :reject -> %{link | url: ""}
    end
  end

  defp rewrite_image(%MDEx.Image{url: url} = image, context) do
    case destination(url, :raw, context) do
      :unchanged ->
        image

      {:ok, rewritten} ->
        if raster_path?(rewritten) do
          %{image | url: rewritten}
        else
          image_link(image, rewritten)
        end

      :reject ->
        image_link(image, "")
    end
  end

  defp destination("#" <> _anchor, _route, _context), do: :unchanged
  defp destination("", _route, _context), do: :unchanged
  defp destination("//" <> _rest, _route, _context), do: :reject

  defp destination(url, route, context) do
    uri = URI.parse(url)

    cond do
      is_binary(uri.scheme) ->
        if String.downcase(uri.scheme) in @allowed_schemes, do: :unchanged, else: :reject

      is_binary(uri.host) ->
        :reject

      true ->
        rewrite_relative(uri, route, context)
    end
  rescue
    ArgumentError -> :reject
  end

  defp rewrite_relative(%URI{} = uri, route, context) do
    with {:ok, path_segments} <- relative_path_segments(uri.path, context.path),
         url <- repository_url(route, path_segments, context) do
      {:ok, url <> query_suffix(uri.query) <> fragment_suffix(uri.fragment)}
    else
      :error -> :reject
    end
  end

  defp relative_path_segments(nil, readme_path) do
    {:ok, String.split(readme_path, "/", trim: true)}
  end

  defp relative_path_segments(path, readme_path) do
    with {:ok, decoded_path} <- decode_path(path) do
      normalize_path(decoded_path, readme_path)
    end
  end

  defp normalize_path(destination, readme_path) do
    if String.contains?(destination, ["\\", "\0"]) do
      :error
    else
      base =
        if String.starts_with?(destination, "/") do
          []
        else
          readme_path
          |> String.split("/", trim: true)
          |> Enum.drop(-1)
        end

      destination
      |> String.trim_leading("/")
      |> String.split("/", trim: false)
      |> Enum.reduce_while({:ok, Enum.reverse(base)}, fn
        segment, {:ok, stack} when segment in ["", "."] ->
          {:cont, {:ok, stack}}

        "..", {:ok, []} ->
          {:halt, :error}

        "..", {:ok, [_parent | rest]} ->
          {:cont, {:ok, rest}}

        segment, {:ok, stack} ->
          {:cont, {:ok, [segment | stack]}}
      end)
      |> case do
        {:ok, stack} -> {:ok, Enum.reverse(stack)}
        :error -> :error
      end
    end
  end

  defp repository_url(route, path_segments, context) do
    route_segments =
      [context.owner, context.repository, Atom.to_string(route)] ++
        String.split(context.ref, "/", trim: true) ++ path_segments

    "/" <> Enum.map_join(route_segments, "/", &encode_segment/1)
  end

  defp context!(opts) do
    %{
      owner: opts |> Keyword.fetch!(:owner) |> to_string(),
      repository: opts |> Keyword.fetch!(:repository) |> to_string(),
      ref: opts |> Keyword.fetch!(:ref) |> to_string(),
      path: opts |> Keyword.fetch!(:path) |> to_string()
    }
  end

  defp image_link(image, url) do
    %MDEx.Link{
      nodes: image.nodes,
      url: url,
      title: image.title,
      sourcepos: image.sourcepos
    }
  end

  defp raster_path?(url) do
    url
    |> URI.parse()
    |> Map.get(:path, "")
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @raster_extensions))
  end

  defp markdown?(path), do: String.ends_with?(String.downcase(path), ".md")

  defp decode_path(path) do
    {:ok, URI.decode(path)}
  rescue
    ArgumentError -> :error
  end

  defp encode_segment(segment) do
    URI.encode(segment, &URI.char_unreserved?/1)
  end

  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query

  defp fragment_suffix(nil), do: ""
  defp fragment_suffix(fragment), do: "#" <> fragment

  defp escape_html(content) do
    content
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
