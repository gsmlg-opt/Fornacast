defmodule FornacastAPI.Serializers.V2022_11_28.Issue do
  alias FornacastAPI.{Serializer, URL}

  def render(issue, opts) do
    version = option(opts, :version, "2022-11-28")
    {owner, repo} = repository!(opts)
    url = URL.issue(owner, repo, issue.number)

    assignees =
      Enum.map(issue.assignees || [], &Serializer.render(version, :simple_user, &1, opts))

    labels = Enum.map(issue.labels || [], &render_label(&1, owner, repo))

    %{
      url: url,
      repository_url: URL.repository(owner, repo),
      labels_url: url <> "/labels{/name}",
      comments_url: url <> "/comments",
      events_url: url <> "/events",
      html_url: url,
      id: issue.id,
      node_id: node_id("Issue", issue.id),
      number: issue.number,
      title: issue.title,
      user: Serializer.render(version, :simple_user, issue.author, opts),
      labels: labels,
      state: Atom.to_string(issue.state),
      locked: false,
      assignee: List.first(assignees),
      assignees: assignees,
      milestone: nil,
      comments: issue.comment_count,
      created_at: timestamp(issue.inserted_at),
      updated_at: timestamp(issue.updated_at),
      closed_at: timestamp(issue.closed_at),
      author_association: issue.author_association,
      active_lock_reason: nil,
      draft: false,
      body: issue.body,
      closed_by: nil,
      reactions: reactions(URL.issue_reactions(owner, repo, issue.number)),
      timeline_url: url <> "/timeline",
      performed_via_github_app: nil,
      state_reason: enum_or_nil(issue.state_reason)
    }
    |> maybe_put_pull_request(pull_request(issue, owner, repo, opts))
  end

  def render_label(label, owner, repo) do
    %{
      id: label.id,
      node_id: node_id("Label", label.id),
      url: URL.label(owner, repo, label.name),
      name: label.name,
      color: label.color,
      default: label.default,
      description: label.description
    }
  end

  defp pull_request(%{kind: :issue}, _owner, _repo, _opts), do: nil

  defp pull_request(issue, owner, repo, opts) do
    pull = opts |> option(:pull_links_by_issue_id, %{}) |> Map.get(issue.id, %{merged_at: nil})
    url = URL.pull(owner, repo, issue.number)

    %{
      url: url,
      html_url: url,
      diff_url: url,
      patch_url: url
    }
    |> maybe_put_merged_at(
      timestamp(Map.get(pull, :merged_at) || Map.get(pull, "merged_at")),
      opts
    )
  end

  defp repository!(opts), do: {option(opts, :owner), option(opts, :repo)}
  defp option(opts, key, default \\ nil)
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp option(opts, key, default),
    do: Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))

  defp node_id(type, id), do: Base.url_encode64("#{type}:#{id}", padding: false)
  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)
  defp enum_or_nil(nil), do: nil
  defp enum_or_nil(value), do: Atom.to_string(value)

  defp maybe_put_pull_request(map, nil), do: map
  defp maybe_put_pull_request(map, value), do: Map.put(map, :pull_request, value)

  defp maybe_put_merged_at(map, nil, opts) do
    if option(opts, :version) == "2026-03-10", do: map, else: Map.put(map, :merged_at, nil)
  end

  defp maybe_put_merged_at(map, value, _opts), do: Map.put(map, :merged_at, value)

  defp reactions(url),
    do: %{
      "+1": 0,
      "-1": 0,
      laugh: 0,
      confused: 0,
      heart: 0,
      hooray: 0,
      rocket: 0,
      eyes: 0,
      url: url,
      total_count: 0
    }
end
