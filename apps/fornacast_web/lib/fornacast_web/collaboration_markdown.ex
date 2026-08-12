defmodule FornacastWeb.CollaborationMarkdown do
  @moduledoc """
  Renders untrusted issue and pull-request Markdown.
  """

  @allowed_schemes ~w(http https mailto)

  def render(content) when is_binary(content) do
    html =
      content
      |> MDEx.parse_document!()
      |> MDEx.Document.update_nodes(MDEx.Link, &filter_destination/1)
      |> MDEx.Document.update_nodes(MDEx.Image, &filter_destination/1)
      |> MDEx.to_html!(sanitize: MDEx.Document.default_sanitize_options())

    Phoenix.HTML.raw(html)
  end

  defp filter_destination(%{url: url} = node) do
    if allowed_destination?(url), do: node, else: %{node | url: ""}
  end

  defp allowed_destination?("//" <> _rest), do: false

  defp allowed_destination?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_nil(host) ->
        String.downcase(scheme) == "mailto"

      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        String.downcase(scheme) in @allowed_schemes

      _other ->
        false
    end
  rescue
    ArgumentError -> false
  end
end
