defmodule ForgeIssues.Sync do
  @moduledoc """
  Trusted transactional domain boundary for permanent synchronization.

  Callers authorize and lease their synchronization operation before composing
  these steps. This module has no mirror mappings or provider transport knowledge.
  Projections contain domain relationship IDs; the coordinator owns their external
  identity mapping. Request fields cannot control attribution or event provenance.
  """
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.{Comment, Issue, IssueAssignee, IssueLabel, Label, NumberSequence}
  alias Fornacast.{Audit, DomainOutbox, Repo}

  @max_id 9_223_372_036_854_775_807
  @max_relationships 512
  defguardp valid_id(id) when is_integer(id) and id > 0 and id <= @max_id

  def sync_projection(repository_id, kind, id) do
    case Repo.transaction(fn ->
           with {:ok, repository} <- repository(Repo, repository_id),
                {:ok, {row, issue}} <- resource(Repo, repository, kind, id) do
             projection(Repo, row, issue)
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def append_sync_observe(%Multi{} = multi, key, expected) do
    Multi.run(multi, key, fn repo, _ ->
      with :ok <- validate_observation(expected),
           {:ok, repository} <- repository(repo, expected.repository_id),
           {:ok, {row, issue}} <-
             resource(repo, repository, expected.resource_kind, expected.local_resource_id),
           :ok <- observed_version(row, expected) do
        {:ok, projection(repo, row, issue)}
      end
    end)
  end

  def append_sync_apply(%Multi{} = multi, key, request) do
    write_key = {key, :sync_write}

    multi
    |> Multi.run(write_key, fn repo, _ ->
      with :ok <- validate_request(request),
           {:ok, repository} <- repository(repo, request.repository_id),
           {:ok, {row, issue}} <- apply_row(repo, repository, request) do
        {:ok, %{row: row, issue: issue, repository: repository}}
      end
    end)
    |> DomainOutbox.record_multi({key, :sync_outbox}, fn changes ->
      event(Map.fetch!(changes, write_key), request)
    end)
    |> Audit.record_multi(
      {key, :sync_audit},
      nil,
      "github_sync.applied",
      "repository",
      fn changes -> Map.fetch!(changes, write_key).repository.id end,
      fn changes ->
        result = Map.fetch!(changes, write_key)

        %{
          "repository_id" => result.repository.id,
          "resource_id" => result.row.id,
          "resource_kind" => Atom.to_string(request.resource_kind),
          "action" => Atom.to_string(request.action)
        }
      end
    )
    |> Multi.run(key, fn repo, changes ->
      %{row: row, issue: issue} = Map.fetch!(changes, write_key)

      result =
        if request.action == :delete,
          do: envelope(row) |> Map.merge(comment_route(issue)) |> Map.put(:deleted, true),
          else: projection(repo, row, issue)

      {:ok, result}
    end)
  end

  defp validate_expected(
         %{
           repository_id: repository_id,
           resource_kind: kind,
           local_resource_id: id,
           expected_local_version: version
         } = expected
       )
       when valid_id(repository_id) and kind in [:issue, :issue_comment] and
              valid_id(id) and valid_id(version) and version < @max_id and
              not is_map_key(expected, :minimum_local_version),
       do: :ok

  defp validate_expected(_), do: {:error, :invalid_sync_request}

  defp validate_observation(%{minimum_local_version: minimum} = expected)
       when not is_map_key(expected, :expected_local_version) do
    expected
    |> Map.delete(:minimum_local_version)
    |> Map.put(:expected_local_version, minimum)
    |> validate_expected()
  end

  defp validate_observation(expected), do: validate_expected(expected)

  defp observed_version(%{sync_version: current}, %{minimum_local_version: minimum})
       when current >= minimum, do: :ok

  defp observed_version(row, %{expected_local_version: expected}), do: version(row, expected)
  defp observed_version(_, _), do: {:error, :stale_local_version}

  defp validate_request(
         %{action: action, resource_kind: kind, fields: fields, provenance: %{origin: :github}} =
           request
       )
       when action in [:create, :update, :delete] and kind in [:issue, :issue_comment] and
              is_map(fields) do
    identity_valid =
      if action == :create do
        valid_id(request[:repository_id]) and
          request[:local_resource_id] == nil and request[:expected_local_version] == :missing and
          valid_id(request[:author_github_identity_id]) and
          match?(%DateTime{}, request[:inserted_at]) and match?(%DateTime{}, request[:updated_at]) and
          if kind == :issue,
            do: valid_id(request[:github_number]) and request.github_number < @max_id,
            else: valid_id(request[:parent_issue_id])
      else
        validate_expected(request) == :ok
      end

    fields_valid =
      case {kind, action} do
        {:issue, :delete} ->
          false

        {:issue, _} ->
          Enum.sort(Map.keys(fields)) == ~w(body state state_reason title) and
            bounded_list?(request[:local_label_ids]) and bounded_list?(request[:assignee_refs])

        {:issue_comment, :delete} ->
          true

        {:issue_comment, _} ->
          Map.keys(fields) == ["body"]
      end

    if identity_valid and fields_valid, do: :ok, else: {:error, :invalid_sync_request}
  end

  defp validate_request(_), do: {:error, :invalid_sync_request}

  defp bounded_list?(value) when is_list(value),
    do: length(Enum.take(value, @max_relationships + 1)) <= @max_relationships

  defp bounded_list?(_), do: false

  defp repository(repo, id) when valid_id(id) do
    case repo.one(from r in ForgeRepos.Repository, where: r.id == ^id and is_nil(r.deleted_at)) do
      %ForgeRepos.Repository{lifecycle: lifecycle} = repository
      when lifecycle in [:ready, :synchronizing] ->
        {:ok, repository}

      _ ->
        {:error, :not_found}
    end
  end

  defp repository(_, _), do: {:error, :not_found}

  defp resource(repo, repository, :issue, id) when valid_id(id) do
    case repo.one(
           from i in Issue,
             where: i.id == ^id and i.repository_id == ^repository.id and i.kind == :issue,
             lock: "FOR UPDATE"
         ) do
      %Issue{} = issue -> {:ok, {issue, issue}}
      nil -> {:error, :not_found}
    end
  end

  defp resource(repo, repository, :issue_comment, id) when valid_id(id) do
    case repo.one(
           from c in Comment,
             join: i in Issue,
             on: i.id == c.issue_id,
             where: c.id == ^id and i.repository_id == ^repository.id,
             select: {c, i},
             lock: "FOR UPDATE"
         ) do
      {%Comment{}, %Issue{}} = result -> {:ok, result}
      nil -> {:error, :not_found}
    end
  end

  defp resource(_, _, _, _), do: {:error, :not_found}

  defp version(%{sync_version: version}, version), do: :ok
  defp version(_, _), do: {:error, :stale_local_version}

  defp apply_row(repo, repository, %{action: :create, resource_kind: :issue} = request) do
    with :ok <- author_exists(request.author_github_identity_id),
         :ok <- reserve_number(repo, repository.id, request.github_number),
         {:ok, issue} <-
           repo.insert(
             Issue.import_changeset(
               %Issue{repository_id: repository.id, kind: :issue},
               request.fields
               |> Map.merge(%{
                 "number" => request.github_number,
                 "author_github_identity_id" => request.author_github_identity_id,
                 "inserted_at" => request.inserted_at,
                 "updated_at" => request.updated_at,
                 "closed_at" =>
                   if(request.fields["state"] == "closed", do: request.updated_at, else: nil)
               })
             )
           ),
         :ok <- relationships(repo, issue, request) do
      {:ok, {issue, issue}}
    end
  end

  defp apply_row(repo, repository, %{action: :create, resource_kind: :issue_comment} = request) do
    with :ok <- author_exists(request.author_github_identity_id),
         %Issue{} = issue <-
           repo.one(
             from i in Issue,
               where: i.id == ^request.parent_issue_id and i.repository_id == ^repository.id,
               lock: "FOR UPDATE"
           ),
         {:ok, comment} <-
           repo.insert(
             Comment.import_changeset(
               %Comment{issue_id: issue.id},
               Map.merge(request.fields, %{
                 "author_github_identity_id" => request.author_github_identity_id,
                 "inserted_at" => request.inserted_at,
                 "updated_at" => request.updated_at
               })
             )
           ) do
      {:ok, {comment, issue}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_row(repo, repository, request) do
    with {:ok, {row, issue}} <-
           resource(repo, repository, request.resource_kind, request.local_resource_id),
         :ok <- version(row, request.expected_local_version),
         {:ok, updated} <- mutate(repo, row, request),
         :ok <-
           if(request.resource_kind == :issue,
             do: relationships(repo, updated, request),
             else: :ok
           ) do
      {:ok, {updated, if(request.resource_kind == :issue, do: updated, else: issue)}}
    end
  end

  defp mutate(repo, %Issue{} = row, request),
    do:
      repo.update(Issue.update_changeset(row, request.fields),
        force: true,
        stale_error_field: :id
      )

  defp mutate(repo, %Comment{} = row, %{action: :update} = request),
    do:
      repo.update(Comment.update_changeset(row, request.fields),
        force: true,
        stale_error_field: :id
      )

  defp mutate(repo, %Comment{} = row, %{action: :delete}) do
    row
    |> Changeset.change()
    |> Changeset.optimistic_lock(:sync_version, &(&1 + 1))
    |> repo.delete(stale_error_field: :id)
  end

  defp author_exists(id) do
    if Map.has_key?(ForgeAccounts.resolve_attributions([{:github, id}]), {:github, id}),
      do: :ok,
      else: {:error, :invalid_author}
  end

  defp reserve_number(repo, repository_id, number) do
    with {:ok, _} <-
           repo.insert(
             NumberSequence.changeset(%NumberSequence{}, %{repository_id: repository_id}),
             on_conflict: :nothing,
             conflict_target: [:repository_id]
           ) do
      sequence =
        repo.one!(
          from s in NumberSequence, where: s.repository_id == ^repository_id, lock: "FOR UPDATE"
        )

      if repo.exists?(
           from i in Issue, where: i.repository_id == ^repository_id and i.number == ^number
         ) do
        {:error, :namespace_collision}
      else
        case repo.update(
               NumberSequence.finalize_changeset(sequence, %{
                 next_number: max(sequence.next_number, number + 1)
               })
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc false
  # Trusted aggregate callers must hold the canonical Issue lock. This helper
  # replaces membership only; version and event ownership remain with the caller.
  def replace_relationships(repo, %Issue{} = issue, request) when is_map(request) do
    if repo.in_transaction?() and bounded_list?(request[:local_label_ids]) and
         bounded_list?(request[:assignee_refs]) and
         Enum.all?(request.assignee_refs, &relationship_ref?/1) do
      with {:ok, _} <-
             lock_assignee_identities(repo, assignee_refs(repo, issue) ++ request.assignee_refs),
           do: relationships(repo, issue, request)
    else
      {:error, :invalid_relationship}
    end
  end

  def replace_relationships(_, _, _), do: {:error, :invalid_relationship}

  @doc false
  # Canonical preimages use local identity row IDs, never provider names/logins.
  # User FK fences prevent new identity links; known identity share locks prevent
  # unlinking. NOWAIT avoids waiting against Accounts' identity-first write order.
  def relationship_projection(repo, %Issue{} = issue) do
    if repo.in_transaction?() do
      labels =
        repo.all(
          from l in IssueLabel,
            where: l.issue_id == ^issue.id,
            order_by: l.label_id,
            select: l.label_id
        )

      refs = assignee_refs(repo, issue)

      with true <- bounded_list?(labels) and bounded_list?(refs),
           {:ok, identities} <- lock_assignee_identities(repo, refs),
           {:ok, managed} <- managed_identities(refs, identities) do
        {:ok,
         %{
           label_ids: labels,
           assignee_refs: refs,
           relationship_preimage: %{label_ids: labels, managed_assignee_identity_ids: managed}
         }}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_relationship}
      end
    else
      {:error, :invalid_relationship}
    end
  end

  def relationship_projection(_, _), do: {:error, :invalid_relationship}

  defp relationship_ref?(%{kind: kind, id: id} = ref)
       when kind in [:local_user, :github_identity] and valid_id(id), do: map_size(ref) == 2

  defp relationship_ref?(_), do: false

  defp lock_assignee_identities(repo, refs) do
    user_ids = for %{kind: :local_user, id: id} <- refs, do: id
    identity_ids = for %{kind: :github_identity, id: id} <- refs, do: id

    # Each lock query uses a savepoint so NOWAIT rejection leaves the caller's
    # transaction usable long enough to return a typed Multi rollback reason.
    repo.all(
      from(u in ForgeAccounts.User,
        where: u.id in ^user_ids,
        order_by: u.id,
        lock: "FOR UPDATE NOWAIT"
      ),
      mode: :savepoint
    )

    identities =
      repo.all(
        from(i in ForgeAccounts.GitHubIdentity,
          where: i.kind == :user and (i.local_user_id in ^user_ids or i.id in ^identity_ids),
          order_by: i.id,
          lock: "FOR SHARE NOWAIT"
        ),
        mode: :savepoint
      )

    {:ok, identities}
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :lock_not_available,
        do: {:error, :relationship_lock_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp managed_identities(refs, identities) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, ids} ->
      matches =
        Enum.filter(identities, fn i ->
          if ref.kind == :local_user, do: i.local_user_id == ref.id, else: i.id == ref.id
        end)

      case {ref.kind, matches} do
        {:local_user, []} -> {:cont, {:ok, ids}}
        {_, [identity]} -> {:cont, {:ok, [identity.id | ids]}}
        {_, []} -> {:halt, {:error, :invalid_relationship}}
        _ -> {:halt, {:error, :ambiguous_assignee_identity}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.sort(Enum.uniq(ids))}
      error -> error
    end
  end

  defp relationships(repo, issue, request) do
    labels = Enum.uniq(request.local_label_ids)
    refs = Enum.uniq(request.assignee_refs)
    valid_labels = Enum.all?(labels, &valid_id/1)

    valid_refs =
      Enum.all?(refs, fn
        %{kind: kind, id: id} = ref
        when kind in [:local_user, :github_identity] and valid_id(id) ->
          map_size(ref) == 2

        _ ->
          false
      end)

    if valid_labels and valid_refs and
         repo.aggregate(
           from(l in Label, where: l.repository_id == ^issue.repository_id and l.id in ^labels),
           :count
         ) == length(labels) and
         map_size(ForgeAccounts.resolve_attributions(Enum.map(refs, &attribution_ref/1))) ==
           length(refs) do
      refs = Enum.uniq(refs ++ unmanaged_assignees(repo, issue))
      repo.delete_all(from l in IssueLabel, where: l.issue_id == ^issue.id)
      repo.delete_all(from a in IssueAssignee, where: a.issue_id == ^issue.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      repo.insert_all(
        IssueLabel,
        Enum.map(labels, &%{issue_id: issue.id, label_id: &1, inserted_at: now, updated_at: now})
      )

      repo.insert_all(
        IssueAssignee,
        Enum.map(refs, fn ref ->
          %{
            issue_id: issue.id,
            user_id: if(ref.kind == :local_user, do: ref.id),
            github_identity_id: if(ref.kind == :github_identity, do: ref.id),
            inserted_at: now,
            updated_at: now
          }
        end)
      )

      :ok
    else
      {:error, :invalid_relationship}
    end
  end

  defp unmanaged_assignees(repo, issue) do
    assignee_refs(repo, issue)
    |> Enum.filter(fn
      %{kind: :local_user, id: id} ->
        ForgeAccounts.list_github_identities(ForgeAccounts.get_user(id)) == []

      _ ->
        false
    end)
  end

  defp attribution_ref(%{kind: :local_user, id: id}), do: {:user, id}
  defp attribution_ref(%{kind: :github_identity, id: id}), do: {:github, id}

  defp projection(repo, %Issue{} = issue, _parent) do
    Map.merge(envelope(issue), %{
      fields: %{
        "title" => issue.title,
        "body" => issue.body,
        "state" => Atom.to_string(issue.state),
        "state_reason" => if(issue.state_reason, do: Atom.to_string(issue.state_reason))
      },
      label_ids:
        repo.all(
          from l in IssueLabel,
            where: l.issue_id == ^issue.id,
            order_by: l.label_id,
            select: l.label_id
        ),
      assignee_refs: assignee_refs(repo, issue)
    })
  end

  defp projection(_repo, %Comment{} = comment, issue),
    do:
      envelope(comment)
      |> Map.merge(comment_route(issue))
      |> Map.merge(%{fields: %{"body" => comment.body}, label_ids: [], assignee_refs: []})

  defp comment_route(issue),
    do: %{
      repository_id: issue.repository_id,
      parent_issue_id: issue.id,
      issue_number: issue.number,
      issue_kind: issue.kind
    }

  defp envelope(%Issue{} = issue),
    do: %{
      repository_id: issue.repository_id,
      resource_kind: :issue,
      local_resource_id: issue.id,
      local_resource_type: "ForgeIssues.Issue",
      local_version: issue.sync_version
    }

  defp envelope(%Comment{} = comment),
    do: %{
      resource_kind: :issue_comment,
      local_resource_id: comment.id,
      local_resource_type: "ForgeIssues.Comment",
      local_version: comment.sync_version
    }

  defp assignee_refs(repo, issue) do
    repo.all(from a in IssueAssignee, where: a.issue_id == ^issue.id)
    |> Enum.map(fn
      %{user_id: id} when is_integer(id) -> %{kind: :local_user, id: id}
      %{github_identity_id: id} -> %{kind: :github_identity, id: id}
    end)
    |> Enum.sort_by(&{&1.kind, &1.id})
  end

  defp event(%{row: row, issue: issue, repository: repository}, request) do
    type = Atom.to_string(request.resource_kind)
    suffix = %{create: "created", update: "updated", delete: "deleted"}[request.action]

    payload = %{
      "repository_id" => repository.id,
      "issue_id" => issue.id,
      "issue_number" => issue.number,
      "issue_kind" => Atom.to_string(issue.kind),
      "sync_version" => row.sync_version
    }

    payload =
      if request.resource_kind == :issue_comment,
        do:
          Map.merge(payload, %{
            "comment_id" => row.id,
            "author_user_id" => row.author_user_id,
            "author_github_identity_id" => row.author_github_identity_id,
            "deleted" => request.action == :delete
          }),
        else: payload

    %{
      event_id: Ecto.UUID.generate(),
      aggregate_type: type,
      aggregate_id: to_string(row.id),
      event_type: type <> "." <> suffix,
      payload: payload,
      origin: :github,
      causation_id: request.provenance[:causation_id],
      correlation_id: request.provenance[:correlation_id]
    }
  end
end
