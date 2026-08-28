defmodule ForgePulls.Mutations do
  @moduledoc false

  alias Ecto.Multi
  alias ForgePulls.PullRequest
  alias Fornacast.Audit

  def create_multi(actor, repository, attrs, refs, request_metadata) do
    request_metadata = safe_request_metadata(request_metadata)

    Multi.new()
    |> ForgeIssues.insert_numbered_identity(
      :issue,
      repository,
      actor,
      :pull_request,
      issue_attrs(attrs)
    )
    |> Multi.insert(:pull_request, fn %{issue: issue} ->
      %PullRequest{}
      |> PullRequest.create_changeset(
        Map.merge(refs, %{issue_id: issue.id, repository_id: repository.id})
      )
      |> Ecto.Changeset.put_change(:mergeable, nil)
      |> Ecto.Changeset.put_change(:mergeable_state, :unknown)
    end)
    |> Audit.record_multi(
      :audit,
      actor,
      "pull_request.created",
      "repository",
      repository.id,
      %{"repository_id" => repository.id, "result" => "success"},
      request_metadata: request_metadata
    )
  end

  defp issue_attrs(attrs),
    do:
      attrs
      |> Map.take(["title", "body", :title, :body])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

  @doc false
  def safe_request_metadata(metadata) when is_map(metadata) do
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
end

defmodule ForgePulls.SnapshotRefresh do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgePulls.PullRequest
  alias Fornacast.Repo

  def persist(%PullRequest{} = expected, attrs) when is_map(attrs) do
    Multi.new()
    |> Multi.run(:pull_request, fn repo, _changes ->
      persist_in_transaction(repo, expected, attrs)
    end)
    |> ForgeIssues.transaction()
    |> case do
      {:ok, %{pull_request: pull}} -> {:ok, pull}
      {:error, :pull_request, reason, _changes} -> {:error, reason}
    end
  end

  def persist_in_transaction(repo, %PullRequest{} = expected, attrs) when is_map(attrs) do
    target_head_ref = Map.fetch!(attrs, :head_ref)
    target_base_ref = Map.fetch!(attrs, :base_ref)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(pull in PullRequest,
        where:
          pull.id == ^expected.id and pull.repository_id == ^expected.repository_id and
            pull.head_ref == ^expected.head_ref and pull.base_ref == ^expected.base_ref and
            pull.head_sha == ^expected.head_sha and pull.base_sha == ^expected.base_sha
      )

    updates = [
      head_ref: target_head_ref,
      base_ref: target_base_ref,
      head_sha: Map.fetch!(attrs, :head_sha),
      base_sha: Map.fetch!(attrs, :base_sha),
      mergeable: nil,
      mergeable_state: :unknown,
      updated_at: now
    ]

    case repo.update_all(query, set: updates) do
      {1, _rows} ->
        {:ok,
         repo.one!(
           from(pull in PullRequest,
             where:
               pull.id == ^expected.id and pull.repository_id == ^expected.repository_id and
                 pull.head_ref == ^target_head_ref and pull.base_ref == ^target_base_ref and
                 pull.head_sha == ^Map.fetch!(attrs, :head_sha) and
                 pull.base_sha == ^Map.fetch!(attrs, :base_sha)
           )
         )}

      {0, _rows} ->
        {:error, :ref_conflict}
    end
  end
end

