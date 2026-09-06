defmodule ForgeIssues.SyncEvents do
  @moduledoc """
  Provider-neutral issue synchronization event producers.

  Events carry bounded identity/version metadata. Consumers reread the latest live
  resource rather than replaying potentially stale content. Comment deletion events
  retain parent and author identities so consumers never need the deleted row.

  Provenance options are supplied only by trusted internal Multi builders. Public
  request attributes and request metadata cannot change event origin.
  """

  alias Fornacast.DomainOutbox

  def issue(multi, event_type, options) do
    DomainOutbox.record_multi(multi, :outbox, fn %{issue: issue} ->
      attrs(
        "issue",
        issue.id,
        event_type,
        %{
          "repository_id" => issue.repository_id,
          "issue_id" => issue.id,
          "issue_number" => issue.number,
          "issue_kind" => Atom.to_string(issue.kind),
          "sync_version" => issue.sync_version
        },
        options
      )
    end)
  end

  def comment(multi, event_type, issue, repository, options) do
    DomainOutbox.record_multi(multi, :outbox, fn %{comment: comment} ->
      attrs(
        "issue_comment",
        comment.id,
        event_type,
        %{
          "repository_id" => repository.id,
          "issue_id" => issue.id,
          "issue_number" => issue.number,
          "issue_kind" => Atom.to_string(issue.kind),
          "comment_id" => comment.id,
          "author_user_id" => comment.author_user_id,
          "author_github_identity_id" => comment.author_github_identity_id,
          "sync_version" => comment.sync_version,
          "deleted" => event_type == "issue_comment.deleted"
        },
        options
      )
    end)
  end

  defp attrs(type, id, event_type, payload, options) do
    %{
      event_id: Ecto.UUID.generate(),
      aggregate_type: type,
      aggregate_id: to_string(id),
      event_type: event_type,
      payload: payload,
      origin: Keyword.get(options, :origin, :fornacast),
      causation_id: Keyword.get(options, :causation_id),
      correlation_id: Keyword.get(options, :correlation_id)
    }
  end
end
