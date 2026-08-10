defmodule FornacastWeb.PullRequestHTML do
  @moduledoc false

  use FornacastWeb, :html

  alias FornacastWeb.RepositoryHTML

  embed_templates "pull_request_html/*"

  def total_pages(page), do: Fornacast.Page.total_pages(page)

  def pagination_base(result) do
    filters = result.content.filters

    query =
      [
        state: filters.state,
        head: filters.head,
        base: filters.base,
        sort: filters.sort,
        direction: filters.direction
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.map(fn {key, value} -> {key, query_value(value)} end)
      |> URI.encode_query()

    base = RepositoryHTML.pulls_path(result.chrome)
    if query == "", do: base, else: base <> "?" <> query
  end

  def filter_value(filters, key) do
    case Map.get(filters, key) do
      nil -> ""
      value -> query_value(value)
    end
  end

  defp query_value(:long_running), do: "long-running"
  defp query_value(value), do: to_string(value)

  def state_variant(:open), do: "success"
  def state_variant(:closed), do: "neutral"

  def author_name(%{username: username}) when is_binary(username), do: username
  def author_name(_author), do: "unknown"

  def comment_label(1), do: "1 comment"
  def comment_label(count), do: "#{count} comments"

  def branch_name("refs/heads/" <> name), do: name
  def branch_name(name), do: name

  def branch_options(branches, current) do
    options =
      Enum.map(branches, fn branch -> {branch_name(branch.name), branch_display(branch)} end)

    if is_binary(current) and current != "" and not Enum.any?(options, &(elem(&1, 0) == current)) do
      [{current, current} | options]
    else
      options
    end
  end

  defp branch_display(%{display_name: display_name}) when is_binary(display_name),
    do: display_name

  defp branch_display(branch), do: branch_name(branch.name)

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
  def form_value(values, key, default \\ ""), do: Map.get(values, key, default)

  def field_errors(errors, resource, field) do
    errors
    |> Enum.filter(&(&1.resource == resource and &1.field == field))
    |> Enum.map(&validation_message/1)
  end

  defp validation_message(%{message: message}) when is_binary(message), do: message

  defp validation_message(%{field: field, code: code}) do
    label = field |> String.replace("_", " ") |> String.capitalize()

    case code do
      :invalid -> "#{label} is invalid"
      :missing -> "#{label} is missing"
      :missing_field -> "#{label} is missing"
      :unprocessable -> "#{label} could not be processed"
      _code -> "#{label} is invalid"
    end
  end
end
