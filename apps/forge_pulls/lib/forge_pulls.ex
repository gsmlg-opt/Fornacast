defmodule ForgePulls do
  @moduledoc "Repository-scoped pull-request lifecycle operations."

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeIssues.Issue
  alias ForgePulls.PullRequest
  alias Fornacast.{Audit, Page, Repo}

  @type error_reason ::
          :not_found
          | :forbidden
          | :invalid_head
          | :invalid_base
          | :cross_repository_head
          | :head_equals_base
          | {:validation, [map()]}
          | {:unavailable, atom()}

  @spec list_pull_requests(ForgeRepos.Repository.t(), map() | nil, keyword() | map()) ::
          {:ok, Page.t(PullRequest.t())} | {:error, error_reason()}
  def list_pull_requests(%ForgeRepos.Repository{} = repository, actor, filters \\ %{}) do
    with :ok <- authorize_read(actor, repository),
         {:ok, filters} <- list_filters(filters) do
      query =
        from(pull in PullRequest,
          join: issue in Issue,
          on: issue.id == pull.issue_id,
          where: pull.repository_id == ^repository.id,
          where: ^state_filter(filters.state),
          where: ^ref_filter(:head_ref, filters.head),
          where: ^ref_filter(:base_ref, filters.base)
        )
        |> apply_order(filters.sort, filters.direction)

      total = Repo.aggregate(query, :count, :id)
      pulls = query |> limit(^filters.per_page) |> offset(^filters.offset) |> Repo.all()

      {:ok,
       %Page{
         entries: load_issues(pulls, repository),
         total: total,
         page: filters.page,
         per_page: filters.per_page
       }}
    end
  end

  @spec get_pull_request(ForgeRepos.Repository.t(), pos_integer(), map() | nil) ::
          {:ok, PullRequest.t()} | {:error, error_reason()}
  def get_pull_request(%ForgeRepos.Repository{} = repository, number, actor)
      when is_integer(number) and number > 0 do
    with :ok <- authorize_read(actor, repository),
         %PullRequest{} = pull <- Repo.one(pull_query(repository, number)) do
      {:ok, pull |> refresh_analysis(repository) |> load_issue(repository)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def get_pull_request(_repository, _number, _actor), do: {:error, :not_found}

  @spec create_pull_request(ForgeRepos.Repository.t(), map(), map(), map()) ::
          {:ok, PullRequest.t()} | {:error, error_reason()}
  def create_pull_request(%ForgeRepos.Repository{} = repository, actor, attrs, request_metadata)
      when is_map(attrs) and is_map(request_metadata) do
    with %ForgeAccounts.User{} = actor <- actor,
         :ok <- authorize_read(actor, repository),
         {:ok, refs} <- resolve_creation_refs(repository, attrs) do
      Multi.new()
      |> Multi.run(:authorization, fn repo, _ ->
        authorize_create(repo, actor.id, repository.id)
      end)
      |> Multi.merge(fn %{authorization: %{actor: current_actor, repository: current_repository}} ->
        Multi.new()
        |> ForgeIssues.insert_numbered_identity(
          :issue,
          current_repository,
          current_actor,
          :pull_request,
          issue_attrs(attrs)
        )
        |> Multi.insert(:pull_request, fn %{issue: issue} ->
          PullRequest.create_changeset(
            %PullRequest{},
            Map.merge(refs, %{issue_id: issue.id, repository_id: current_repository.id})
          )
        end)
        |> Audit.record_multi(
          :audit,
          current_actor,
          "pull_request.created",
          "repository",
          current_repository.id,
          %{"repository_id" => current_repository.id, "result" => "success"},
          request_metadata: request_metadata
        )
      end)
      |> ForgeIssues.transaction()
      |> create_result()
    else
      nil -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  def create_pull_request(_repository, _actor, _attrs, _request_metadata),
    do: {:error, :forbidden}

  @spec update_pull_request(ForgeRepos.Repository.t(), PullRequest.t(), map(), map(), map()) ::
          {:ok, PullRequest.t()} | {:error, error_reason()}
  def update_pull_request(
        %ForgeRepos.Repository{} = repository,
        %PullRequest{} = pull,
        actor,
        attrs,
        request_metadata
      )
      when is_map(attrs) and is_map(request_metadata) do
    with %ForgeAccounts.User{} = actor <- actor,
         :ok <- authorize_read(actor, repository),
         :ok <- immutable_head(attrs),
         {:ok, pull_attrs} <- resolve_updated_base(repository, pull, attrs) do
      Multi.new()
      |> Multi.run(:authorization, fn repo, _ ->
        authorize_update(repo, actor.id, repository.id, pull.id)
      end)
      |> Multi.merge(fn %{authorization: context} ->
        %{
          actor: current_actor,
          repository: current_repository,
          issue: issue,
          pull: current_pull,
          capability: capability
        } = context

        shared_attrs = permitted_shared_attrs(attrs, capability, issue)

        Multi.new()
        |> ForgeIssues.update_identity(:issue, issue, current_actor, shared_attrs)
        |> Multi.update(:pull_request, PullRequest.update_changeset(current_pull, pull_attrs))
        |> Audit.record_multi(
          :audit,
          current_actor,
          "pull_request.updated",
          "repository",
          current_repository.id,
          %{"repository_id" => current_repository.id, "result" => "success"},
          request_metadata: request_metadata
        )
      end)
      |> ForgeIssues.transaction()
      |> update_result()
    else
      nil -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  @spec pull_links_for_issue_ids(ForgeRepos.Repository.t(), [pos_integer()], map() | nil) ::
          {:ok, %{optional(pos_integer()) => %{merged_at: DateTime.t() | nil}}}
          | {:error, error_reason()}
  def pull_links_for_issue_ids(%ForgeRepos.Repository{} = repository, ids, actor)
      when is_list(ids) do
    with :ok <- authorize_read(actor, repository) do
      links =
        from(pull in PullRequest,
          where: pull.repository_id == ^repository.id and pull.issue_id in ^ids,
          select: {pull.issue_id, pull.merged_at}
        )
        |> Repo.all()
        |> Map.new(fn {issue_id, merged_at} -> {issue_id, %{merged_at: merged_at}} end)

      {:ok, links}
    end
  end

  def pull_links_for_issue_ids(_repository, _ids, _actor), do: {:error, :not_found}

  defp resolve_creation_refs(repository, attrs) do
    with {:ok, head_ref} <- head_ref(repository, attr(attrs, "head")),
         {:ok, base_ref} <- branch_ref(attr(attrs, "base"), :invalid_base),
         :ok <- distinct_refs(head_ref, base_ref),
         {:ok, head} <- resolve_ref(repository, head_ref, :invalid_head),
         {:ok, base} <- resolve_ref(repository, base_ref, :invalid_base) do
      {:ok, %{head_ref: head.ref, base_ref: base.ref, head_sha: head.oid, base_sha: base.oid}}
    end
  end

  defp resolve_updated_base(repository, pull, attrs) do
    with {:ok, base_ref} <-
           if(attr(attrs, "base"),
             do: branch_ref(attr(attrs, "base"), :invalid_base),
             else: {:ok, pull.base_ref}
           ),
         :ok <- distinct_refs(pull.head_ref, base_ref),
         {:ok, head} <- resolve_ref(repository, pull.head_ref, :invalid_head),
         {:ok, base} <- resolve_ref(repository, base_ref, :invalid_base) do
      {:ok,
       %{
         base_ref: base.ref,
         head_sha: head.oid,
         base_sha: base.oid,
         mergeable: nil,
         mergeable_state: nil
       }}
    end
  end

  defp head_ref(repository, value) when is_binary(value) do
    case String.split(String.trim(value), ":", parts: 2) do
      [branch] ->
        branch_ref(branch, :invalid_head)

      [owner, branch] ->
        case ForgeAccounts.get_public_user(String.trim(owner)) do
          {:ok, %{id: owner_id}} when owner_id == repository.owner_user_id ->
            branch_ref(branch, :invalid_head)

          _ ->
            {:error, :cross_repository_head}
        end
    end
  end

  defp head_ref(_repository, _value), do: {:error, :invalid_head}

  defp branch_ref(value, error) when is_binary(value) do
    branch = String.trim(value)

    if branch != "" and not String.contains?(branch, [":", <<0>>]) and
         not String.starts_with?(branch, "refs/"),
       do: {:ok, "refs/heads/" <> branch},
       else: {:error, error}
  end

  defp branch_ref(_value, error), do: {:error, error}

  defp resolve_ref(repository, ref, error) do
    case GitCore.resolve_snapshot(
           ForgeRepos.absolute_storage_path(repository),
           %GitCore.RefSelector{kind: :branch, full_name: ref}
         ) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _} -> {:error, error}
    end
  end

  defp distinct_refs(head, base), do: if(head == base, do: {:error, :head_equals_base}, else: :ok)

  defp immutable_head(attrs),
    do: if(attr(attrs, "head") || attr(attrs, "head_ref"), do: {:error, :invalid_head}, else: :ok)

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp issue_attrs(attrs),
    do:
      attrs
      |> Map.take(["title", "body", :title, :body])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

  defp authorize_read(actor, repository),
    do:
      if(Fornacast.Access.allowed?(actor, :repository_read, repository),
        do: :ok,
        else: {:error, :not_found}
      )

  defp authorize_create(repo, actor_id, repository_id) do
    with {:ok, actor} <- current_actor(repo, actor_id),
         {:ok, repository} <- current_repository(repo, repository_id),
         :ok <- authorize_read(actor, repository) do
      {:ok, %{actor: actor, repository: repository}}
    end
  end

  defp authorize_update(repo, actor_id, repository_id, pull_id) do
    with {:ok, actor} <- current_actor(repo, actor_id),
         {:ok, repository} <- current_repository(repo, repository_id),
         :ok <- authorize_read(actor, repository),
         %PullRequest{} = pull <-
           repo.one(
             from(p in PullRequest, where: p.id == ^pull_id and p.repository_id == ^repository_id)
           ),
         %Issue{} = issue <-
           repo.one(
             from(i in Issue,
               where:
                 i.id == ^pull.issue_id and i.repository_id == ^repository_id and
                   i.kind == :pull_request
             )
           ),
         {:ok, capability} <- mutation_capability(actor, repository, issue) do
      {:ok,
       %{actor: actor, repository: repository, issue: issue, pull: pull, capability: capability}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp current_actor(repo, id) do
    case repo.get_by(ForgeAccounts.User, id: id, kind: :user, state: :active) do
      %ForgeAccounts.User{} = actor -> {:ok, actor}
      _ -> {:error, :forbidden}
    end
  end

  defp current_repository(repo, id) do
    case repo.get(ForgeRepos.Repository, id) do
      %ForgeRepos.Repository{deleted_at: nil} = repository -> {:ok, repository}
      _ -> {:error, :not_found}
    end
  end

  defp mutation_capability(actor, repository, issue) do
    cond do
      Fornacast.Access.allowed?(actor, :repository_write, repository) ->
        {:ok, :writer}

      actor.id == issue.author_user_id and
          Fornacast.Access.allowed?(actor, :repository_read, repository) ->
        {:ok, :author}

      true ->
        {:error, :forbidden}
    end
  end

  defp permitted_shared_attrs(attrs, :writer, _issue),
    do:
      shared_issue_attrs(
        Map.take(attrs, [
          "title",
          "body",
          "state",
          "state_reason",
          :title,
          :body,
          :state,
          :state_reason
        ])
      )

  defp permitted_shared_attrs(attrs, :author, issue) do
    attrs = shared_issue_attrs(Map.take(attrs, ["title", "body", "state", :title, :body, :state]))

    case {issue.state, attr(attrs, "state")} do
      {state, :closed} when state != :closed -> Map.put(attrs, "state_reason", :completed)
      {state, :open} when state != :open -> Map.put(attrs, "state_reason", :reopened)
      _ -> attrs
    end
  end

  defp shared_issue_attrs(attrs),
    do:
      attrs
      |> Map.take([
        "title",
        "body",
        "state",
        "state_reason",
        :title,
        :body,
        :state,
        :state_reason
      ])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

  defp pull_query(repository, number),
    do:
      from(p in PullRequest,
        join: i in Issue,
        on: i.id == p.issue_id,
        where:
          p.repository_id == ^repository.id and i.number == ^number and i.kind == :pull_request,
        select: p
      )

  defp load_issues(pulls, repository) do
    issues_by_id =
      pulls
      |> Enum.map(& &1.issue_id)
      |> ForgeIssues.load_issue_metadata_by_ids(repository)
      |> Map.new(&{&1.id, &1})

    Enum.map(pulls, &%{&1 | issue: Map.fetch!(issues_by_id, &1.issue_id)})
  end

  defp load_issue(pull, repository), do: load_issues([pull], repository) |> hd()

  defp refresh_analysis(pull, repository) do
    with {:ok, head} <- resolve_ref(repository, pull.head_ref, :invalid_head),
         {:ok, base} <- resolve_ref(repository, pull.base_ref, :invalid_base),
         {:ok, refreshed} <-
           pull
           |> PullRequest.update_changeset(%{
             head_sha: head.oid,
             base_sha: base.oid,
             mergeable: nil,
             mergeable_state: nil
           })
           |> Repo.update() do
      refreshed
    else
      _ -> pull
    end
  end

  defp create_result({:ok, %{pull_request: pull}}),
    do: {:ok, load_issue(pull, Repo.get!(ForgeRepos.Repository, pull.repository_id))}

  defp create_result({:error, :authorization, reason, _}), do: {:error, reason}

  defp create_result({:error, _step, %Ecto.Changeset{} = changeset, _}),
    do: {:error, {:validation, changeset_errors(changeset)}}

  defp create_result({:error, _step, {:unavailable, _} = error, _}), do: {:error, error}

  defp create_result({:error, _step, _reason, _}),
    do: {:error, {:validation, [%{resource: "PullRequest", field: "base", code: :unprocessable}]}}

  defp update_result({:ok, %{pull_request: pull}}),
    do: {:ok, load_issue(pull, Repo.get!(ForgeRepos.Repository, pull.repository_id))}

  defp update_result({:error, :authorization, reason, _}), do: {:error, reason}

  defp update_result({:error, _step, %Ecto.Changeset{} = changeset, _}),
    do: {:error, {:validation, changeset_errors(changeset)}}

  defp update_result({:error, _step, _reason, _}),
    do: {:error, {:validation, [%{resource: "PullRequest", field: "base", code: :unprocessable}]}}

  defp changeset_errors(changeset),
    do:
      Enum.map(changeset.errors, fn {field, _} ->
        %{resource: "PullRequest", field: Atom.to_string(field), code: :invalid}
      end)

  defp list_filters(filters) when is_list(filters), do: list_filters(Map.new(filters))

  defp list_filters(filters) when is_map(filters) do
    state = attr(filters, "state") || :open
    sort = attr(filters, "sort") || :created
    direction = attr(filters, "direction") || :desc
    page = parse_positive(attr(filters, "page"), 1)
    per_page = min(parse_positive(attr(filters, "per_page") || attr(filters, "per"), 30), 100)

    if state in [:open, :closed, "open", "closed"] and
         sort in [:created, :updated, :number, "created", "updated", "number"] and
         direction in [:asc, :desc, "asc", "desc"],
       do:
         {:ok,
          %{
            state: state,
            sort: sort,
            direction: direction,
            page: page,
            per_page: per_page,
            offset: (page - 1) * per_page,
            head: attr(filters, "head"),
            base: attr(filters, "base")
          }},
       else:
         {:error, {:validation, [%{resource: "PullRequest", field: "filter", code: :invalid}]}}
  end

  defp list_filters(_),
    do: {:error, {:validation, [%{resource: "PullRequest", field: "filter", code: :invalid}]}}

  defp parse_positive(nil, default), do: default
  defp parse_positive(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
  end

  defp parse_positive(_, default), do: default

  defp state_filter(state),
    do: dynamic([_pull, issue], issue.state == ^String.to_existing_atom(to_string(state)))

  defp ref_filter(_field, nil), do: dynamic(true)
  defp ref_filter(field, value), do: dynamic([pull, _issue], field(pull, ^field) == ^value)

  defp apply_order(query, sort, direction) do
    direction = if to_string(direction) == "asc", do: :asc, else: :desc

    case to_string(sort) do
      "number" ->
        order_by(query, [pull, issue], [{^direction, issue.number}, {^direction, pull.id}])

      "updated" ->
        order_by(query, [pull], [{^direction, pull.updated_at}, {^direction, pull.id}])

      _ ->
        order_by(query, [pull], [{^direction, pull.inserted_at}, {^direction, pull.id}])
    end
  end
end
