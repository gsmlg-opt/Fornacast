defmodule FornacastAPI.Serializers.V2022_11_28.IssueComment do
  alias FornacastAPI.{Serializer, URL}

  def render(comment, opts) do
    owner = option(opts, :owner)
    repo = option(opts, :repo)
    issue_number = option(opts, :issue_number)
    url = URL.issue_comment(owner, repo, comment.id)

    %{
      url: url,
      html_url: url,
      issue_url: URL.issue(owner, repo, issue_number),
      id: comment.id,
      node_id: Base.url_encode64("IssueComment:#{comment.id}", padding: false),
      user: Serializer.render("2022-11-28", :simple_user, comment.author, opts),
      created_at: DateTime.to_iso8601(comment.inserted_at),
      updated_at: DateTime.to_iso8601(comment.updated_at),
      author_association: comment.author_association,
      body: comment.body,
      reactions: %{
        "+1": 0,
        "-1": 0,
        laugh: 0,
        confused: 0,
        heart: 0,
        hooray: 0,
        rocket: 0,
        eyes: 0,
        url: nil,
        total_count: 0
      },
      performed_via_github_app: nil
    }
  end

  defp option(opts, key) when is_list(opts), do: Keyword.fetch!(opts, key)
  defp option(opts, key), do: Map.fetch!(opts, key)
end
