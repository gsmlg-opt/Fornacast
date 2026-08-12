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

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  def form_value(values, key, default \\ ""), do: Map.get(values, key, default)

  def label_options(options),
    do: Enum.map(options.labels, fn label -> {label.name, label.name} end)

  def assignee_options(options),
    do: Enum.map(options.assignees, fn assignee -> {assignee.username, assignee.username} end)

  def selected_option?(values, value) when is_list(values), do: value in values
  def selected_option?(value, value), do: true
  def selected_option?(_values, _value), do: false

  def field_errors(errors, resource, field) do
    errors
    |> Enum.filter(&(&1.resource == resource and &1.field == field))
    |> Enum.map(&validation_message/1)
  end

  def resource_errors(errors, resource) do
    errors
    |> Enum.filter(&(&1.resource == resource and &1.field == "base"))
    |> Enum.map(&validation_message/1)
  end

  def comment_values(content, operation), do: comment_form_value(content, operation, :values, %{})
  def comment_errors(content, operation), do: comment_form_value(content, operation, :errors, [])

  defp comment_form_value(content, operation, key, default) do
    case Map.get(content, :comment_form) do
      %{operation: ^operation} = form -> Map.get(form, key, default)
      _form -> default
    end
  end

  defp validation_message(%{resource: "Issue", field: "base"}),
    do: "The issue could not be processed"

  defp validation_message(%{resource: "IssueComment", field: "base"}),
    do: "The comment could not be processed"

  defp validation_message(%{field: field, code: code}) do
    label = field |> String.replace("_", " ") |> String.capitalize()

    case code do
      :invalid -> "#{label} is invalid"
      :missing -> "#{label} is missing"
      :unprocessable -> "#{label} could not be processed"
      _code -> "#{label} is invalid"
    end
  end
end
