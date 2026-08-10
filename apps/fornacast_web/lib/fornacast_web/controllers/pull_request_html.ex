defmodule FornacastWeb.PullRequestHTML do
  @moduledoc false

  use FornacastWeb, :html

  alias FornacastWeb.{CollaborationMarkdown, RepositoryHTML}

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

  def markdown(nil), do: CollaborationMarkdown.render("")
  def markdown(body), do: CollaborationMarkdown.render(body)

  def format_time(value), do: RepositoryHTML.format_time(value)
  def short_oid(value), do: RepositoryHTML.short_oid(value)
  def diff_line_map(value), do: RepositoryHTML.diff_line_map(value)

  def changed_file_pages(%{total: total, per_page: per_page}) when total > 0,
    do: div(total + per_page - 1, per_page)

  def changed_file_pages(_page), do: 1

  attr :result, :map, required: true
  attr :active, :atom, required: true

  def pull_navigation(assigns) do
    ~H"""
    <nav class="flex flex-wrap gap-2" aria-label="Pull request navigation" data-pull-navigation>
      <.dm_link
        href={RepositoryHTML.pull_path(@result.chrome, @result.content.pull.issue.number)}
        aria-current={if @active == :conversation, do: "page"}
      >
        Conversation
      </.dm_link>
      <.dm_link
        href={RepositoryHTML.pull_commits_path(@result.chrome, @result.content.pull.issue.number)}
        aria-current={if @active == :commits, do: "page"}
      >
        Commits
      </.dm_link>
      <.dm_link
        href={RepositoryHTML.pull_files_path(@result.chrome, @result.content.pull.issue.number)}
        aria-current={if @active == :files, do: "page"}
      >
        Files changed
      </.dm_link>
    </nav>
    """
  end

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
