defmodule ForgeImports.GitHub.MetadataImporter do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts
  alias ForgeAccounts.GitHubIdentity
  alias ForgeImports.GitHub.{Client, MetadataMapper}
  alias ForgeImports.{ObjectMapping, PageCheckpoint, Persistence, ReportEntry, RepositoryItem}
  alias ForgeIssues
  alias ForgeIssues.{Issue, Label}
  alias ForgePulls
  alias ForgePulls.PullRequest
  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitCore

  @phases [:labels, :issues, :comments, :pull_requests, :number_sequence]
  @terminal_page_key "__terminal_v1__"

  @type credential_checkout :: ((String.t() -> term()) -> term())

  @spec stage(RepositoryItem.t(), credential_checkout(), keyword()) ::
          :ok | {:error, atom()}
  def stage(%RepositoryItem{} = item, credential_checkout, opts \\ [])
      when is_function(credential_checkout, 1) and is_list(opts) do
    opts = Keyword.put(opts, :credential_checkout, credential_checkout)

    Enum.reduce_while(@phases, :ok, fn phase, :ok ->
      case stage_phase(item, phase, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec stage_phase(RepositoryItem.t(), atom(), keyword()) :: :ok | {:error, atom()}
  def stage_phase(%RepositoryItem{} = item, phase, opts \\ [])
      when phase in @phases and is_list(opts) do
    resource = Atom.to_string(phase)

    if phase_terminal?(item.id, resource) do
      :ok
    else
      do_stage_phase(item, phase, opts)
    end
  end

  defp do_stage_phase(item, :labels, opts), do: import_labels(item, opts)
  defp do_stage_phase(item, :issues, opts), do: import_issues(item, opts)
  defp do_stage_phase(item, :comments, opts), do: import_comments(item, opts)
  defp do_stage_phase(item, :pull_requests, opts), do: import_pulls(item, opts)
  defp do_stage_phase(item, :number_sequence, opts), do: finalize_sequence(item, opts)

  defp import_labels(item, opts) do
    page_key = "page:1"

    if page_committed?(item.id, "labels", page_key) do
      commit_phase_terminal(item, "labels")
    else
      with {:ok, repository} <- hidden_repository(item),
           {:ok, {owner, repo}} <- source_parts(item),
           {:ok, payloads} <- fetch(:labels, item, owner, repo, opts) do
        commit_page(item, "labels", page_key, length(payloads), fn multi ->
          Enum.reduce(payloads, multi, fn payload, multi ->
            case MetadataMapper.label(payload) do
              {:ok, mapped} ->
                import_label_row(multi, item, repository, mapped, payload)

              {:error, _} ->
                multi
            end
          end)
        end)
        |> case do
          :ok -> commit_phase_terminal(item, "labels")
          error -> error
        end
      end
    end
  end

  defp import_issues(item, opts) do
    page_key = "page:1"

    if page_committed?(item.id, "issues", page_key) do
      commit_phase_terminal(item, "issues")
    else
      with {:ok, repository} <- hidden_repository(item),
           {:ok, {owner, repo}} <- source_parts(item),
           {:ok, payloads} <- fetch(:issues, item, owner, repo, opts) do
        now = observed_at(item)

        commit_page(item, "issues", page_key, length(payloads), fn multi ->
          Enum.reduce(payloads, multi, fn payload, multi ->
            case MetadataMapper.issue(payload) do
              {:ok, mapped} ->
                import_issue_row(multi, item, repository, mapped, payload, now)

              {:skip, :pull_request_issue, details} ->
                record_pull_candidate(multi, item, details[:number])

              {:skip, code, details} ->
                skip_object(multi, item, "issue", payload["id"], code, details)

              {:error, _} ->
                multi
            end
          end)
        end)
        |> case do
          :ok -> commit_phase_terminal(item, "issues")
          error -> error
        end
      end
    end
  end

  defp import_comments(item, opts) do
    with {:ok, repository} <- hidden_repository(item) do
      numbers = imported_issue_numbers(item.id)

      result =
        Enum.reduce_while(numbers, :ok, fn number, :ok ->
          page_key = "issue:#{number}"

          if page_committed?(item.id, "comments", page_key) do
            {:cont, :ok}
          else
            case import_comments_for_issue(item, repository, number, page_key, opts) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end
        end)

      case result do
        :ok -> commit_phase_terminal(item, "comments")
        error -> error
      end
    end
  end

  defp import_pulls(item, opts) do
    with {:ok, repository} <- hidden_repository(item),
         staged_refs <- staged_refs(item) do
      numbers = pending_pull_numbers(item.id)

      result =
        Enum.reduce_while(numbers, :ok, fn number, :ok ->
          page_key = "pull:#{number}"

          if page_committed?(item.id, "pull_requests", page_key) do
            {:cont, :ok}
          else
            case import_pull(item, repository, number, page_key, staged_refs, opts) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end
        end)

      case result do
        :ok -> commit_phase_terminal(item, "pull_requests")
        error -> error
      end
    end
  end

  defp finalize_sequence(item, _opts) do
    with {:ok, repository} <- hidden_repository(item) do
      if phase_terminal?(item.id, "number_sequence") do
        :ok
      else
        transaction =
          Persistence.with_retry(fn ->
            Multi.new()
            |> ForgeIssues.finalize_import_sequence_multi(:sequence, repository)
            |> Repo.transaction()
          end)

        with {:ok, _result} <- transaction do
          commit_phase_terminal(item, "number_sequence")
        else
          {:error, _reason} -> {:error, :persistence_unavailable}
        end
      end
    end
  end

  defp import_comments_for_issue(item, repository, issue_number, page_key, opts) do
    with :ok <- parent_imported?(item.id, issue_number),
         {:ok, {owner, repo}} <- source_parts(item),
         {:ok, payloads} <- fetch_comments(item, owner, repo, issue_number, opts) do
      now = observed_at(item)
      commit_page(item, "comments", page_key, length(payloads), fn multi ->
        Enum.reduce(payloads, multi, fn payload, multi ->
          case MetadataMapper.comment(payload) do
            {:ok, mapped} ->
              import_comment_row(multi, item, repository, issue_number, mapped, now)

            {:error, _} ->
              multi
          end
        end)
      end)
    else
      {:error, :parent_unsupported} ->
        commit_page(item, "comments", page_key, 0, fn multi -> multi end)
    end
  end

  defp import_pull(item, repository, number, page_key, staged_refs, opts) do
    with {:ok, {owner, repo}} <- source_parts(item),
         {:ok, payload} <- fetch_pull(item, owner, repo, number, opts) do
      now = observed_at(item)
      case MetadataMapper.pull(payload, item.github_repository_id, staged_refs: staged_refs) do
        {:ok, mapped} ->
          commit_page(item, "pull_requests", page_key, 1, fn multi ->
            import_pull_row(multi, item, repository, mapped, now)
          end)

        {:skip, code, details} ->
          commit_page(item, "pull_requests", page_key, 0, fn multi ->
            skip_pull(multi, item, number, code, details)
          end)

        {:error, _} ->
          {:error, :invalid_pull}
      end
    end
  end

  defp fetch(:labels, item, owner, repo, opts),
    do: checkout_fetch(opts, fn pat -> Client.repository_labels(pat, owner, repo, client_opts(item, opts)) end)

  defp fetch(:issues, item, owner, repo, opts),
    do: checkout_fetch(opts, fn pat -> Client.repository_issues(pat, owner, repo, client_opts(item, opts)) end)

  defp fetch_comments(item, owner, repo, issue_number, opts),
    do:
      checkout_fetch(opts, fn pat ->
        Client.issue_comments(pat, owner, repo, issue_number, client_opts(item, opts))
      end)

  defp fetch_pull(item, owner, repo, number, opts),
    do:
      checkout_fetch(opts, fn pat ->
        Client.pull_request(pat, owner, repo, number, client_opts(item, opts))
      end)

  defp checkout_fetch(opts, callback) do
    checkout = Keyword.fetch!(opts, :credential_checkout)
    checkout.(callback)
  end

  defp import_label_row(multi, item, repository, mapped, _payload) do
    key = {:label, mapped.github_id}

    if mapping_exists?(item.id, "label", mapped.github_id) do
      multi
    else
      multi
      |> ForgeIssues.import_label_multi(key, repository, %{
        name: mapped.name,
        color: mapped.color,
        description: mapped.description
      })
      |> Multi.run({:mapping, mapped.github_id}, fn repo, changes ->
        %Label{} = label = Map.fetch!(changes, key)

        insert_mapping(repo, item, "label", mapped.github_id, "ForgeIssues.Label", label.id)
      end)
    end
  end

  defp import_issue_row(multi, item, repository, mapped, payload, now) do
    key = {:issue, mapped.number}

    if mapping_exists?(item.id, "issue", mapped.github_id) do
      multi
    else
      multi
      |> Multi.run(key, fn repo, _changes ->
        with {:ok, identity} <- resolve_author(mapped, now),
             {:ok, issue} <- insert_imported_issue(repo, repository, identity, mapped),
             :ok <- insert_issue_mapping(repo, item, mapped, issue),
             :ok <- import_assignees(repo, issue, payload, now),
             :ok <- import_labels(repo, issue, payload, repository) do
          report_issue_warnings(repo, item, mapped)
          {:ok, issue}
        end
      end)
    end
  end

  defp import_comment_row(multi, item, repository, issue_number, mapped, now) do
    key = {:comment, mapped.github_id}

    if mapping_exists?(item.id, "comment", mapped.github_id) do
      multi
    else
      multi
      |> Multi.run(key, fn repo, _changes ->
        with %Issue{} = issue <- issue_by_number(repo, repository.id, issue_number),
             {:ok, identity} <- resolve_comment_author(mapped, now),
             {:ok, %{comment: comment}} <-
               Multi.new()
               |> ForgeIssues.import_comment_multi(:comment, issue, identity, %{
                 body: mapped.body,
                 inserted_at: mapped.inserted_at,
                 updated_at: mapped.updated_at
               })
               |> Repo.transaction(),
             {:ok, _mapping} <-
               insert_mapping(
                 repo,
                 item,
                 "comment",
                 mapped.github_id,
                 "ForgeIssues.Comment",
                 comment.id,
                 source_url(item, "issues", issue_number)
               ) do
          {:ok, comment}
        else
          nil -> {:error, :not_found}
          {:error, _step, reason, _} -> {:error, reason}
        end
      end)
    end
  end

  defp import_pull_row(multi, item, repository, mapped, now) do
    key = {:pull, mapped.number}

    if mapping_exists?(item.id, "pull_request", mapped.github_id) do
      multi
    else
      multi
      |> Multi.run(key, fn repo, _changes ->
        with {:ok, author} <- resolve_author(mapped, now),
             {:ok, merger} <- resolve_merger(mapped, now),
             {:ok, %{issue: issue, pull: _pull}} <-
               Multi.new()
               |> ForgeIssues.import_identity_multi(
                 :issue,
                 repository,
                 author,
                 :pull_request,
                 issue_attrs(mapped)
               )
               |> Multi.merge(fn %{issue: issue} ->
                 Multi.new()
                 |> ForgePulls.import_pull_request_multi(
                   :pull,
                   repository,
                   issue,
                   merger,
                   pull_attrs(mapped)
                 )
               end)
               |> Repo.transaction(),
             {:ok, _} <-
               insert_mapping(
                 repo,
                 item,
                 "issue",
                 mapped.github_id,
                 "ForgeIssues.Issue",
                 issue.id,
                 source_url(item, "pulls", mapped.number)
               ),
             {:ok, _} <-
               insert_mapping(
                 repo,
                 item,
                 "pull_request",
                 mapped.github_id,
                 "ForgePulls.PullRequest",
                 issue.id,
                 source_url(item, "pulls", mapped.number)
               ) do
          {:ok, issue}
        else
          {:error, _step, reason, _} -> {:error, reason}
        end
      end)
    end
  end

  defp insert_imported_issue(repo, repository, identity, mapped) do
    Multi.new()
    |> ForgeIssues.import_identity_multi(:issue, repository, identity, :issue, issue_attrs(mapped))
    |> Repo.transaction()
    |> case do
      {:ok, %{issue: issue}} -> {:ok, issue}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp issue_attrs(mapped) do
    %{
      number: mapped.number,
      title: mapped.title,
      body: mapped.body,
      state: mapped.state,
      state_reason: Map.get(mapped, :state_reason),
      closed_at: Map.get(mapped, :closed_at) || Map.get(mapped, :merged_at),
      inserted_at: mapped.inserted_at,
      updated_at: mapped.updated_at
    }
  end

  defp pull_attrs(mapped) do
    %{
      head_ref: mapped.head_ref,
      base_ref: mapped.base_ref,
      head_sha: mapped.head_sha,
      base_sha: mapped.base_sha,
      merged_at: mapped.merged_at,
      merge_commit_sha: mapped.merge_commit_sha,
      inserted_at: mapped.inserted_at,
      updated_at: mapped.updated_at
    }
  end

  defp insert_issue_mapping(repo, item, mapped, issue) do
    insert_mapping(
      repo,
      item,
      "issue",
      mapped.github_id,
      "ForgeIssues.Issue",
      issue.id,
      source_url(item, "issues", mapped.number)
    )
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp import_assignees(repo, issue, payload, now) do
    Enum.reduce_while(Map.get(payload, "assignees", []), :ok, fn assignee_payload, :ok ->
      with {:ok, github_user_id} <- ForgeImports.GitHub.User.id(assignee_payload["id"]),
           {:ok, identity} <- observe_user(github_user_id, now),
           {:ok, _} <-
             Multi.new()
             |> ForgeIssues.import_assignee_multi(:assignee, issue, identity)
             |> Repo.transaction() do
        {:cont, :ok}
      else
        _invalid -> {:cont, :ok}
      end
    end)
  end

  defp import_labels(repo, issue, payload, repository) do
    Enum.reduce_while(Map.get(payload, "labels", []), :ok, fn label_payload, :ok ->
      case MetadataMapper.label(label_payload) do
        {:ok, mapped} ->
          case Multi.new()
               |> ForgeIssues.import_label_multi(:label, repository, %{
                 name: mapped.name,
                 color: mapped.color,
                 description: mapped.description
               })
               |> Multi.merge(fn %{label: label} ->
                 Multi.new()
                 |> ForgeIssues.import_issue_label_multi(:issue_label, issue, label)
               end)
               |> Repo.transaction() do
            {:ok, _} -> {:cont, :ok}
            {:error, _, _, _} -> {:cont, :ok}
          end

        {:error, _} ->
          {:cont, :ok}
      end
    end)
  end

  defp report_issue_warnings(repo, item, %{unsupported: []}), do: :ok

  defp report_issue_warnings(repo, item, mapped) do
    Enum.each(mapped.unsupported, fn category ->
      %ReportEntry{}
      |> ReportEntry.create_changeset(%{
        import_run_id: item.import_run_id,
        repository_item_id: item.id,
        idempotency_key: "warning-#{item.id}-issue-#{mapped.number}-#{category}",
        scope: :object,
        object_kind: "issue",
        source_object_id: mapped.github_id,
        outcome: :warning,
        classification: category,
        summary: "Unsupported #{category} metadata was not imported",
        metadata: %{"category" => category},
        source_count: 0
      })
      |> repo.insert(on_conflict: :nothing, conflict_target: [:import_run_id, :idempotency_key])
    end)

    :ok
  end

  defp commit_page(item, resource_kind, page_key, item_count, fun) do
    now = DateTime.utc_now(:second)

    multi =
      fun.(Multi.new())
      |> Multi.insert(:checkpoint, fn _changes ->
        PageCheckpoint.create_changeset(%PageCheckpoint{}, %{
          repository_item_id: item.id,
          resource_kind: resource_kind,
          page_key: page_key,
          item_count: item_count,
          cursor_metadata: %{},
          committed_at: now
        })
      end)

    case Persistence.with_retry(fn -> Repo.transaction(multi) end) do
      {:ok, _result} -> :ok
      {:error, :checkpoint, _changeset, _} -> {:error, :checkpoint_failed}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp commit_phase_terminal(item, resource_kind) do
    if phase_terminal?(item.id, resource_kind) do
      :ok
    else
      commit_page(item, resource_kind, @terminal_page_key, 0, fn multi -> multi end)
    end
  end

  defp phase_terminal?(item_id, resource_kind) do
    Repo.exists?(
      from checkpoint in PageCheckpoint,
        where:
          checkpoint.repository_item_id == ^item_id and
            checkpoint.resource_kind == ^resource_kind and
            checkpoint.page_key == ^@terminal_page_key
    )
  end

  defp page_committed?(item_id, resource_kind, page_key) do
    Repo.exists?(
      from checkpoint in PageCheckpoint,
        where:
          checkpoint.repository_item_id == ^item_id and
            checkpoint.resource_kind == ^resource_kind and
            checkpoint.page_key == ^page_key
    )
  end

  defp mapping_exists?(item_id, kind, github_object_id) do
    Repo.exists?(
      from mapping in ObjectMapping,
        where:
          mapping.repository_item_id == ^item_id and mapping.object_kind == ^kind and
            mapping.github_object_id == ^github_object_id
    )
  end

  defp hidden_repository(%RepositoryItem{hidden_repository_id: id})
       when is_integer(id) and id > 0 do
    case Repo.get(Repository, id) do
      %Repository{} = repository -> {:ok, repository}
      nil -> {:error, :not_found}
    end
  end

  defp hidden_repository(_item), do: {:error, :not_found}

  defp source_parts(%RepositoryItem{source_full_name: full_name}) do
    case String.split(full_name, "/", parts: 2) do
      [owner, repository] -> {:ok, {owner, repository}}
      _invalid -> {:error, :invalid_source}
    end
  end

  defp client_opts(item, opts) do
    client_options = Keyword.get(opts, :client_options, [])

    gate_key =
      Keyword.get(opts, :gate_key,
        Keyword.get(client_options, :gate_key, {:one_time_run, item.import_run_id})
      )

    Keyword.merge(client_options, gate_key: gate_key)
  end

  defp staged_refs(%RepositoryItem{staged_storage_path: path}) when is_binary(path) do
    case GitCore.list_refs(path) do
      {:ok, refs} -> Map.new(refs, fn ref -> {ref.name, ref.target} end)
      {:error, _} -> %{}
    end
  end

  defp staged_refs(_item), do: %{}

  defp observed_at(%RepositoryItem{source_observed_at: %DateTime{} = at}), do: at
  defp observed_at(_item), do: DateTime.utc_now(:second)

  defp resolve_author(%{author_deleted: true}, _now), do: {:ok, ForgeAccounts.github_deleted_identity()}
  defp resolve_author(%{author_github_user_id: id}, now), do: observe_user(id, now)

  defp resolve_comment_author(%{author_deleted: true}, _now),
    do: {:ok, ForgeAccounts.github_deleted_identity()}

  defp resolve_comment_author(%{author_github_user_id: id}, now), do: observe_user(id, now)

  defp resolve_merger(%{merger_github_user_id: nil}, _now), do: {:ok, nil}
  defp resolve_merger(%{merger_deleted: true}, _now), do: {:ok, ForgeAccounts.github_deleted_identity()}
  defp resolve_merger(%{merger_github_user_id: id}, now), do: observe_user(id, now)

  defp observe_user(github_user_id, now) do
    case Repo.get_by(GitHubIdentity, github_user_id: github_user_id) do
      %GitHubIdentity{} = identity -> {:ok, identity}
      nil -> ForgeAccounts.observe_github_identity(%{github_user_id: github_user_id, login: "gh-#{github_user_id}", avatar_url: nil, profile_url: nil}, now)
    end
  end

  defp insert_mapping(repo, item, kind, github_object_id, local_type, local_id, source_url \\ nil) do
    %ObjectMapping{}
    |> ObjectMapping.create_changeset(%{
      repository_item_id: item.id,
      hidden_repository_id: item.hidden_repository_id,
      github_repository_id: item.github_repository_id,
      object_kind: kind,
      github_object_id: github_object_id,
      local_resource_type: local_type,
      local_resource_id: local_id,
      source_url: source_url
    })
    |> repo.insert()
  end

  defp issue_by_number(repo, repository_id, number),
    do: repo.get_by(Issue, repository_id: repository_id, number: number)

  defp imported_issue_numbers(item_id) do
    Repo.all(
      from issue in Issue,
        join: mapping in ObjectMapping,
        on:
          mapping.local_resource_id == issue.id and mapping.repository_item_id == ^item_id and
            mapping.object_kind == "issue",
        order_by: [asc: issue.number],
        select: issue.number
    )
  end

  defp pending_pull_numbers(item_id) do
    Repo.all(
      from report in ReportEntry,
        where: report.repository_item_id == ^item_id and report.classification == "pull_candidate",
        select: report.source_object_id
    )
  end

  defp parent_imported?(item_id, issue_number) do
    if Repo.exists?(
         from mapping in ObjectMapping,
           join: issue in Issue,
           on: issue.id == mapping.local_resource_id,
           where:
             mapping.repository_item_id == ^item_id and mapping.object_kind == "issue" and
               issue.number == ^issue_number
       ),
       do: :ok,
       else: {:error, :parent_unsupported}
  end

  defp record_pull_candidate(multi, item, number) do
    Multi.insert(
      multi,
      {:pull_candidate, number},
      ReportEntry.create_changeset(%ReportEntry{}, %{
        import_run_id: item.import_run_id,
        repository_item_id: item.id,
        idempotency_key: "pull-candidate-#{item.id}-#{number}",
        scope: :object,
        object_kind: "pull_request",
        source_object_id: number,
        outcome: :skipped,
        classification: "pull_candidate",
        summary: "Pull request deferred to pull phase",
        metadata: %{"count" => number},
        source_count: 0
      }),
      on_conflict: :nothing,
      conflict_target: [:import_run_id, :idempotency_key]
    )
  end

  defp skip_object(multi, item, kind, github_id, code, details) do
    Multi.insert(
      multi,
      {:skip, {kind, github_id}},
      ReportEntry.create_changeset(%ReportEntry{}, %{
        import_run_id: item.import_run_id,
        repository_item_id: item.id,
        idempotency_key: "skip-#{item.id}-#{kind}-#{github_id}",
        scope: :object,
        object_kind: kind,
        source_object_id: github_id,
        outcome: :skipped,
        classification: Atom.to_string(code),
        summary: "Skipped #{kind}",
        metadata: sanitize_report_metadata(details),
        source_count: 0
      }),
      on_conflict: :nothing,
      conflict_target: [:import_run_id, :idempotency_key]
    )
  end

  @report_metadata_keys ~w(code field phase state count github_id category expected actual visibility)

  defp sanitize_report_metadata(details) when is_map(details) do
    details
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("count", Map.get(details, :number) || Map.get(details, "number"))
    |> Map.drop(["number"])
    |> Map.take(@report_metadata_keys)
  end

  defp skip_pull(multi, item, number, code, details),
    do: skip_object(multi, item, "pull_request", number, code, details)

  defp source_url(item, segment, number),
    do: "https://github.com/#{item.source_full_name}/#{segment}/#{number}"

  defp stringify_metadata(details) when is_map(details), do: sanitize_report_metadata(details)
end
