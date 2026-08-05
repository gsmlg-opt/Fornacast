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

  alias Fornacast.{Audit, Page, Repo}

  @turso_busy_attempts 12
  @turso_busy_backoff_ms 5

  @type validation_error :: %{
          required(:resource) => String.t(),
          required(:field) => String.t(),
          required(:code) => :invalid | :unprocessable
        }

  @spec list(ForgeAccounts.User.t() | nil, String.t(), String.t(), map()) ::
          {:ok, Page.t(Issue.t())} | {:error, term()}
  def list(actor, owner_slug, repository_slug, filters) when is_map(filters) do
    with {:ok, repository} <-
           fetch_repository(actor, owner_slug, repository_slug, :repository_read),
         {:ok, filters} <- validate_list_filters(filters) do
      query =
        Issue
        |> where([issue], issue.repository_id == ^repository.id)
        |> scope_enabled_issue_kinds(repository)
        |> filter_state(filters.state)
        |> filter_labels(repository.id, filters.labels)
        |> filter_assignee(filters.assignee)
        |> filter_creator(filters.creator)
        |> filter_since(filters.since)
        |> order_issues(filters.sort, filters.direction)

      total = Repo.aggregate(query, :count, :id)

      entries =
        query
        |> limit(^filters.per_page)
        |> offset(^filters.offset)
        |> Repo.all()
        |> do_load_issue_metadata(repository)

      {:ok, %Page{entries: entries, total: total, page: filters.page, per_page: filters.per_page}}
    end
  end

  def list(_actor, _owner_slug, _repository_slug, _filters), do: invalid_filter("base")

  @spec get(ForgeAccounts.User.t() | nil, String.t(), String.t(), pos_integer()) ::
          {:ok, Issue.t()} | {:error, term()}
  def get(actor, owner_slug, repository_slug, number) when is_integer(number) and number > 0 do
    with {:ok, repository} <-
           fetch_repository(actor, owner_slug, repository_slug, :repository_read),
         %Issue{} = issue <-
           Repo.one(
             from(issue in Issue,
               where: issue.repository_id == ^repository.id and issue.number == ^number
             )
           ),
         :ok <- require_identity_enabled(repository, issue) do
      {:ok, load_issue_metadata(issue, repository)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def get(_actor, _owner_slug, _repository_slug, _number), do: {:error, :not_found}

  @spec create(ForgeAccounts.User.t(), String.t(), String.t(), map(), map()) ::
          {:ok, Issue.t()} | {:error, term()}
  def create(actor, owner_slug, repository_slug, attrs, request_metadata)
      when is_map(attrs) and is_map(request_metadata) do
    with {:ok, repository} <-
           fetch_repository(actor, owner_slug, repository_slug, :repository_read),
         {:ok, multi} <- create_mutation_multi(actor, repository, attrs, request_metadata) do
      multi
      |> transaction()
      |> map_create_result()
    end
  end

  def create(_actor, _owner_slug, _repository_slug, _attrs, _request_metadata),
    do: {:error, :forbidden}

  @spec update(ForgeAccounts.User.t(), String.t(), String.t(), pos_integer(), map(), map()) ::
          {:ok, Issue.t()} | {:error, term()}
  def update(actor, owner_slug, repository_slug, number, attrs, request_metadata)
      when is_integer(number) and number > 0 and is_map(attrs) and is_map(request_metadata) do
    with {:ok, repository} <-
           fetch_repository(actor, owner_slug, repository_slug, :repository_read),
         {:ok, multi} <-
           update_mutation_multi(actor, repository, number, attrs, request_metadata) do
      multi
      |> transaction()
      |> map_update_result()
    end
  end

  def update(_actor, _owner_slug, _repository_slug, _number, _attrs, _request_metadata),
    do: {:error, :forbidden}

  defp create_mutation_multi(%ForgeAccounts.User{} = actor, repository, attrs, request_metadata),
    do: {:ok, create_multi(actor, repository, attrs, request_metadata)}

  defp create_mutation_multi(_actor, _repository, _attrs, _request_metadata),
    do: {:error, :forbidden}

  defp update_mutation_multi(
         %ForgeAccounts.User{} = actor,
         repository,
         number,
         attrs,
         request_metadata
       ),
       do: {:ok, update_multi(actor, repository, number, attrs, request_metadata)}

  defp update_mutation_multi(_actor, _repository, _number, _attrs, _request_metadata),
    do: {:error, :forbidden}

  @doc false
  @spec create_multi(ForgeAccounts.User.t(), ForgeRepos.Repository.t(), map(), map()) :: Multi.t()
  def create_multi(
        %ForgeAccounts.User{id: actor_id},
        %ForgeRepos.Repository{id: repository_id},
        attrs,
        request_metadata
      )
      when is_integer(actor_id) and is_integer(repository_id) and is_map(attrs) and
             is_map(request_metadata) do
    attrs = normalize_attrs(attrs)
    request_metadata = safe_request_metadata(request_metadata)

    Multi.new()
    |> Multi.run(:authorization, fn repo, _changes ->
      authorize_create_transaction(repo, actor_id, repository_id)
    end)
    |> Multi.merge(fn %{authorization: context} ->
      %{actor: actor, repository: repository, capability: capability} = context
      identity_attrs = Map.take(attrs, ["title", "body", "state", "state_reason"])

      Multi.new()
      |> insert_numbered_identity(:issue, repository, actor, :issue, identity_attrs)
      |> put_relationship_operations(:issue, repository, actor, attrs, capability)
      |> Audit.record_multi(
        :audit,
        actor,
        "issue.created",
        "repository",
        repository.id,
        %{"repository_id" => repository.id, "result" => "success"},
        request_metadata: request_metadata
      )
    end)
  end

  @doc false
  @spec update_multi(
          ForgeAccounts.User.t(),
          ForgeRepos.Repository.t(),
          pos_integer(),
          map(),
          map()
        ) :: Multi.t()
  def update_multi(
        %ForgeAccounts.User{id: actor_id},
        %ForgeRepos.Repository{id: repository_id},
        number,
        attrs,
        request_metadata
      )
      when is_integer(actor_id) and is_integer(repository_id) and is_integer(number) and
             number > 0 and is_map(attrs) and is_map(request_metadata) do
    attrs = normalize_attrs(attrs)
    request_metadata = safe_request_metadata(request_metadata)

    Multi.new()
    |> Multi.run(:authorization, fn repo, _changes ->
      authorize_update_transaction(repo, actor_id, repository_id, number, attrs)
    end)
    |> Multi.merge(fn %{authorization: context} ->
      %{
        actor: actor,
        repository: repository,
        issue: issue,
        capability: capability,
        attrs: authorized_attrs
      } = context

      Multi.new()
      |> update_identity(
        :issue,
        issue,
        actor,
        Map.take(authorized_attrs, ["title", "body", "state", "state_reason"])
      )
      |> put_relationship_operations(:issue, repository, actor, authorized_attrs, capability)
      |> Audit.record_multi(
        :audit,
        actor,
        "issue.updated",
        "issue",
        fn %{issue: updated} -> updated.id end,
        %{"repository_id" => repository.id, "result" => "success"},
        request_metadata: request_metadata
      )
    end)
  end

  defp fetch_repository(actor, owner_slug, repository_slug, permission),
    do: ForgeRepos.fetch_authorized_repository(actor, owner_slug, repository_slug, permission)

  defp require_issues_enabled(%ForgeRepos.Repository{has_issues: true}), do: :ok
  defp require_issues_enabled(%ForgeRepos.Repository{}), do: {:error, :issues_disabled}

  defp require_identity_enabled(%ForgeRepos.Repository{has_issues: true}, %Issue{}), do: :ok
  defp require_identity_enabled(%ForgeRepos.Repository{}, %Issue{kind: :pull_request}), do: :ok

  defp require_identity_enabled(%ForgeRepos.Repository{}, %Issue{}),
    do: {:error, :issues_disabled}

  defp scope_enabled_issue_kinds(query, %ForgeRepos.Repository{has_issues: true}), do: query

  defp scope_enabled_issue_kinds(query, %ForgeRepos.Repository{}),
    do: where(query, [issue], issue.kind == :pull_request)

  defp create_capability(%ForgeAccounts.User{} = actor, repository) do
    if Fornacast.Access.allowed?(actor, :repository_read, repository),
      do:
        {:ok,
         if(Fornacast.Access.allowed?(actor, :repository_write, repository),
           do: :writer,
           else: :author
         )},
      else: {:error, :forbidden}
  end

  defp create_capability(_actor, _repository), do: {:error, :forbidden}

  defp authorize_create_transaction(repo, actor_id, repository_id) do
    with {:ok, actor} <- active_mutation_actor(repo, actor_id),
         {:ok, repository} <- current_repository(repo, repository_id),
         :ok <- authorize_repository_read(actor, repository),
         :ok <- require_issues_enabled(repository),
         {:ok, capability} <- create_capability(actor, repository) do
      {:ok, %{actor: actor, repository: repository, capability: capability}}
    end
  end

  defp authorize_update_transaction(repo, actor_id, repository_id, number, attrs) do
    with {:ok, actor} <- active_mutation_actor(repo, actor_id),
         {:ok, repository} <- current_repository(repo, repository_id),
         :ok <- authorize_repository_read(actor, repository),
         {:ok, issue} <- current_issue(repo, repository, number),
         :ok <- require_identity_enabled(repository, issue),
         {:ok, capability} <- mutation_capability(actor, repository, issue),
         {:ok, attrs} <- mutation_attrs(attrs, capability, issue) do
      {:ok,
       %{
         actor: actor,
         repository: repository,
         issue: issue,
         capability: capability,
         attrs: attrs
       }}
    end
  end

  defp active_mutation_actor(repo, actor_id) do
    case repo.get_by(ForgeAccounts.User, id: actor_id, kind: :user, state: :active) do
      %ForgeAccounts.User{state: :active} = actor -> {:ok, actor}
      _actor -> {:error, :forbidden}
    end
  end

  defp current_repository(repo, repository_id) do
    repository =
      ForgeRepos.Repository
      |> join(:inner, [repository], owner in ForgeAccounts.User,
        on: owner.id == repository.owner_user_id
      )
      |> where(
        [repository, owner],
        repository.id == ^repository_id and is_nil(repository.deleted_at) and
          owner.state == :active and owner.kind in [:user, :organization]
      )
      |> select([repository, _owner], repository)
      |> repo.one()

    if repository, do: {:ok, repository}, else: {:error, :not_found}
  end

  defp authorize_repository_read(actor, repository) do
    if Fornacast.Access.allowed?(actor, :repository_read, repository),
      do: :ok,
      else: {:error, :not_found}
  end

  defp current_issue(repo, repository, number) do
    case repo.one(
           from(issue in Issue,
             where: issue.repository_id == ^repository.id and issue.number == ^number
           )
         ) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, :not_found}
    end
  end

  defp mutation_capability(%ForgeAccounts.User{} = actor, repository, %Issue{
         author_user_id: author_id
       }) do
    cond do
      Fornacast.Access.allowed?(actor, :repository_write, repository) ->
        {:ok, :writer}

      actor.id == author_id and Fornacast.Access.allowed?(actor, :repository_read, repository) ->
        {:ok, :author}

      true ->
        {:error, :forbidden}
    end
  end

  defp mutation_capability(_actor, _repository, _issue), do: {:error, :forbidden}

  defp mutation_attrs(attrs, :writer, _issue), do: {:ok, attrs}

  defp mutation_attrs(attrs, :author, issue) do
    attrs = Map.take(attrs, ["title", "body", "state"])

    attrs =
      case {issue.state, Map.get(attrs, "state")} do
        {state, :closed} when state != :closed -> Map.put(attrs, "state_reason", :completed)
        {state, :open} when state != :open -> Map.put(attrs, "state_reason", :reopened)
        _transition -> attrs
      end

    {:ok, attrs}
  end

  defp map_create_result({:ok, %{authorization: %{repository: repository}, issue: issue}}),
    do: {:ok, load_issue_metadata(issue, repository)}

  defp map_create_result({:error, :authorization, reason, _changes}), do: {:error, reason}

  defp map_create_result({:error, :issue, changeset, _changes})
       when is_struct(changeset, Ecto.Changeset),
       do: {:error, {:validation, issue_changeset_errors(changeset)}}

  defp map_create_result({:error, _step, {:validation, _errors} = error, _changes}),
    do: {:error, error}

  defp map_create_result({:error, _step, {:unavailable, _reason} = error, _changes}),
    do: {:error, error}

  defp map_create_result({:error, _step, _reason, _changes}),
    do: invalid_filter("base", :unprocessable)

  defp map_update_result({:ok, %{authorization: %{repository: repository}, issue: issue}}),
    do: {:ok, load_issue_metadata(issue, repository)}

  defp map_update_result({:error, :authorization, reason, _changes}), do: {:error, reason}

  defp map_update_result({:error, :issue, changeset, _changes})
       when is_struct(changeset, Ecto.Changeset),
       do: {:error, {:validation, issue_changeset_errors(changeset)}}

  defp map_update_result({:error, _step, {:validation, _errors} = error, _changes}),
    do: {:error, error}

  defp map_update_result({:error, _step, _reason, _changes}),
    do: invalid_filter("base", :unprocessable)

  defp issue_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, _error} ->
      %{resource: "Issue", field: Atom.to_string(field), code: :invalid}
    end)
    |> Enum.uniq()
  end

  defp validate_list_filters(filters) do
    with {:ok, state} <- enum_filter(filters, "state", :open, [:open, :closed, :all]),
         {:ok, labels} <- labels_filter(filters),
         {:ok, assignee} <- assignee_filter(filters),
         {:ok, creator} <- username_filter(filters, "creator"),
         {:ok, sort} <- enum_filter(filters, "sort", :created, [:created, :updated, :comments]),
         {:ok, direction} <- enum_filter(filters, "direction", :desc, [:asc, :desc]),
         {:ok, since} <- since_filter(filters),
         {:ok, page} <- positive_integer_filter(filters, "page", 1, :infinity),
         {:ok, per_page} <- positive_integer_filter(filters, "per_page", 30, 100),
         {:ok, offset} <- page_offset(page, per_page) do
      {:ok,
       %{
         state: state,
         labels: labels,
         assignee: assignee,
         creator: creator,
         sort: sort,
         direction: direction,
         since: since,
         page: page,
         per_page: per_page,
         offset: offset
       }}
    end
  end

  defp enum_filter(filters, field, default, values) do
    case fetch_filter(filters, field, default) do
      value when is_atom(value) ->
        if(value in values, do: {:ok, value}, else: invalid_filter(field))

      value when is_binary(value) ->
        case Enum.find(values, &(Atom.to_string(&1) == String.downcase(value))) do
          nil -> invalid_filter(field)
          result -> {:ok, result}
        end

      _ ->
        invalid_filter(field)
    end
  end

  defp labels_filter(filters) do
    labels = fetch_filter(filters, "labels", [])

    labels =
      cond do
        is_binary(labels) -> String.split(labels, ",", trim: true)
        is_list(labels) and Enum.all?(labels, &is_binary/1) -> labels
        labels == [] -> []
        true -> :invalid
      end

    case labels do
      :invalid ->
        invalid_filter("labels")

      names ->
        names =
          names
          |> Enum.map(&DefaultLabels.normalize_name/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        if length(names) <= 100, do: {:ok, names}, else: invalid_filter("labels", :unprocessable)
    end
  end

  defp assignee_filter(filters) do
    case fetch_filter(filters, "assignee", nil) do
      nil ->
        {:ok, nil}

      "*" ->
        {:ok, :any}

      "none" ->
        {:ok, :none}

      username when is_binary(username) ->
        case ForgeAccounts.get_public_user(username) do
          {:ok, user} -> {:ok, {:user, user.id}}
          {:error, :not_found} -> {:ok, {:user, nil}}
        end

      _ ->
        invalid_filter("assignee")
    end
  end

  defp username_filter(filters, field) do
    case fetch_filter(filters, field, nil) do
      nil ->
        {:ok, nil}

      username when is_binary(username) ->
        case ForgeAccounts.get_public_user(username) do
          {:ok, user} -> {:ok, user.id}
          {:error, :not_found} -> {:ok, :missing}
        end

      _ ->
        invalid_filter(field)
    end
  end

  defp since_filter(filters) do
    case fetch_filter(filters, "since", nil) do
      nil ->
        {:ok, nil}

      %DateTime{} = value ->
        {:ok, DateTime.truncate(value, :second)}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _ -> invalid_filter("since", :unprocessable)
        end

      _ ->
        invalid_filter("since", :unprocessable)
    end
  end

  defp positive_integer_filter(filters, field, default, :infinity) do
    case fetch_filter(filters, field, default) do
      value when is_integer(value) and value >= 1 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 1 -> {:ok, integer}
          _ -> invalid_filter(field, :unprocessable)
        end

      _ ->
        invalid_filter(field, :unprocessable)
    end
  end

  defp positive_integer_filter(filters, field, default, maximum) do
    case fetch_filter(filters, field, default) do
      value when is_integer(value) and value >= 1 and value <= maximum ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 1 and integer <= maximum -> {:ok, integer}
          _ -> invalid_filter(field, :unprocessable)
        end

      _ ->
        invalid_filter(field, :unprocessable)
    end
  end

  defp page_offset(page, per_page) do
    offset = (page - 1) * per_page

    if offset <= 9_223_372_036_854_775_807,
      do: {:ok, offset},
      else: invalid_filter("page", :unprocessable)
  end

  defp fetch_filter(filters, field, default),
    do: Map.get(filters, field, Map.get(filters, String.to_atom(field), default))

  defp invalid_filter(field, code \\ :invalid),
    do: {:error, {:validation, [%{resource: "Issue", field: field, code: code}]}}

  defp filter_state(query, :all), do: query
  defp filter_state(query, state), do: where(query, [issue], issue.state == ^state)

  defp filter_labels(query, _repository_id, []), do: query

  defp filter_labels(query, repository_id, names) do
    matching_issue_ids =
      IssueLabel
      |> join(:inner, [join], label in Label, on: label.id == join.label_id)
      |> where(
        [_join, label],
        label.repository_id == ^repository_id and label.normalized_name in ^names
      )
      |> group_by([join], join.issue_id)
      |> having([_join, label], count(label.normalized_name, :distinct) == ^length(names))
      |> select([join], join.issue_id)

    where(query, [issue], issue.id in subquery(matching_issue_ids))
  end

  defp filter_assignee(query, nil), do: query

  defp filter_assignee(query, :any),
    do: where(query, [issue], issue.id in subquery(assignee_issue_ids()))

  defp filter_assignee(query, :none),
    do: where(query, [issue], issue.id not in subquery(assignee_issue_ids()))

  defp filter_assignee(query, {:user, nil}), do: where(query, [issue], false)

  defp filter_assignee(query, {:user, user_id}) do
    where(query, [issue], issue.id in subquery(assignee_issue_ids(user_id)))
  end

  defp assignee_issue_ids(user_id \\ nil) do
    IssueAssignee
    |> then(fn query ->
      if is_nil(user_id), do: query, else: where(query, [join], join.user_id == ^user_id)
    end)
    |> select([join], join.issue_id)
  end

  defp filter_creator(query, nil), do: query
  defp filter_creator(query, :missing), do: where(query, [issue], false)
  defp filter_creator(query, user_id), do: where(query, [issue], issue.author_user_id == ^user_id)
  defp filter_since(query, nil), do: query
  defp filter_since(query, since), do: where(query, [issue], issue.updated_at >= ^since)

  defp order_issues(query, :comments, direction) do
    counts =
      Comment
      |> group_by([comment], comment.issue_id)
      |> select([comment], %{issue_id: comment.issue_id, count: count(comment.id)})

    query
    |> join(:left, [issue], count in subquery(counts), on: count.issue_id == issue.id)
    |> order_by([issue, count], [{^direction, coalesce(count.count, 0)}, {^direction, issue.id}])
  end

  defp order_issues(query, :created, direction),
    do: order_by(query, [issue], [{^direction, issue.inserted_at}, {^direction, issue.id}])

  defp order_issues(query, :updated, direction),
    do: order_by(query, [issue], [{^direction, issue.updated_at}, {^direction, issue.id}])

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn {key, value} ->
      key = to_string(key)
      {key, normalize_attr_value(key, value)}
    end)
  end

  defp normalize_attr_value("state", value) when is_binary(value), do: safe_enum(value)
  defp normalize_attr_value("state_reason", value) when is_binary(value), do: safe_enum(value)
  defp normalize_attr_value(_key, value), do: value

  defp safe_enum(value) do
    case value do
      "open" -> :open
      "closed" -> :closed
      "completed" -> :completed
      "not_planned" -> :not_planned
      "reopened" -> :reopened
      _ -> value
    end
  end

  defp safe_request_metadata(metadata) do
    [:request_id, :api_version, :ip_address, :user_agent, :token_id]
    |> Enum.reduce(%{}, fn key, safe ->
      string_key = Atom.to_string(key)

      cond do
        Map.has_key?(metadata, string_key) -> Map.put(safe, key, Map.fetch!(metadata, string_key))
        Map.has_key?(metadata, key) -> Map.put(safe, key, Map.fetch!(metadata, key))
        true -> safe
      end
    end)
  end

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
      [loaded] = do_load_issue_metadata([issue], repository)
      loaded
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
