defmodule FornacastWeb.IssueHTML do
  @moduledoc false

  use FornacastWeb, :html

  alias FornacastWeb.{CollaborationMarkdown, RepositoryHTML}

  embed_templates "issue_html/*"

  def total_pages(page), do: Fornacast.Page.total_pages(page)

  def pagination_base(result) do
    filters = result.content.filters

    query =
      [
        state: filters.state,
        labels: filters.labels,
        assignee: filters.assignee,
        creator: filters.creator,
        sort: filters.sort,
        direction: filters.direction
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
      |> URI.encode_query()

    base = RepositoryHTML.issues_path(result.chrome)
    if query == "", do: base, else: base <> "?" <> query
  end

  def filter_value(filters, key) do
    case Map.get(filters, key) do
      nil -> ""
      value -> to_string(value)
    end
  end

  def state_variant(:open), do: "success"
  def state_variant(:closed), do: "neutral"

  def author_name(%{username: username}) when is_binary(username), do: username
  def author_name(_author), do: "unknown"

  def label_name(%{name: name}) when is_binary(name), do: name
  def label_name(%{normalized_name: name}) when is_binary(name), do: name
  def label_name(_label), do: "label"

  def comment_label(1), do: "1 comment"
  def comment_label(count), do: "#{count} comments"

  def markdown(nil), do: CollaborationMarkdown.render("")
  def markdown(body), do: CollaborationMarkdown.render(body)

  def format_time(value), do: RepositoryHTML.format_time(value)
end