defmodule ForgePulls do
  @moduledoc "Repository-scoped pull-request lifecycle operations."

  import Ecto.Query

  alias ForgeIssues.{Comment, Issue}
  alias ForgePulls.{MergeOperation, MergeRecovery, PullRequest}
  alias Fornacast.{Audit, Page, Repo}

  @oid_regex ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @pull_list_analysis_deadline_ms 5_000

  if Mix.env() == :test do
    @read_phase_hook_key {__MODULE__, :read_phase_hook}

    @doc false
    def with_test_read_phase_hook(hook, fun)
        when is_function(hook, 0) and is_function(fun, 0) do
      previous = Process.get(@read_phase_hook_key)
      Process.put(@read_phase_hook_key, hook)

      try do
        fun.()
      after
        if previous,
          do: Process.put(@read_phase_hook_key, previous),
          else: Process.delete(@read_phase_hook_key)
      end
    end

    defp run_read_phase_hook do
      Process.get(@read_phase_hook_key, fn -> :ok end).()
      :ok
    end
  else
    defp run_read_phase_hook, do: :ok
  end

  @type error_reason ::
          :not_found
          | :forbidden
          | :invalid_head
          | :invalid_base
          | :cross_repository_head
          | :head_equals_base
          | :head_changed
          | :conflict
          | :merge_commits_disabled
          | :ref_conflict
          | {:validation, [validation_error()]}
          | {:unavailable, atom()}

  @type validation_error :: %{
          required(:resource) => String.t(),
          required(:field) => String.t(),
          required(:code) =>
            :missing | :missing_field | :invalid | :already_exists | :unprocessable | :custom,
          optional(:message) => String.t()
        }

  @spec branch_options(ForgeRepos.Repository.t(), map() | nil) ::
          {:ok, [struct()]} | {:error, error_reason()}
  def branch_options(%ForgeRepos.Repository{} = repository, actor) do
    with {:ok, repository} <- canonical_read_repository(repository, actor),
         {:ok, branches} <-
           with_read_path(repository, fn path -> branch_option_pages(path, 1, []) end) do
      {:ok, branches}
    else
      {:error, %GitCore.Error{kind: kind}} -> {:error, {:unavailable, kind}}
      {:error, _} = error -> error
    end
  end

  def branch_options(_repository, _actor), do: {:error, :not_found}

  defp branch_option_pages(path, page_number, accumulated) do
    with {:ok, page} <- GitCore.ref_page(path, :branch, page_number, per_page: 100) do
      accumulated = Enum.reverse(page.refs, accumulated)

      if page_number < page.total_pages do
        branch_option_pages(path, page_number + 1, accumulated)
      else
        {:ok, Enum.reverse(accumulated)}
      end
    end
  end

  @spec compare(ForgeRepos.Repository.t(), map() | nil, String.t(), String.t(), keyword()) ::
          {:ok, ForgePulls.Comparison.t()} | {:error, error_reason()}
  def compare(repository, actor, head, base, opts \\ [])

  def compare(%ForgeRepos.Repository{} = repository, actor, head, base, opts)
      when is_binary(head) and is_binary(base) and is_list(opts) do
    result =
      with {:ok, repository} <- canonical_read_repository(repository, actor) do
        with_read_path(repository, fn path ->
          with {:ok, head_ref} <- head_ref(repository, head),
               {:ok, base_ref} <- branch_ref(base, :invalid_base),
               :ok <- distinct_refs(head_ref, base_ref),
               {:ok, head_snapshot} <- resolve_ref_path(path, head_ref, :invalid_head),
               {:ok, base_snapshot} <- resolve_ref_path(path, base_ref, :invalid_base),
               {:ok, analysis} <- pull_analysis_path(path, base_snapshot, head_snapshot, opts) do
            {:ok,
             %ForgePulls.Comparison{
               head_ref: head_snapshot.ref,
               base_ref: base_snapshot.ref,
               head_oid: head_snapshot.oid,
               base_oid: base_snapshot.oid,
               analysis: analysis
             }}
          end
        end)
      end

    normalize_public_read_result(result)
  end

  def compare(_repository, _actor, _head, _base, _opts), do: {:error, :not_found}

  @spec list_commits(ForgeRepos.Repository.t(), PullRequest.t(), map() | nil, keyword()) ::
          {:ok, Page.t(struct())} | {:error, error_reason()}
  def list_commits(repository, pull, actor, opts \\ [])

  def list_commits(
        %ForgeRepos.Repository{} = repository,
        %PullRequest{} = pull,
        actor,
        opts
      )
      when is_list(opts) do
    page = positive_option(opts, :page, 1)
    per_page = positive_option(opts, :per_page, 50)

    result =
      with {:ok, repository} <- canonical_read_repository(repository, actor) do
        with_read_path(repository, fn path ->
          with {:ok, head, base} <- resolve_pull_pair_path(repository, pull, path),
               {:ok, commit_page} <-
                 GitCore.commit_range_page(path, base.oid, head.oid, page, per_page: per_page) do
            {:ok,
             %Page{
               entries: commit_page.commits,
               total: commit_page.total,
               page: commit_page.page,
               per_page: commit_page.per_page
             }}
          end
        end)
      end

    normalize_public_read_result(result)
  end

  def list_commits(_repository, _pull, _actor, _opts), do: {:error, :not_found}

  @spec changed_files(ForgeRepos.Repository.t(), PullRequest.t(), map() | nil, keyword()) ::
          {:ok, ForgePulls.ChangedFilePage.t()} | {:error, error_reason()}
  def changed_files(repository, pull, actor, opts \\ [])

  def changed_files(
        %ForgeRepos.Repository{} = repository,
        %PullRequest{} = pull,
        actor,
        opts
      )
      when is_list(opts) do
    page = positive_option(opts, :page, 1)
    per_page = opts |> positive_option(:per_page, 100) |> min(100)

    result =
      with {:ok, repository} <- canonical_read_repository(repository, actor) do
        with_read_path(repository, fn path ->
          with {:ok, head, base} <- resolve_pull_pair_path(repository, pull, path),
               {:ok, diff} <-
                 GitCore.diff_between(path, base.oid, head.oid,
                   page: page,
                   per_page: per_page
                 ) do
            {:ok,
             %ForgePulls.ChangedFilePage{
               entries: diff.files,
               total: diff.changed_files,
               additions: diff.additions,
               deletions: diff.deletions,
               page: page,
               per_page: per_page,
               truncated: diff.truncated
             }}
          end
        end)
      end

    normalize_public_read_result(result)
  end

  def changed_files(_repository, _pull, _actor, _opts), do: {:error, :not_found}

  @spec list_pull_requests(ForgeRepos.Repository.t(), map() | nil, keyword()) ::
          {:ok, Page.t(PullRequest.t())} | {:error, error_reason()}
  def list_pull_requests(repository, actor, filters \\ [])

  def list_pull_requests(%ForgeRepos.Repository{} = repository, actor, filters)
      when is_list(filters) do
    with {:ok, repository} <- canonical_read_repository(repository, actor),
         {:ok, filters} <- list_filters(filters),
         {:ok, filters} <- normalize_list_refs(repository, filters) do
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

      with {:ok, entries} <- load_issues(pulls, repository, actor) do
        {:ok,
         %Page{
           entries: entries,
           total: total,
           page: filters.page,
           per_page: filters.per_page
         }}
      end
    end
  end

  def list_pull_requests(_repository, _actor, _filters), do: invalid_filter()

  @spec get_pull_request(ForgeRepos.Repository.t(), pos_integer(), map() | nil) ::
          {:ok, PullRequest.t()} | {:error, error_reason()}
  def get_pull_request(%ForgeRepos.Repository{} = repository, number, actor)
      when is_integer(number) and number > 0 do
    with {:ok, repository} <- canonical_read_repository(repository, actor),
         %PullRequest{} = pull <- Repo.one(pull_query(repository, number)),
         {:ok, pull} <- reconcile_pull_on_touch(repository, pull),
         {:ok, pull} <- refresh_analysis(pull, repository),
         {:ok, loaded} <- load_issue_result(pull, repository, actor) do
      {:ok, loaded}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def get_pull_request(_repository, _number, _actor), do: {:error, :not_found}

  @spec merged?(ForgeRepos.Repository.t(), PullRequest.t(), map() | nil) ::
          {:ok, boolean()} | {:error, error_reason()}
  def merged?(
        %ForgeRepos.Repository{} = repository,
        %PullRequest{} = expected_pull,
        actor
      ) do
    with {:ok, repository} <- canonical_read_repository(repository, actor),
         %PullRequest{} = pull <-
           Repo.one(
             from candidate in PullRequest,
               join: issue in Issue,
               on: issue.id == candidate.issue_id,
               where:
                 candidate.id == ^expected_pull.id and
                   candidate.repository_id == ^repository.id and
                   issue.kind == :pull_request
           ),
         {:ok, pull} <- reconcile_pull_on_touch(repository, pull) do
      {:ok, not is_nil(pull.merged_at) and not is_nil(pull.merge_commit_sha)}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def merged?(_repository, _pull, _actor), do: {:error, :not_found}

  @spec create_pull_request(ForgeRepos.Repository.t(), map(), map(), map()) ::
          {:ok, PullRequest.t()} | {:error, error_reason()}
  def create_pull_request(%ForgeRepos.Repository{} = repository, actor, attrs, request_metadata)
      when is_map(attrs) and is_map(request_metadata) do
    with %ForgeAccounts.User{} = actor <- actor,
         {:ok, repository} <- canonical_read_repository(repository, actor),
         {:ok, refs} <- resolve_creation_refs(repository, attrs) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:authorization, fn repo, _ ->
        authorize_create(repo, actor.id, repository.id)
      end)
      |> Ecto.Multi.merge(fn %{
                               authorization: %{
                                 actor: current_actor,
                                 repository: current_repository
                               }
                             } ->
        ForgePulls.Mutations.create_multi(
          current_actor,
          current_repository,
          attrs,
          refs,
          request_metadata
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
         {:ok, preflight} <- authorize_update_preflight(actor, repository, pull),
         :ok <- unchanged_snapshot(preflight.pull, pull),
         :ok <- immutable_source(attrs),
         {:ok, attrs} <- normalize_update_attrs(attrs) do
      ForgeRepos.with_write_fence(preflight.repository, :merge, fn _repository_path, _remaining ->
        execute_update(preflight.repository, pull, actor, attrs, request_metadata)
      end)
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
    with {:ok, repository} <- canonical_read_repository(repository, actor) do
      links = pull_links(repository.id, ids)

      {:ok, links}
    end
  end

  def pull_links_for_issue_ids(_repository, _ids, _actor), do: {:error, :not_found}

  @spec reconcile_repository(ForgeRepos.Repository.t(), keyword()) ::
          :ok | {:error, {:unavailable, :pull_recovery}}
  def reconcile_repository(repository, opts \\ [])

  def reconcile_repository(%ForgeRepos.Repository{} = repository, opts) when is_list(opts) do
    case ForgeRepos.with_write_fence(repository, :merge, fn _repository_path, _remaining ->
           :ok
         end) do
      :ok -> :ok
      _error -> {:error, {:unavailable, :pull_recovery}}
    end
  end

  def reconcile_repository(_repository, _opts),
    do: {:error, {:unavailable, :pull_recovery}}

  @spec merge(ForgeRepos.Repository.t(), PullRequest.t(), map(), map(), map()) ::
          {:ok, %{merged: true, message: String.t(), sha: String.t()}}
          | {:error, error_reason()}
  def merge(
        %ForgeRepos.Repository{} = repository,
        %PullRequest{} = expected_pull,
        actor,
        attrs,
        request_metadata
      )
      when is_map(attrs) and is_map(request_metadata) do
    with %ForgeAccounts.User{} = actor <- actor,
         {:ok, context} <- authorize_merge(actor, repository, expected_pull),
         :ok <- reconcile_before_merge(context.repository),
         {:ok, merge_attrs} <- normalize_merge_attrs(attrs),
         result <-
           ForgeRepos.with_write_fence(context.repository, :merge, fn repository_path,
                                                                      remaining ->
             absolute_deadline = System.monotonic_time(:millisecond) + remaining

             execute_merge(
               context,
               merge_attrs,
               request_metadata,
               repository_path,
               absolute_deadline
             )
           end) do
      result
    else
      nil -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  def merge(_repository, _pull, _actor, _attrs, _request_metadata), do: {:error, :forbidden}

  if Mix.env() == :test do
    @merge_transition_hook_key {__MODULE__, :merge_transition_hook}

    @doc false
    def with_test_merge_transition_hook(hook, fun)
        when is_function(hook, 2) and is_function(fun, 0) do
      previous = Process.get(@merge_transition_hook_key)
      Process.put(@merge_transition_hook_key, hook)

      try do
        fun.()
      after
        if previous == nil,
          do: Process.delete(@merge_transition_hook_key),
          else: Process.put(@merge_transition_hook_key, previous)
      end
    end

    defp notify_merge_transition(state, operation) do
      case Process.get(@merge_transition_hook_key) do
        hook when is_function(hook, 2) -> hook.(state, operation)
        nil -> :ok
      end
    end
  else
    defp notify_merge_transition(_state, _operation), do: :ok
  end

  defp pull_links(_repository_id, []), do: %{}

  defp pull_links(repository_id, ids) do
    from(pull in PullRequest,
      where: pull.repository_id == ^repository_id and pull.issue_id in ^Enum.uniq(ids),
      select: {pull.issue_id, pull.merged_at}
    )
    |> Repo.all()
    |> Map.new(fn {issue_id, merged_at} -> {issue_id, %{merged_at: merged_at}} end)
  end

  defp execute_merge(context, attrs, request_metadata, repository_path, absolute_deadline) do
    with {:ok, context} <-
           authorize_merge(context.actor, context.repository, context.pull),
         :ok <- merge_allowed(context),
         {:ok, head_oid} <- exact_ref(repository_path, context.pull.head_ref, absolute_deadline),
         {:ok, base_oid} <- exact_ref(repository_path, context.pull.base_ref, absolute_deadline),
         :ok <- expected_head(attrs.sha, head_oid),
         {:ok, analysis} <-
           merge_analysis(repository_path, base_oid, head_oid, absolute_deadline),
         :ok <- mergeable(analysis),
         {:ok, operation} <-
           prepare_merge_operation(context, attrs, request_metadata, base_oid, head_oid),
         :ok <- notify_merge_transition(:prepared, operation),
         {:ok, merge_oid} <-
           write_merge_commit(
             repository_path,
             base_oid,
             head_oid,
             context,
             attrs,
             absolute_deadline
           ),
         {:ok, operation} <- persist_merge_written(operation, merge_oid),
         :ok <- notify_merge_transition(:merge_written, operation),
         {:ok, ^merge_oid} <-
           compare_and_swap(
             repository_path,
             context.pull.base_ref,
             base_oid,
             merge_oid,
             absolute_deadline
           ),
         {:ok, operation} <- persist_ref_advanced(operation),
         :ok <- notify_merge_transition(:ref_advanced, operation),
         :ok <-
           MergeRecovery.reconcile_repository_locked(
             context.repository,
             repository_path,
             absolute_deadline
           ),
         %MergeOperation{state: :completed} = operation <- Repo.get(MergeOperation, operation.id),
         :ok <- notify_merge_transition(:completed, operation) do
      {:ok, %{merged: true, message: "Pull Request successfully merged", sha: merge_oid}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, {:unavailable, :pull_merge}}
    end
  end

  defp authorize_merge(actor, repository, expected_pull) do
    with {:ok, actor} <- current_actor(Repo, actor.id),
         {:ok, repository} <- canonical_read_repository(repository, actor),
         %PullRequest{} = pull <-
           Repo.one(
             from candidate in PullRequest,
               where:
                 candidate.id == ^expected_pull.id and
                   candidate.repository_id == ^repository.id
           ),
         :ok <- same_pull_refs(pull, expected_pull),
         %Issue{kind: :pull_request} = issue <- current_issue(pull.issue_id, repository),
         true <- Fornacast.Access.allowed?(actor, :repository_write, repository) do
      {:ok, %{actor: actor, repository: repository, pull: pull, issue: issue}}
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp same_pull_refs(
         %PullRequest{head_ref: head_ref, base_ref: base_ref},
         %PullRequest{head_ref: head_ref, base_ref: base_ref}
       ),
       do: :ok

  defp same_pull_refs(_pull, _expected), do: {:error, :ref_conflict}

  defp merge_allowed(%{repository: %{allow_merge_commit: false}}),
    do: {:error, :merge_commits_disabled}

  defp merge_allowed(%{pull: %{merge_commit_sha: merge_oid}}) when is_binary(merge_oid),
    do: {:error, :conflict}

  defp merge_allowed(%{issue: %{state: state}}) when state != :open, do: {:error, :conflict}
  defp merge_allowed(_context), do: :ok

  defp exact_ref(repository_path, ref, absolute_deadline) do
    with {:ok, remaining} <- remaining_ms(absolute_deadline) do
      case GitCore.exact_ref(repository_path, ref, deadline_ms: remaining) do
        {:ok, oid} when is_binary(oid) -> {:ok, oid}
        {:ok, nil} -> {:error, :ref_conflict}
        {:error, %GitCore.Error{kind: kind}} -> {:error, {:unavailable, kind}}
      end
    end
  end

  defp expected_head(nil, _head_oid), do: :ok
  defp expected_head(head_oid, head_oid), do: :ok
  defp expected_head(_expected, _actual), do: {:error, :head_changed}

  defp merge_analysis(repository_path, base_oid, head_oid, absolute_deadline) do
    with {:ok, remaining} <- remaining_ms(absolute_deadline) do
      case GitCore.merge_analysis(repository_path, base_oid, head_oid, deadline_ms: remaining) do
        {:ok, analysis} -> {:ok, analysis}
        {:error, %GitCore.Error{kind: :merge_conflict}} -> {:error, :conflict}
        {:error, %GitCore.Error{kind: kind}} -> {:error, {:unavailable, kind}}
      end
    end
  end

  defp mergeable(%GitCore.MergeAnalysis{mergeable: true}), do: :ok
  defp mergeable(%GitCore.MergeAnalysis{mergeable: false}), do: {:error, :conflict}

  defp prepare_merge_operation(context, _attrs, request_metadata, base_oid, head_oid) do
    safe_metadata = ForgePulls.Mutations.safe_request_metadata(request_metadata)

    case Map.get(safe_metadata, :request_id) do
      request_id when is_binary(request_id) and request_id != "" ->
        operation_metadata =
          Map.take(safe_metadata, [
            :request_id,
            :api_version,
            :ip_address,
            :user_agent,
            :token_id
          ])

        %MergeOperation{}
        |> MergeOperation.prepare_changeset(
          Map.merge(operation_metadata, %{
            pull_request_id: context.pull.id,
            repository_id: context.repository.id,
            actor_user_id: context.actor.id,
            base_ref: context.pull.base_ref,
            head_ref: context.pull.head_ref,
            expected_base_oid: base_oid,
            expected_head_oid: head_oid,
            state: :prepared
          })
        )
        |> Repo.insert()
        |> case do
          {:ok, operation} -> {:ok, operation}
          {:error, _changeset} -> {:error, {:unavailable, :database}}
        end

      _missing ->
        merge_validation("request_id", :missing)
    end
  end

  defp write_merge_commit(
         repository_path,
         base_oid,
         head_oid,
         context,
         attrs,
         absolute_deadline
       ) do
    with {:ok, remaining} <- remaining_ms(absolute_deadline) do
      signature = merge_signature(context.actor)
      message = merge_message(context, attrs)

      case GitCore.write_merge_commit(
             repository_path,
             base_oid,
             head_oid,
             signature,
             signature,
             message,
             deadline_ms: remaining
           ) do
        {:ok, merge_oid} -> {:ok, merge_oid}
        {:error, %GitCore.Error{kind: :merge_conflict}} -> {:error, :conflict}
        {:error, %GitCore.Error{kind: kind}} -> {:error, {:unavailable, kind}}
      end
    end
  end

  defp persist_merge_written(operation, merge_oid) do
    operation
    |> MergeOperation.merge_written_changeset(merge_oid)
    |> Repo.update()
    |> database_result()
  end

  defp persist_ref_advanced(operation) do
    operation
    |> MergeOperation.ref_advanced_changeset()
    |> Repo.update()
    |> database_result()
  end

  defp database_result({:ok, operation}), do: {:ok, operation}
  defp database_result({:error, _changeset}), do: {:error, {:unavailable, :database}}

  defp compare_and_swap(repository_path, base_ref, base_oid, merge_oid, absolute_deadline) do
    with {:ok, remaining} <- remaining_ms(absolute_deadline) do
      case GitCore.compare_and_swap_ref(
             repository_path,
             base_ref,
             base_oid,
             merge_oid,
             :fast_forward,
             deadline_ms: remaining
           ) do
        {:ok, oid} ->
          {:ok, oid}

        {:error, %GitCore.Error{kind: kind}}
        when kind in [:stale_ref, :ref_exists, :non_fast_forward] ->
          {:error, :ref_conflict}

        {:error, %GitCore.Error{kind: kind}} ->
          {:error, {:unavailable, kind}}
      end
    end
  end

  defp merge_signature(actor) do
    %GitCore.Signature{
      name: actor.username,
      email: actor.email,
      seconds: System.system_time(:second),
      offset_minutes: 0
    }
  end

  defp merge_message(context, attrs) do
    title = attrs.commit_title || default_merge_title(context)
    body = attrs.commit_message || context.issue.title
    if body == "", do: title, else: title <> "\n\n" <> body
  end

  defp default_merge_title(context) do
    branch = String.replace_prefix(context.pull.head_ref, "refs/heads/", "")
    "Merge pull request ##{context.issue.number} from #{branch}"
  end

  defp normalize_merge_attrs(attrs) do
    method = attr(attrs, "merge_method") || "merge"
    sha = attr(attrs, "sha")
    title = attr(attrs, "commit_title")
    message = attr(attrs, "commit_message")

    with :ok <- valid_merge_method(method),
         :ok <- valid_optional_oid(sha),
         :ok <- valid_optional_message("commit_title", title, 256, false),
         :ok <- valid_optional_message("commit_message", message, 65_536, true) do
      {:ok,
       %{
         sha: if(is_binary(sha), do: String.downcase(sha), else: nil),
         commit_title: title,
         commit_message: message
       }}
    end
  end

  defp valid_merge_method(method) when method in [:merge, "merge"], do: :ok
  defp valid_merge_method(_method), do: merge_validation("merge_method", :invalid)

  defp valid_optional_oid(nil), do: :ok

  defp valid_optional_oid(oid) when is_binary(oid) do
    if Regex.match?(@oid_regex, String.downcase(oid)),
      do: :ok,
      else: merge_validation("sha", :invalid)
  end

  defp valid_optional_oid(_oid), do: merge_validation("sha", :invalid)

  defp valid_optional_message(_field, nil, _max, _empty?), do: :ok

  defp valid_optional_message(field, value, max, empty?) when is_binary(value) do
    if byte_size(value) <= max and not String.contains?(value, <<0>>) and
         (empty? or String.trim(value) != ""),
       do: :ok,
       else: merge_validation(field, :invalid)
  end

  defp valid_optional_message(field, _value, _max, _empty?),
    do: merge_validation(field, :invalid)

  defp merge_validation(field, code),
    do: {:error, {:validation, [%{resource: "PullRequest", field: field, code: code}]}}

  defp remaining_ms(absolute_deadline) do
    remaining = absolute_deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, remaining}, else: {:error, {:unavailable, :write_timeout}}
  end

  defp resolve_creation_refs(repository, attrs) do
    with_read_path(repository, fn path ->
      with {:ok, head_ref} <- head_ref(repository, attr(attrs, "head")),
           {:ok, base_ref} <- branch_ref(attr(attrs, "base"), :invalid_base),
           :ok <- distinct_refs(head_ref, base_ref),
           {:ok, head} <- resolve_ref_path(path, head_ref, :invalid_head),
           {:ok, base} <- resolve_ref_path(path, base_ref, :invalid_base) do
        {:ok, %{head_ref: head.ref, base_ref: base.ref, head_sha: head.oid, base_sha: base.oid}}
      end
    end)
  end

  defp resolve_updated_base(repository, pull, attrs) do
    with_read_path(repository, fn path ->
      with {:ok, base_ref} <-
             if(attr(attrs, "base"),
               do: branch_ref(attr(attrs, "base"), :invalid_base),
               else: {:ok, pull.base_ref}
             ),
           :ok <- distinct_refs(pull.head_ref, base_ref),
           {:ok, head} <- resolve_ref_path(path, pull.head_ref, :invalid_head),
           {:ok, base} <- resolve_ref_path(path, base_ref, :invalid_base) do
        {:ok,
         %{
           head_ref: head.ref,
           base_ref: base.ref,
           head_sha: head.oid,
           base_sha: base.oid,
           mergeable: nil,
           mergeable_state: :unknown
         }}
      end
    end)
  end

  defp head_ref(repository, value) when is_binary(value) do
    case String.split(String.trim(value), ":", parts: 2) do
      [branch] ->
        branch_ref(branch, :invalid_head)

      [owner, branch] ->
        case public_owner(String.trim(owner)) do
          {:ok, %{id: owner_id}} when owner_id == repository.owner_user_id ->
            branch_ref(branch, :invalid_head)

          _ ->
            {:error, :cross_repository_head}
        end
    end
  end

  defp head_ref(_repository, _value), do: {:error, :invalid_head}

  defp public_owner(owner) do
    case ForgeAccounts.get_public_user(owner) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> ForgeAccounts.get_public_organization(owner)
    end
  end

  defp branch_ref(value, error) when is_binary(value) do
    branch = String.trim(value)

    if branch != "" and not String.contains?(branch, [":", <<0>>]) and
         not String.starts_with?(branch, "refs/"),
       do: {:ok, "refs/heads/" <> branch},
       else: {:error, error}
  end

  defp branch_ref(_value, error), do: {:error, error}

  defp resolve_ref_path(path, ref, error) do
    result = GitCore.resolve_snapshot(path, %GitCore.RefSelector{kind: :branch, full_name: ref})

    case result do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, %GitCore.Error{kind: kind}} when kind in [:ref_not_found, :not_found] ->
        {:error, error}

      {:error, %GitCore.Error{kind: kind}} ->
        {:error, {:unavailable, kind}}
    end
  end

  defp resolve_pull_pair_path(repository, expected_pull, path) do
    with %PullRequest{} = pull <-
           Repo.get_by(PullRequest,
             id: expected_pull.id,
             repository_id: repository.id
           ),
         {:ok, head} <- resolve_ref_path(path, pull.head_ref, :invalid_head),
         {:ok, base} <- resolve_ref_path(path, pull.base_ref, :invalid_base) do
      {:ok, head, base}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp distinct_refs(head, base), do: if(head == base, do: {:error, :head_equals_base}, else: :ok)

  defp immutable_source(attrs) do
    cond do
      attr(attrs, "head") || attr(attrs, "head_ref") ->
        {:error, :invalid_head}

      attr(attrs, "repository") || attr(attrs, "repository_id") ->
        {:error, {:validation, [%{resource: "PullRequest", field: "repository", code: :invalid}]}}

      true ->
        :ok
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp canonical_read_repository(repository, actor) do
    with %ForgeAccounts.User{} = owner <- ForgeAccounts.get_account(repository.owner_user_id),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner.username,
             repository.slug,
             :repository_read
           ) do
      {:ok, repository}
    else
      _ -> {:error, :not_found}
    end
  end

  defp authorize_create(repo, actor_id, repository_id) do
    with {:ok, actor} <- current_actor(repo, actor_id),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository_by_id(actor, repository_id, :repository_read) do
      {:ok, %{actor: actor, repository: repository}}
    end
  end

  defp authorize_update_preflight(actor, repository, expected_pull) do
    with {:ok, actor} <- current_actor(Repo, actor.id),
         {:ok, repository} <- canonical_read_repository(repository, actor),
         %PullRequest{} = pull <-
           Repo.one(
             from(p in PullRequest,
               where: p.id == ^expected_pull.id and p.repository_id == ^repository.id
             )
           ),
         %Issue{kind: :pull_request} = issue <- current_issue(pull.issue_id, repository),
         {:ok, capability} <- mutation_capability(actor, repository, issue) do
      {:ok,
       %{actor: actor, repository: repository, issue: issue, pull: pull, capability: capability}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp authorize_update(repo, actor_id, repository_id, %PullRequest{} = expected_pull) do
    with {:ok, actor} <- current_actor(repo, actor_id),
         {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository_by_id(actor, repository_id, :repository_read),
         %PullRequest{} = pull <-
           repo.one(
             from(p in PullRequest,
               where: p.id == ^expected_pull.id and p.repository_id == ^repository_id
             )
           ),
         :ok <- unchanged_snapshot(pull, expected_pull),
         %Issue{kind: :pull_request} = issue <-
           current_issue(pull.issue_id, repository),
         {:ok, capability} <- mutation_capability(actor, repository, issue) do
      {:ok,
       %{actor: actor, repository: repository, issue: issue, pull: pull, capability: capability}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp execute_update(repository, expected_pull, actor, attrs, request_metadata) do
    with {:ok, context} <- authorize_update_preflight(actor, repository, expected_pull),
         :ok <- unchanged_snapshot(context.pull, expected_pull),
         :ok <- compatible_merged_update(context.pull, attrs),
         {:ok, pull_attrs} <- resolve_updated_base(context.repository, context.pull, attrs) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:authorization, fn repo, _ ->
        authorize_update(repo, context.actor.id, context.repository.id, context.pull)
      end)
      |> Ecto.Multi.merge(fn %{authorization: authorized} ->
        %{
          actor: current_actor,
          repository: current_repository,
          issue: issue,
          pull: current_pull,
          capability: capability
        } = authorized

        shared_attrs = permitted_shared_attrs(attrs, capability, issue)

        Ecto.Multi.new()
        |> ForgeIssues.update_identity(:issue, issue, current_actor, shared_attrs)
        |> Ecto.Multi.run(:pull_request, fn repo, _changes ->
          ForgePulls.SnapshotRefresh.persist_in_transaction(repo, current_pull, pull_attrs)
        end)
        |> Audit.record_multi(
          :audit,
          current_actor,
          "pull_request.updated",
          "repository",
          current_repository.id,
          %{"repository_id" => current_repository.id, "result" => "success"},
          request_metadata: ForgePulls.Mutations.safe_request_metadata(request_metadata)
        )
      end)
      |> ForgeIssues.transaction()
      |> update_result()
    end
  end

  defp compatible_merged_update(%PullRequest{merge_commit_sha: nil}, _attrs), do: :ok

  defp compatible_merged_update(%PullRequest{}, attrs) do
    cond do
      fetch_attr(attrs, "base") != :error -> {:error, :conflict}
      fetch_attr(attrs, "state") in [{:ok, :open}, {:ok, "open"}] -> {:error, :conflict}
      true -> :ok
    end
  end

  defp unchanged_snapshot(
         %PullRequest{
           head_ref: head_ref,
           base_ref: base_ref,
           head_sha: head_sha,
           base_sha: base_sha
         },
         %PullRequest{
           head_ref: head_ref,
           base_ref: base_ref,
           head_sha: head_sha,
           base_sha: base_sha
         }
       ),
       do: :ok

  defp unchanged_snapshot(_current, _expected), do: {:error, :ref_conflict}

  defp current_issue(issue_id, repository) do
    case ForgeIssues.load_issue_metadata_by_ids([issue_id], repository) do
      [issue] -> issue
      [] -> nil
    end
  end

  defp current_actor(repo, id) do
    case repo.get_by(ForgeAccounts.User, id: id, kind: :user, state: :active) do
      %ForgeAccounts.User{} = actor -> {:ok, actor}
      _ -> {:error, :forbidden}
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

  defp permitted_shared_attrs(attrs, capability, issue) when capability in [:author, :writer] do
    attrs = shared_issue_attrs(Map.take(attrs, ["title", "body", "state", :title, :body, :state]))

    case {issue.state, attr(attrs, "state")} do
      {state, :closed} when state != :closed -> Map.put(attrs, "state_reason", :completed)
      {state, :open} when state != :open -> Map.put(attrs, "state_reason", :reopened)
      _ -> attrs
    end
  end

  defp normalize_update_attrs(attrs) do
    attrs = attrs |> Map.delete("state_reason") |> Map.delete(:state_reason)

    case fetch_attr(attrs, "state") do
      :error ->
        {:ok, attrs}

      {:ok, state} when state in [:open, "open"] ->
        {:ok, attrs |> Map.delete(:state) |> Map.put("state", :open)}

      {:ok, state} when state in [:closed, "closed"] ->
        {:ok, attrs |> Map.delete(:state) |> Map.put("state", :closed)}

      {:ok, _state} ->
        {:error, {:validation, [%{resource: "PullRequest", field: "state", code: :invalid}]}}
    end
  end

  defp fetch_attr(attrs, key) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.fetch!(attrs, key)}
      Map.has_key?(attrs, atom_key) -> {:ok, Map.fetch!(attrs, atom_key)}
      true -> :error
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

  defp reconcile_pull_on_touch(repository, pull) do
    pending? =
      Repo.exists?(
        from operation in MergeOperation,
          where:
            operation.pull_request_id == ^pull.id and
              operation.state not in [:completed, :failed]
      )

    if pending? do
      with :ok <- reconcile_repository(repository, []) do
        case Repo.get(PullRequest, pull.id) do
          %PullRequest{} = reconciled -> {:ok, reconciled}
          nil -> {:error, :not_found}
        end
      end
    else
      {:ok, pull}
    end
  end

  defp reconcile_before_merge(repository) do
    pending? =
      Repo.exists?(
        from operation in MergeOperation,
          where:
            operation.repository_id == ^repository.id and
              operation.state not in [:completed, :failed]
      )

    if pending? do
      reconcile_repository(repository, [])
    else
      :ok
    end
  end

  defp load_issues(pulls, repository, actor) do
    absolute_deadline =
      System.monotonic_time(:millisecond) + @pull_list_analysis_deadline_ms

    issues_by_id =
      pulls
      |> Enum.map(& &1.issue_id)
      |> ForgeIssues.load_issue_metadata_by_ids(repository, actor)
      |> Map.new(&{&1.id, &1})

    load_issues_with_analysis(pulls, issues_by_id, repository, absolute_deadline)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      {:error, _} = error -> error
    end
  end

  defp load_issues_with_analysis(pulls, issues_by_id, repository, absolute_deadline) do
    if Enum.any?(pulls, &is_nil(&1.analysis)) do
      with_read_path(repository, fn path ->
        reduce_loaded_issues(pulls, issues_by_id, repository, absolute_deadline, path)
      end)
    else
      reduce_loaded_issues(pulls, issues_by_id, repository, absolute_deadline, nil)
    end
  end

  defp reduce_loaded_issues(pulls, issues_by_id, repository, absolute_deadline, path) do
    Enum.reduce_while(pulls, {:ok, []}, fn pull, {:ok, loaded} ->
      with {:ok, issue} <- Map.fetch(issues_by_id, pull.issue_id),
           {:ok, analyzed} <- ensure_analysis(pull, repository, absolute_deadline, path) do
        pull = attach_issue_and_capabilities(analyzed, issue, repository)
        {:cont, {:ok, [pull | loaded]}}
      else
        :error -> {:halt, {:error, :not_found}}
      end
    end)
  end

  defp load_issue_result(pull, repository, actor) do
    case load_issues([pull], repository, actor) do
      {:ok, [loaded]} -> {:ok, loaded}
      {:ok, []} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp refresh_analysis(pull, repository) do
    with_read_path(repository, fn path ->
      with {:ok, head} <- resolve_ref_path(path, pull.head_ref, :invalid_head),
           {:ok, base} <- resolve_ref_path(path, pull.base_ref, :invalid_base),
           {:ok, analysis} <- pull_analysis_path(path, base, head, []),
           {:ok, refreshed} <-
             ForgePulls.SnapshotRefresh.persist(pull, %{
               head_ref: head.ref,
               base_ref: base.ref,
               head_sha: head.oid,
               base_sha: base.oid,
               mergeable: nil,
               mergeable_state: :unknown
             }) do
        {:ok, %{refreshed | analysis: analysis}}
      end
    end)
    |> case do
      {:error, %GitCore.Error{kind: kind}} -> {:error, {:unavailable, kind}}
      result -> result
    end
  end

  defp ensure_analysis(pull, repository, absolute_deadline, path)

  defp ensure_analysis(
         %PullRequest{analysis: %GitCore.MergeAnalysis{}} = pull,
         _repository,
         _absolute_deadline,
         _path
       ),
       do: {:ok, pull}

  defp ensure_analysis(pull, repository, absolute_deadline, nil) do
    with_read_path(repository, fn path ->
      ensure_analysis(pull, repository, absolute_deadline, path)
    end)
  end

  defp ensure_analysis(pull, _repository, absolute_deadline, path) when is_binary(path) do
    with true <- absolute_deadline > System.monotonic_time(:millisecond),
         {:ok, head} <- resolve_ref_path(path, pull.head_ref, :invalid_head),
         {:ok, base} <- resolve_ref_path(path, pull.base_ref, :invalid_base),
         remaining when remaining > 0 <-
           absolute_deadline - System.monotonic_time(:millisecond),
         {:ok, analysis} <- pull_analysis_path(path, base, head, deadline_ms: remaining) do
      {:ok, %{pull | analysis: analysis}}
    else
      _ -> {:ok, %{pull | analysis: unknown_analysis(pull)}}
    end
  end

  defp unknown_analysis(pull) do
    %GitCore.MergeAnalysis{
      base_oid: pull.base_sha,
      head_oid: pull.head_sha,
      mergeable: false,
      ahead_by: 0,
      behind_by: 0,
      commit_count: 0,
      changed_paths: 0
    }
  end

  defp pull_analysis_path(path, base, head, opts) do
    GitCore.merge_analysis(path, base.oid, head.oid, opts)
    |> normalize_pull_analysis(base, head)
  end

  defp normalize_pull_analysis(result, base, head) do
    case result do
      {:ok, analysis} ->
        {:ok, analysis}

      {:error, %GitCore.Error{kind: :merge_conflict}} ->
        {:ok,
         %GitCore.MergeAnalysis{
           base_oid: base.oid,
           head_oid: head.oid,
           mergeable: false,
           ahead_by: 0,
           behind_by: 0,
           commit_count: 0,
           changed_paths: 0
         }}

      {:error, _} = error ->
        error
    end
  end

  defp with_read_path(repository, fun) do
    deadline = System.monotonic_time(:millisecond) + GitCore.Limits.get(:content_deadline_ms)

    ForgeRepos.with_repository_read(repository, deadline, fn handle ->
      :ok = run_read_phase_hook()
      fun.(ForgeRepos.repository_read_path(handle))
    end)
    |> case do
      {:error, :unavailable} -> {:error, {:unavailable, :read_limiter}}
      {:error, :deadline_exceeded} -> {:error, {:unavailable, :read_timeout}}
      result -> result
    end
  end

  defp normalize_public_read_result({:error, %GitCore.Error{kind: kind}}),
    do: {:error, {:unavailable, kind}}

  defp normalize_public_read_result(result), do: result

  defp attach_issue_and_capabilities(pull, issue, repository) do
    issue_capabilities = issue.capabilities || %{}

    capabilities = %{
      can_edit: Map.get(issue_capabilities, :can_edit, false),
      can_close: Map.get(issue_capabilities, :can_close, false),
      can_comment: Map.get(issue_capabilities, :can_comment, false),
      can_merge:
        repository.allow_merge_commit and
          Map.get(issue_capabilities, :can_manage_relationships, false) and
          issue.state == :open and is_nil(pull.merged_at) and pull.analysis.mergeable
    }

    %{pull | issue: issue, capabilities: capabilities}
  end

  defp create_result(
         {:ok, %{pull_request: pull, authorization: %{repository: repository, actor: actor}}}
       ) do
    with {:ok, pull} <- refresh_analysis(pull, repository) do
      load_issue_result(pull, repository, actor)
    end
  end

  defp create_result({:error, :authorization, reason, _}), do: {:error, reason}

  defp create_result({:error, _step, %Ecto.Changeset{} = changeset, _}),
    do: {:error, {:validation, changeset_errors(changeset)}}

  defp create_result({:error, _step, {:unavailable, _} = error, _}), do: {:error, error}

  defp create_result({:error, _step, _reason, _}),
    do: {:error, {:validation, [%{resource: "PullRequest", field: "base", code: :unprocessable}]}}

  defp update_result(
         {:ok, %{pull_request: pull, authorization: %{repository: repository, actor: actor}}}
       ) do
    with {:ok, pull} <- refresh_analysis(pull, repository) do
      load_issue_result(pull, repository, actor)
    end
  end

  defp update_result({:error, :authorization, reason, _}), do: {:error, reason}

  defp update_result({:error, :pull_request, :ref_conflict, _}), do: {:error, :ref_conflict}

  defp update_result({:error, _step, %Ecto.Changeset{} = changeset, _}),
    do: {:error, {:validation, changeset_errors(changeset)}}

  defp update_result({:error, _step, _reason, _}),
    do: {:error, {:validation, [%{resource: "PullRequest", field: "base", code: :unprocessable}]}}

  defp changeset_errors(changeset),
    do:
      Enum.map(changeset.errors, fn {field, _} ->
        %{resource: "PullRequest", field: Atom.to_string(field), code: :invalid}
      end)

  defp list_filters(filters) when is_list(filters) do
    filters = Map.new(filters)
    page = parse_positive(attr(filters, "page"), 1)
    per_page = min(parse_positive(attr(filters, "per_page") || attr(filters, "per"), 30), 100)

    with {:ok, state} <- normalize_state(attr(filters, "state") || :open),
         {:ok, sort} <- normalize_sort(attr(filters, "sort") || :created),
         {:ok, direction} <-
           normalize_direction(attr(filters, "direction") || default_direction(sort)) do
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
       }}
    end
  end

  defp invalid_filter,
    do: {:error, {:validation, [%{resource: "PullRequest", field: "filter", code: :invalid}]}}

  defp normalize_state(state) when state in [:open, "open"], do: {:ok, :open}
  defp normalize_state(state) when state in [:closed, "closed"], do: {:ok, :closed}
  defp normalize_state(state) when state in [:all, "all"], do: {:ok, :all}
  defp normalize_state(_state), do: invalid_filter_value("state")

  defp normalize_sort(sort) when sort in [:created, "created"], do: {:ok, :created}
  defp normalize_sort(sort) when sort in [:updated, "updated"], do: {:ok, :updated}
  defp normalize_sort(sort) when sort in [:popularity, "popularity"], do: {:ok, :popularity}

  defp normalize_sort(sort) when sort in [:long_running, "long-running"],
    do: {:ok, :long_running}

  defp normalize_sort(_sort), do: invalid_filter_value("sort")

  defp normalize_direction(direction) when direction in [:asc, "asc"], do: {:ok, :asc}
  defp normalize_direction(direction) when direction in [:desc, "desc"], do: {:ok, :desc}
  defp normalize_direction(_direction), do: invalid_filter_value("direction")

  defp invalid_filter_value(field),
    do: {:error, {:validation, [%{resource: "PullRequest", field: field, code: :invalid}]}}

  defp default_direction(:created), do: :desc
  defp default_direction(_sort), do: :asc

  defp parse_positive(nil, default), do: default
  defp parse_positive(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> default
    end
  end

  defp parse_positive(_, default), do: default

  defp normalize_list_refs(repository, filters) do
    with {:ok, head} <- normalize_optional_head(repository, filters.head),
         {:ok, base} <- normalize_optional_base(filters.base) do
      {:ok, %{filters | head: head, base: base}}
    end
  end

  defp normalize_optional_head(_repository, nil), do: {:ok, nil}
  defp normalize_optional_head(repository, value), do: head_ref(repository, value)
  defp normalize_optional_base(nil), do: {:ok, nil}
  defp normalize_optional_base(value), do: branch_ref(value, :invalid_base)

  defp state_filter(:all), do: dynamic(true)
  defp state_filter(state), do: dynamic([_pull, issue], issue.state == ^state)

  defp ref_filter(_field, nil), do: dynamic(true)
  defp ref_filter(field, value), do: dynamic([pull, _issue], field(pull, ^field) == ^value)

  defp apply_order(query, sort, direction) do
    case sort do
      :popularity ->
        counts =
          Comment
          |> group_by([comment], comment.issue_id)
          |> select([comment], %{issue_id: comment.issue_id, count: count(comment.id)})

        query
        |> join(:left, [pull, issue], counts in subquery(counts), on: counts.issue_id == issue.id)
        |> order_by([pull, issue, counts], [
          {^direction, coalesce(counts.count, 0)},
          {^direction, issue.id},
          {^direction, pull.id}
        ])

      :updated ->
        order_by(query, [pull, issue], [
          {^direction, issue.updated_at},
          {^direction, issue.id},
          {^direction, pull.id}
        ])

      sort when sort in [:created, :long_running] ->
        order_by(query, [pull, issue], [
          {^direction, issue.inserted_at},
          {^direction, issue.id},
          {^direction, pull.id}
        ])
    end
  end
end
