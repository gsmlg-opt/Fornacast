defmodule ForgeIssues do
  @moduledoc """
  Composable operations for canonical issue identities.

  Callers build one complete `Ecto.Multi` and execute it through `transaction/1`.
  Authorization remains the responsibility of the outer issue or pull-request
  context, where repository access is available.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias ForgeIssues.{
    Comment,
    DefaultLabels,
    Issue,
    IssueAssignee,
    IssueLabel,
    Label,
    NumberSequence
  }

  alias Fornacast.Repo

  @turso_busy_attempts 12
  @turso_busy_backoff_ms 5

  @doc """
  Executes a complete caller-owned multi as one transaction.

  ExTurso classifies concurrent-writer contention as a retryable `:busy`
  exception. On Turso, this function retries the entire transaction a bounded
  number of times; other adapters and all other errors are executed once.
  Multi callbacks must therefore keep external side effects outside the
  transaction boundary.
  """
  @spec transaction(Multi.t()) ::
          {:ok, map()} | {:error, Multi.name(), term(), map()}
  def transaction(%Multi{} = multi) do
    attempts = if Repo.__adapter__() == Ecto.Adapters.Turso, do: @turso_busy_attempts, else: 1
    transact(multi, attempts)
  end

  @spec insert_numbered_identity(
          Multi.t(),
          Multi.name(),
          ForgeRepos.Repository.t(),
          ForgeAccounts.User.t(),
          :issue | :pull_request,
          map()
        ) :: Multi.t()
  def insert_numbered_identity(multi, key, repository, actor, kind, attrs)
      when kind in [:issue, :pull_request] do
    sequence_key = {key, :sequence}
    number_key = {key, :number}

    multi
    |> Multi.insert(
      sequence_key,
      NumberSequence.changeset(%NumberSequence{}, %{repository_id: repository.id}),
      on_conflict: :nothing,
      conflict_target: [:repository_id]
    )
    |> Multi.run(number_key, fn repo, _changes ->
      query = from(sequence in NumberSequence, where: sequence.repository_id == ^repository.id)

      case repo.update_all(query, inc: [next_number: 1]) do
        {1, _rows} ->
          next_number = repo.one!(from(sequence in query, select: sequence.next_number))
          {:ok, next_number - 1}

        {0, _rows} ->
          {:error, {:unavailable, :database}}
      end
    end)
    |> Multi.insert(key, fn changes ->
      %Issue{
        repository_id: repository.id,
        number: Map.fetch!(changes, number_key),
        kind: kind,
        author_user_id: actor.id
      }
      |> Issue.create_changeset(attrs)
    end)
  end

  @spec update_identity(Multi.t(), Multi.name(), Issue.t(), ForgeAccounts.User.t(), map()) ::
          Multi.t()
  def update_identity(multi, key, %Issue{} = issue, _actor, attrs) do
    Multi.update(multi, key, fn _changes -> Issue.update_changeset(issue, attrs) end)
  end

  @spec list_labels(ForgeRepos.Repository.t()) :: [Label.t()]
  def list_labels(%ForgeRepos.Repository{} = repository), do: DefaultLabels.ensure(repository)

  @spec put_relationship_operations(
          Multi.t(),
          Multi.name(),
          ForgeRepos.Repository.t(),
          ForgeAccounts.User.t(),
          map(),
          :author | :writer
        ) :: Multi.t()
  def put_relationship_operations(multi, key, repository, _actor, attrs, capability)
      when capability in [:author, :writer] and is_map(attrs) do
    attrs =
      if capability == :author,
        do: Map.drop(attrs, ["labels", "assignee", "assignees"]),
        else: attrs

    multi
    |> Multi.run({key, :relationships}, fn _repo, changes ->
      case Map.fetch(changes, key) do
        {:ok, %Issue{repository_id: repository_id}} when repository_id == repository.id ->
          resolve_relationships(repository, attrs)

        _ ->
          {:error, :not_found}
      end
    end)
    |> Multi.merge(fn changes ->
      issue = Map.fetch!(changes, key)
      relationships = Map.fetch!(changes, {key, :relationships})
      replace_relationships(key, issue, relationships)
    end)
  end

  @spec load_labels(Issue.t()) :: [Label.t()]
  def load_labels(%Issue{} = issue) do
    IssueLabel
    |> join(:inner, [join], label in Label, on: label.id == join.label_id)
    |> where([join], join.issue_id == ^issue.id)
    |> order_by([_join, label], asc: label.normalized_name)
    |> select([_join, label], label)
    |> Repo.all()
  end

  @spec load_assignees(Issue.t()) :: [ForgeAccounts.User.t()]
  def load_assignees(%Issue{} = issue) do
    IssueAssignee
    |> where([join], join.issue_id == ^issue.id)
    |> select([join], join.user_id)
    |> Repo.all()
    |> Enum.map(&ForgeAccounts.get_user/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.username)
  end

  @spec load_issue_metadata(Issue.t() | [Issue.t()], ForgeRepos.Repository.t()) ::
          Issue.t() | [Issue.t()] | {:error, :not_found}
  def load_issue_metadata(issues, repository) when is_list(issues) do
    if Enum.all?(issues, &issue_in_repository?(&1, repository)) do
      do_load_issue_metadata(issues, repository)
    else
      {:error, :not_found}
    end
  end

  def load_issue_metadata(%Issue{} = issue, repository) do
    if issue_in_repository?(issue, repository) do
      load_issue_metadata(issue, repository, comment_counts([issue]))
    else
      {:error, :not_found}
    end
  end

  defp do_load_issue_metadata(issues, repository) do
    issue_ids = Enum.map(issues, & &1.id)
    labels = labels_by_issue(issue_ids)
    assignee_ids = assignee_ids_by_issue(issue_ids)

    users =
      issues
      |> Enum.map(& &1.author_user_id)
      |> Kernel.++(assignee_ids |> Map.values() |> List.flatten())
      |> ForgeAccounts.get_users()
      |> Map.new(&{&1.id, &1})

    associations = author_associations(issues, repository, users)
    counts = comment_counts(issues)

    Enum.map(issues, fn issue ->
      assignees =
        assignee_ids
        |> Map.get(issue.id, [])
        |> Enum.map(&Map.fetch!(users, &1))
        |> Enum.sort_by(& &1.username)

      %{
        issue
        | labels: Map.get(labels, issue.id, []),
          assignees: assignees,
          author: Map.get(users, issue.author_user_id),
          author_association: Map.get(associations, issue.author_user_id, "NONE"),
          comment_count: Map.get(counts, issue.id, 0)
      }
    end)
  end

  defp load_issue_metadata(issue, repository, counts) do
    author = ForgeAccounts.get_user(issue.author_user_id)

    %{
      issue
      | labels: load_labels(issue),
        assignees: load_assignees(issue),
        author: author,
        author_association: author_association(author, repository),
        comment_count: Map.get(counts, issue.id, 0)
    }
  end

  defp issue_in_repository?(%Issue{repository_id: repository_id}, %{id: repository_id}), do: true
  defp issue_in_repository?(_issue, _repository), do: false

  defp labels_by_issue([]), do: %{}

  defp labels_by_issue(issue_ids) do
    IssueLabel
    |> join(:inner, [join], label in Label, on: label.id == join.label_id)
    |> where([join], join.issue_id in ^issue_ids)
    |> order_by([_join, label], asc: label.normalized_name)
    |> select([join, label], {join.issue_id, label})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp assignee_ids_by_issue([]), do: %{}

  defp assignee_ids_by_issue(issue_ids) do
    IssueAssignee
    |> where([join], join.issue_id in ^issue_ids)
    |> order_by([join], asc: join.user_id)
    |> select([join], {join.issue_id, join.user_id})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp resolve_relationships(repository, attrs) do
    _labels = DefaultLabels.ensure(repository)

    with {:ok, label_request} <- requested_label_names(attrs),
         {:ok, assignee_request} <- requested_assignee_names(attrs),
         {:ok, labels} <- resolve_labels(repository, label_request),
         {:ok, assignees} <- resolve_assignees(repository, assignee_request) do
      {:ok, %{labels: labels, assignees: assignees}}
    end
  end

  defp requested_label_names(attrs) do
    case Map.fetch(attrs, "labels") do
      :error ->
        {:ok, :unchanged}

      {:ok, labels} when is_list(labels) ->
        normalize_label_entries(labels)

      {:ok, _labels} ->
        {:error, missing_labels_error()}
    end
  end

  defp requested_assignee_names(attrs) do
    cond do
      Map.has_key?(attrs, "assignees") ->
        normalize_assignee_entries(Map.fetch!(attrs, "assignees"))

      Map.get(attrs, "assignee") in [nil, ""] ->
        {:ok, :unchanged}

      is_binary(Map.get(attrs, "assignee")) ->
        {:ok, {:replace, [Map.fetch!(attrs, "assignee")]}}

      true ->
        {:error, invalid_assignees_error()}
    end
  end

  defp normalize_label_entries(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn
      name, {:ok, names} when is_binary(name) ->
        {:cont, {:ok, [DefaultLabels.normalize_name(name) | names]}}

      %{"name" => name}, {:ok, names} when is_binary(name) ->
        {:cont, {:ok, [DefaultLabels.normalize_name(name) | names]}}

      _entry, _acc ->
        {:halt, {:error, missing_labels_error()}}
    end)
    |> case do
      {:ok, names} -> {:ok, {:replace, Enum.reverse(names)}}
      error -> error
    end
  end

  defp normalize_assignee_entries(names) when is_list(names) do
    if Enum.all?(names, &is_binary/1),
      do: {:ok, {:replace, names}},
      else: {:error, invalid_assignees_error()}
  end

  defp normalize_assignee_entries(_names), do: {:error, invalid_assignees_error()}

  defp resolve_labels(_repository, :unchanged), do: {:ok, :unchanged}

  defp resolve_labels(repository, {:replace, names}) do
    names = Enum.uniq(names)

    labels =
      Label
      |> where([label], label.repository_id == ^repository.id and label.normalized_name in ^names)
      |> Repo.all()

    if length(labels) == length(names), do: {:ok, labels}, else: {:error, missing_labels_error()}
  end

  defp resolve_assignees(_repository, :unchanged), do: {:ok, :unchanged}

  defp resolve_assignees(repository, {:replace, names}) do
    users = Enum.map(names, &ForgeAccounts.get_user_by_username/1)

    if Enum.all?(users, &eligible_assignee?(&1, repository)) do
      {:ok, users |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)}
    else
      {:error, invalid_assignees_error()}
    end
  end

  defp eligible_assignee?(%ForgeAccounts.User{kind: :user, state: :active} = user, repository),
    do: Fornacast.Access.authorize(user, :repository_read, repository) == :ok

  defp eligible_assignee?(_, _repository), do: false

  defp replace_relationships(key, issue, %{labels: labels, assignees: assignees}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> replace_label_joins(key, issue, labels, now)
    |> replace_assignee_joins(key, issue, assignees, now)
  end

  defp replace_label_joins(multi, _key, _issue, :unchanged, _now), do: multi

  defp replace_label_joins(multi, key, issue, labels, now) do
    multi
    |> Multi.delete_all(
      {key, :delete_labels},
      # WORKAROUND(upstream): gsmlg-dev/concord#66
      from(_join in IssueLabel, where: fragment("issue_id = ?", ^issue.id))
    )
    |> Multi.insert_all(
      {key, :insert_labels},
      IssueLabel,
      Enum.map(labels, &%{issue_id: issue.id, label_id: &1.id, inserted_at: now, updated_at: now})
    )
  end

  defp replace_assignee_joins(multi, _key, _issue, :unchanged, _now), do: multi

  defp replace_assignee_joins(multi, key, issue, assignees, now) do
    multi
    |> Multi.delete_all(
      {key, :delete_assignees},
      # WORKAROUND(upstream): gsmlg-dev/concord#66
      from(_join in IssueAssignee, where: fragment("issue_id = ?", ^issue.id))
    )
    |> Multi.insert_all(
      {key, :insert_assignees},
      IssueAssignee,
      Enum.map(
        assignees,
        &%{issue_id: issue.id, user_id: &1.id, inserted_at: now, updated_at: now}
      )
    )
  end

  defp comment_counts([]), do: %{}

  defp comment_counts(issues) do
    ids = Enum.map(issues, & &1.id)

    Comment
    |> where([comment], comment.issue_id in ^ids)
    |> group_by([comment], comment.issue_id)
    |> select([comment], {comment.issue_id, count(comment.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp author_association(nil, _repository), do: "NONE"
  defp author_association(%ForgeAccounts.User{id: id}, %{owner_user_id: id}), do: "OWNER"

  defp author_association(author, repository) do
    case ForgeRepos.repository_owner(repository) do
      %ForgeAccounts.User{kind: :organization} = organization ->
        case ForgeAccounts.organization_role(author, organization) do
          :owner -> "OWNER"
          :member -> "MEMBER"
          _ -> collaborator_association(author, repository)
        end

      _ ->
        collaborator_association(author, repository)
    end
  end

  defp collaborator_association(author, repository) do
    if ForgeRepos.collaborator_role(author, repository), do: "COLLABORATOR", else: "NONE"
  end

  defp author_associations(issues, repository, users) do
    author_ids = issues |> Enum.map(& &1.author_user_id) |> Enum.uniq()
    owner = ForgeRepos.repository_owner(repository)
    collaborator_roles = ForgeRepos.collaborator_roles(author_ids, repository)

    organization_roles =
      case owner do
        %ForgeAccounts.User{kind: :organization} = organization ->
          ForgeAccounts.organization_roles(author_ids, organization)

        _ ->
          %{}
      end

    Map.new(author_ids, fn author_id ->
      association =
        cond do
          repository.owner_user_id == author_id -> "OWNER"
          Map.get(organization_roles, author_id) == :owner -> "OWNER"
          Map.get(organization_roles, author_id) == :member -> "MEMBER"
          Map.has_key?(collaborator_roles, author_id) -> "COLLABORATOR"
          Map.has_key?(users, author_id) -> "NONE"
          true -> "NONE"
        end

      {author_id, association}
    end)
  end

  defp missing_labels_error,
    do: {:validation, [%{resource: "Issue", field: "labels", code: :missing}]}

  defp invalid_assignees_error,
    do: {:validation, [%{resource: "Issue", field: "assignees", code: :invalid}]}

  defp transact(multi, attempts_remaining) do
    Repo.transaction(multi)
  rescue
    error in Turso.Error ->
      if Repo.__adapter__() == Ecto.Adapters.Turso and error.code == :busy and
           attempts_remaining > 1 do
        attempt = @turso_busy_attempts - attempts_remaining + 1
        Process.sleep(attempt * @turso_busy_backoff_ms)
        transact(multi, attempts_remaining - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
