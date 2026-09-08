defmodule ForgeImports.GitHub.MetadataImporter do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeAccounts
  alias ForgeAccounts.GitHubIdentity
  alias ForgeGitHub.Client
  alias ForgeImports.GitHub.MetadataMapper
  alias ForgeImports.{ObjectMapping, PageCheckpoint, Persistence, ReportEntry, RepositoryItem}
  alias ForgeIssues
  alias ForgeIssues.{Issue, Label}
  alias ForgePulls
  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitCore

  @phases [:labels, :issues, :comments, :pull_requests, :number_sequence]
  @terminal_page_key "__terminal_v1__"

  @type credential_metadata :: %{
          required(:git_login) => String.t(),
          required(:gate_key) => term()
        }
  @type credential_checkout :: ((String.t(), credential_metadata() -> term()) -> term())

  @spec stage(RepositoryItem.t(), credential_checkout(), keyword()) ::
          :ok | {:ok, :identity_recovered} | {:error, atom()}
  def stage(%RepositoryItem{} = item, credential_checkout, opts \\ [])
      when is_function(credential_checkout, 1) and is_list(opts) do
    opts = Keyword.put(opts, :credential_checkout, normalize_checkout(credential_checkout, opts))

    if validate_pull_issue_identities(item) == :ok do
      Enum.reduce_while(@phases, :ok, fn phase, :ok ->
        case stage_phase(item, phase, opts) do
          :ok ->
            {:cont, :ok}

          {:error, :pull_issue_identity_requires_refetch} ->
            {:halt, recover_next_pull_identity(item, opts)}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    else
      report_unverified_pull_identity(item)
      recover_next_pull_identity(item, opts)
    end
  end

  defp recover_next_pull_identity(item, opts) do
    mapped =
      invalid_pull_identities(item)
      |> select([_mapping, _pull, issue], issue.number)
      |> order_by([_mapping, _pull, issue], asc: issue.number)
      |> limit(1)
      |> Repo.all()

    number =
      case mapped do
        [number] ->
          number

        [] ->
          Repo.one(
            from candidate in ReportEntry,
              left_join: page in PageCheckpoint,
              on:
                page.repository_item_id == candidate.repository_item_id and
                  page.resource_kind == "pull_requests" and
                  fragment("? = 'pull:' || ?::text", page.page_key, candidate.source_object_id),
              where:
                candidate.repository_item_id == ^item.id and
                  candidate.classification == "pull_candidate" and is_nil(page.id),
              order_by: candidate.source_object_id,
              select: candidate.source_object_id,
              limit: 1
          )
      end

    if is_integer(number) and number > 0 do
      case revalidate_pull_issue_identity(item, number, opts) do
        :ok -> {:ok, :identity_recovered}
        error -> error
      end
    else
      {:error, :pull_issue_identity_requires_refetch}
    end
  end

  @spec stage_phase(RepositoryItem.t(), atom(), keyword()) :: :ok | {:error, atom()}
  def stage_phase(%RepositoryItem{} = item, phase, opts \\ [])
      when phase in @phases and is_list(opts) do
    resource = Atom.to_string(phase)

    result =
      with :ok <- validate_completed_pull_identities(item, phase) do
        if phase_terminal?(item.id, resource), do: :ok, else: do_stage_phase(item, phase, opts)
      end

    case result do
      {:error, :pull_issue_identity_requires_refetch} = error ->
        report_unverified_pull_identity(item)
        error

      other ->
        other
    end
  end

  @doc false
  def revalidate_pull_issue_identity(%RepositoryItem{} = item, number, opts)
      when is_integer(number) and number > 0 and number <= 999_999 and is_list(opts) do
    with {:ok, _} <- hidden_repository(item),
         {:ok, {owner, name}} <- source_parts(item),
         {:ok, {issue_id, pull_id}} <-
           checkout_fetch(opts, fn credential, metadata ->
             options = client_opts(opts, metadata)

             with {:ok, remote} <- Client.repository(credential, owner, name, options),
                  true <-
                    remote.id == item.github_repository_id and
                      remote.full_name == item.source_full_name,
                  {:ok, issue} <-
                    Client.repository_issue(credential, owner, name, number, options),
                  {:skip, :pull_request_issue, %{number: ^number, github_issue_id: issue_id}} <-
                    MetadataMapper.issue(issue),
                  true <-
                    get_in(issue, ["pull_request", "url"]) ==
                      "https://api.github.com/repos/#{owner}/#{name}/pulls/#{number}",
                  {:ok, pull} <- Client.pull_request(credential, owner, name, number, options),
                  true <-
                    pull["number"] == number and get_in(pull, ["base", "repo", "id"]) == remote.id,
                  {:ok, pull_id} <- ForgeGitHub.User.id(pull["id"]) do
               {:ok, {issue_id, pull_id}}
             else
               {:error, _} = error -> error
               _ -> {:error, :pull_issue_identity_mismatch}
             end
           end) do
      repair_pull_issue_identity(item, number, issue_id, pull_id)
    end
  end

  defp repair_pull_issue_identity(item, number, issue_id, pull_id) do
    Repo.transaction(fn ->
      run =
        Repo.one(
          from r in ForgeImports.ImportRun, where: r.id == ^item.import_run_id, lock: "FOR UPDATE"
        )

      unless run && run.state == :running, do: Repo.rollback(:stale_item)
      current = Repo.one(from i in RepositoryItem, where: i.id == ^item.id, lock: "FOR UPDATE")

      unless current && current.lock_version == item.lock_version &&
               current.state == item.state && current.lease_owner == item.lease_owner &&
               current.state in [:git_staged, :staging_metadata, :ready_to_publish] &&
               ((is_nil(current.lease_owner) && is_nil(current.lease_expires_at)) ||
                  (is_binary(current.lease_owner) && is_struct(current.lease_expires_at, DateTime) &&
                     DateTime.compare(current.lease_expires_at, DateTime.utc_now()) == :gt)) &&
               current.hidden_repository_id == item.hidden_repository_id &&
               current.destination_owner_id == item.destination_owner_id &&
               current.github_repository_id == item.github_repository_id &&
               current.source_full_name == item.source_full_name,
             do: Repo.rollback(:stale_item)

      repository =
        Repo.one(
          from r in Repository, where: r.id == ^current.hidden_repository_id, lock: "FOR UPDATE"
        )

      unless repository && repository.lifecycle == :importing && is_nil(repository.deleted_at),
        do: Repo.rollback(:pull_issue_identity_requires_coordinated_repair)

      unless repository.owner_user_id == current.destination_owner_id,
        do: Repo.rollback(:stale_item)

      case ForgeImports.CredentialProvider.authorize_recovery_locked(run, current) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      if Repo.exists?(
           from m in ForgeMirrors.RepositoryMirror, where: m.repository_id == ^repository.id
         ),
         do: Repo.rollback(:pull_issue_identity_requires_coordinated_repair)

      candidate =
        Repo.one(
          from c in ReportEntry,
            where:
              c.repository_item_id == ^item.id and c.import_run_id == ^item.import_run_id and
                c.classification == "pull_candidate" and c.source_object_id == ^number,
            lock: "FOR UPDATE"
        )

      unless candidate, do: Repo.rollback(:pull_issue_identity_mismatch)

      case ForgeGitHub.User.id(candidate.metadata["github_id"]) do
        {:ok, ^issue_id} -> :ok
        {:ok, _contradictory_id} -> Repo.rollback(:pull_issue_identity_mismatch)
        :error -> :ok
      end

      local_issue =
        Repo.one(
          from i in Issue,
            where: i.repository_id == ^repository.id and i.number == ^number,
            lock: "FOR UPDATE"
        )

      local_issue_id = if local_issue, do: local_issue.id, else: 0

      mappings =
        Repo.all(
          from m in ObjectMapping,
            where:
              m.repository_item_id == ^item.id and
                ((m.object_kind == "pull_request" and m.github_object_id == ^pull_id) or
                   (m.object_kind == "issue" and m.local_resource_id == ^local_issue_id)),
            order_by: m.id,
            lock: "FOR UPDATE"
        )

      pull_mapping =
        Enum.find(
          mappings,
          &(&1.object_kind == "pull_request" and &1.github_object_id == pull_id)
        )

      if pull_mapping do
        pull = Repo.get(ForgePulls.PullRequest, pull_mapping.local_resource_id)
        issue = if pull, do: Repo.get(Issue, pull.issue_id)

        identity =
          if issue,
            do:
              Enum.find(
                mappings,
                &(&1.object_kind == "issue" and &1.local_resource_id == issue.id)
              )

        unless pull && issue && identity &&
                 pull_mapping.local_resource_type == "ForgePulls.PullRequest" &&
                 pull.repository_id == repository.id && issue.repository_id == repository.id &&
                 issue.number == number && issue.kind == :pull_request &&
                 identity.local_resource_type == "ForgeIssues.Issue" &&
                 Enum.all?(
                   [identity, pull_mapping],
                   &(&1.hidden_repository_id == repository.id &&
                       &1.github_repository_id == item.github_repository_id)
                 ) &&
                 identity.github_object_id in [pull_id, issue_id],
               do: Repo.rollback(:pull_issue_identity_mismatch)

        if Repo.exists?(
             from m in ObjectMapping,
               where:
                 m.repository_item_id == ^item.id and
                   m.object_kind == "issue" and m.github_object_id == ^issue_id and
                   m.id != ^identity.id
           ),
           do: Repo.rollback(:pull_issue_identity_mismatch)

        identity |> Ecto.Changeset.change(github_object_id: issue_id) |> Repo.update!()
      else
        # Candidate-only recovery is safe only before any local PR for this number exists.
        if Repo.exists?(
             from i in Issue, where: i.repository_id == ^repository.id and i.number == ^number
           ),
           do: Repo.rollback(:pull_issue_identity_mismatch)
      end

      candidate
      |> Ecto.Changeset.change(metadata: Map.put(candidate.metadata, "github_id", issue_id))
      |> Repo.update!()

      pending_evidence? =
        Repo.exists?(
          from c in ReportEntry,
            where:
              c.repository_item_id == ^item.id and c.classification == "pull_candidate" and
                fragment("COALESCE(jsonb_typeof(?->'github_id'), '') <> 'number'", c.metadata)
        )

      if not pending_evidence? and
           validate_completed_pull_identities(current, :pull_requests) == :ok do
        Repo.update_all(
          from(r in ReportEntry,
            where:
              r.repository_item_id == ^item.id and
                r.classification == "pull_issue_identity_requires_refetch"
          ),
          set: [
            outcome: :imported,
            summary: "Pull request issue identity authenticated and revalidated",
            metadata: %{"phase" => "pull_requests", "code" => "authenticated_refetch_completed"}
          ]
        )
      end

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
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
                record_pull_candidate(multi, item, details)

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
          with true <- mapped.number == number,
               {:ok, issue_id} <- candidate_issue_id(item, number) do
            ForgeImports.GitHub.PullHeadBinding.with_binding(
              item,
              mapped,
              fn head_repository_id ->
                commit_page(item, "pull_requests", page_key, 1, fn multi ->
                  multi
                  |> Multi.run({:head_identity, mapped.github_id}, fn _repo, _ ->
                    persist_pull_head_identity(item, mapped, head_repository_id)
                  end)
                  |> import_pull_row(
                    item,
                    repository,
                    Map.merge(mapped, %{
                      github_issue_id: issue_id,
                      head_repository_id: head_repository_id
                    }),
                    now
                  )
                  |> Multi.run({:head_diagnostic, mapped.github_id}, fn _repo, _ ->
                    resolve_pending_pull_head(item, mapped)
                  end)
                end)
              end
            )
            |> case do
              {:error, :pull_head_not_ready} = error ->
                report_pending_pull_head(item, mapped)
                error

              result ->
                result
            end
          else
            false -> {:error, :invalid_pull}
            {:error, _} = error -> error
          end

        {:skip, code, details} ->
          commit_page(item, "pull_requests", page_key, 0, fn multi ->
            skip_pull(multi, item, number, code, details)
          end)

        {:error, _} ->
          {:error, :invalid_pull}
      end
    end
  end

  defp fetch(:labels, _item, owner, repo, opts),
    do:
      checkout_fetch(opts, fn credential, metadata ->
        Client.repository_labels(credential, owner, repo, client_opts(opts, metadata))
      end)

  defp fetch(:issues, _item, owner, repo, opts),
    do:
      checkout_fetch(opts, fn credential, metadata ->
        Client.repository_issues(credential, owner, repo, client_opts(opts, metadata))
      end)

  defp fetch_comments(_item, owner, repo, issue_number, opts),
    do:
      checkout_fetch(opts, fn credential, metadata ->
        Client.issue_comments(credential, owner, repo, issue_number, client_opts(opts, metadata))
      end)

  defp fetch_pull(_item, owner, repo, number, opts),
    do:
      checkout_fetch(opts, fn credential, metadata ->
        Client.pull_request(credential, owner, repo, number, client_opts(opts, metadata))
      end)

  defp checkout_fetch(opts, callback) do
    checkout = Keyword.fetch!(opts, :credential_checkout)
    checkout.(callback)
  end

  defp normalize_checkout(credential_checkout, opts) do
    case Keyword.fetch(opts, :gate_key) do
      {:ok, gate_key} ->
        fn callback ->
          credential_checkout.(fn credential ->
            callback.(credential, %{gate_key: gate_key})
          end)
        end

      :error ->
        credential_checkout
    end
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
             {:ok, %{issue: issue, pull: pull}} <-
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
                   pull_attrs(mapped),
                   mapped.head_repository_id
                 )
               end)
               |> Repo.transaction(),
             {:ok, _} <-
               insert_mapping(
                 repo,
                 item,
                 "issue",
                 mapped.github_issue_id,
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
                 pull.id,
                 source_url(item, "pulls", mapped.number)
               ) do
          {:ok, issue}
        else
          {:error, _step, reason, _} -> {:error, reason}
        end
      end)
    end
  end

  defp insert_imported_issue(_repo, repository, identity, mapped) do
    Multi.new()
    |> ForgeIssues.import_identity_multi(
      :issue,
      repository,
      identity,
      :issue,
      issue_attrs(mapped)
    )
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
      draft: mapped.draft,
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

  defp persist_pull_head_identity(item, mapped, head_repository_id) do
    key = "pull-head-identity-#{item.id}-#{mapped.github_id}"

    case Repo.get_by(ReportEntry, import_run_id: item.import_run_id, idempotency_key: key) do
      %ReportEntry{} = evidence ->
        if evidence.source_object_id == mapped.github_id &&
             evidence.metadata["github_id"] == mapped.head_github_repository_id &&
             evidence.metadata["github_node_id"] == mapped.head_github_node_id,
           do: {:ok, evidence},
           else: {:error, :pull_head_identity_mismatch}

      nil ->
        %ReportEntry{}
        |> ReportEntry.create_changeset(%{
          import_run_id: item.import_run_id,
          repository_item_id: item.id,
          idempotency_key: key,
          scope: :object,
          object_kind: "pull_request",
          source_object_id: mapped.github_id,
          outcome: :imported,
          classification: "pull_head_identity",
          summary: "Retained immutable pull head repository identity",
          metadata: %{
            "github_id" => mapped.head_github_repository_id,
            "github_node_id" => mapped.head_github_node_id,
            "code" =>
              if(is_nil(head_repository_id), do: "external_read_only", else: "represented")
          },
          source_count: 0
        })
        |> Repo.insert()
    end
  end

  defp report_pending_pull_head(item, mapped) do
    %ReportEntry{}
    |> ReportEntry.create_changeset(%{
      import_run_id: item.import_run_id,
      repository_item_id: item.id,
      idempotency_key: "pull-head-pending-#{item.id}-#{mapped.github_id}",
      scope: :object,
      object_kind: "pull_request",
      source_object_id: mapped.github_id,
      outcome: :warning,
      classification: "pull_head_not_ready",
      summary: "Represented pull head awaits confirmed available refs",
      metadata: %{
        "github_id" => mapped.head_github_repository_id,
        "github_node_id" => mapped.head_github_node_id,
        "code" => "head_ref_proof_required"
      },
      source_count: 0
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:import_run_id, :idempotency_key])
  end

  defp resolve_pending_pull_head(item, mapped) do
    case Repo.get_by(ReportEntry,
           import_run_id: item.import_run_id,
           idempotency_key: "pull-head-pending-#{item.id}-#{mapped.github_id}"
         ) do
      nil ->
        {:ok, :not_applicable}

      %ReportEntry{} = report ->
        if report.metadata["github_id"] == mapped.head_github_repository_id &&
             report.metadata["github_node_id"] == mapped.head_github_node_id do
          report
          |> ReportEntry.create_changeset(%{
            outcome: :imported,
            summary: "Represented pull head refs verified and imported",
            metadata: Map.put(report.metadata, "code", "head_ref_proof_confirmed")
          })
          |> Repo.update()
        else
          {:error, :pull_head_identity_mismatch}
        end
    end
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

  defp import_assignees(_repo, issue, payload, now) do
    Enum.reduce_while(Map.get(payload, "assignees", []), :ok, fn assignee_payload, :ok ->
      with {:ok, github_user_id} <- ForgeGitHub.User.id(assignee_payload["id"]),
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

  defp import_labels(_repo, issue, payload, repository) do
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

  defp report_issue_warnings(_repo, _item, %{unsupported: []}), do: :ok

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

  defp client_opts(opts, %{gate_key: gate_key}) do
    client_options = Keyword.get(opts, :client_options, [])
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

  defp resolve_author(%{author_deleted: true}, _now),
    do: {:ok, ForgeAccounts.github_deleted_identity()}

  defp resolve_author(%{author_github_user_id: id}, now), do: observe_user(id, now)

  defp resolve_comment_author(%{author_deleted: true}, _now),
    do: {:ok, ForgeAccounts.github_deleted_identity()}

  defp resolve_comment_author(%{author_github_user_id: id}, now), do: observe_user(id, now)

  defp resolve_merger(%{merger_github_user_id: nil}, _now), do: {:ok, nil}

  defp resolve_merger(%{merger_deleted: true}, _now),
    do: {:ok, ForgeAccounts.github_deleted_identity()}

  defp resolve_merger(%{merger_github_user_id: id}, now), do: observe_user(id, now)

  defp observe_user(github_user_id, now) do
    case Repo.get_by(GitHubIdentity, github_user_id: github_user_id) do
      %GitHubIdentity{} = identity ->
        {:ok, identity}

      nil ->
        ForgeAccounts.observe_github_identity(
          %{
            github_user_id: github_user_id,
            login: "gh-#{github_user_id}",
            avatar_url: nil,
            profile_url: nil
          },
          now
        )
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
        where:
          report.repository_item_id == ^item_id and report.classification == "pull_candidate",
        order_by: report.source_object_id,
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

  defp record_pull_candidate(multi, item, %{number: number, github_issue_id: issue_id}) do
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
        metadata: %{"count" => number, "github_id" => issue_id},
        source_count: 0
      }),
      on_conflict: :nothing,
      conflict_target: [:import_run_id, :idempotency_key]
    )
  end

  defp candidate_issue_id(item, number) do
    candidate =
      Repo.get_by(ReportEntry,
        import_run_id: item.import_run_id,
        repository_item_id: item.id,
        classification: "pull_candidate",
        source_object_id: number
      )

    case candidate do
      %ReportEntry{metadata: %{"github_id" => id}}
      when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 ->
        {:ok, id}

      _ ->
        {:error, :pull_issue_identity_requires_refetch}
    end
  end

  # Completed legacy checkpoints are not sufficient identity proof. In particular,
  # older imports used the PR ID for both mappings. Revalidation must fetch trusted
  # issue evidence; this guard never repairs identities by matching a number alone.
  @doc false
  def validate_pull_issue_identities(%RepositoryItem{} = item),
    do: validate_completed_pull_identities(item, :pull_requests)

  defp validate_completed_pull_identities(item, :pull_requests) do
    if Repo.exists?(invalid_pull_identities(item)),
      do: {:error, :pull_issue_identity_requires_refetch},
      else: :ok
  end

  defp validate_completed_pull_identities(_, _), do: :ok

  defp invalid_pull_identities(item) do
    from mapping in ObjectMapping,
      left_join: pull in ForgePulls.PullRequest,
      on:
        pull.id == mapping.local_resource_id and
          mapping.local_resource_type == "ForgePulls.PullRequest",
      left_join: issue in Issue,
      on:
        issue.id == pull.issue_id and issue.repository_id == ^item.hidden_repository_id and
          issue.kind == :pull_request,
      left_join: identity in ObjectMapping,
      on:
        identity.repository_item_id == mapping.repository_item_id and
          identity.object_kind == "issue" and
          identity.local_resource_type == "ForgeIssues.Issue" and
          identity.local_resource_id == issue.id,
      left_join: candidate in ReportEntry,
      on:
        candidate.repository_item_id == mapping.repository_item_id and
          candidate.import_run_id == ^item.import_run_id and
          candidate.classification == "pull_candidate" and
          candidate.source_object_id == issue.number,
      where: mapping.repository_item_id == ^item.id and mapping.object_kind == "pull_request",
      where:
        is_nil(pull.id) or is_nil(issue.id) or is_nil(identity.id) or is_nil(candidate.id) or
          fragment(
            "COALESCE(jsonb_typeof(?->'github_id'), '') <> 'number'",
            candidate.metadata
          ) or
          fragment(
            "COALESCE(?->>'github_id', '') <> ?::text",
            candidate.metadata,
            identity.github_object_id
          )
  end

  defp report_unverified_pull_identity(item) do
    %ReportEntry{}
    |> ReportEntry.create_changeset(%{
      import_run_id: item.import_run_id,
      repository_item_id: item.id,
      idempotency_key: "pull-issue-identity-refetch-#{item.id}",
      scope: :repository,
      outcome: :failed,
      classification: "pull_issue_identity_requires_refetch",
      summary: "Pull request issue identity requires authenticated refetch before publication",
      metadata: %{"phase" => "pull_requests", "code" => "authenticated_refetch_required"},
      source_count: 0
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:import_run_id, :idempotency_key])
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
end
