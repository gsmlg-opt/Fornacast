defmodule ForgeImports.OrganizationSync.Handoff do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeImports.ObjectMapping
  alias ForgeIssues.{Comment, Issue, Label}

  alias ForgeMirrors.{
    MirrorOperation,
    MirrorRefState,
    MirrorResourceState,
    MirrorWebhookDelivery,
    OrganizationMirror,
    RepositoryMirror
  }

  alias ForgePulls.PullRequest
  alias ForgeRepos.Repository

  @supported_repository_events ["repository", "push", "create", "delete"]

  def append(%Multi{} = multi, name, run_id, item_id, %DateTime{} = now)
      when is_atom(name) and is_integer(run_id) and run_id > 0 and is_integer(item_id) and
             item_id > 0 do
    Multi.run(multi, name, fn repo, %{repository: publication, item: item} ->
      handoff(repo, run_id, item_id, publication.repository, item, now)
    end)
  end

  defp handoff(repo, run_id, item_id, %Repository{} = repository, item, now) do
    case bootstrap_mirror(repo, run_id) do
      nil ->
        {:ok, :not_applicable}

      %OrganizationMirror{state: state} = organization_mirror
      when state in [:bootstrapping, :catching_up] ->
        with :ok <- validate_publication(organization_mirror, repository, item, item_id),
             {:ok, repository} <- hold_lfs_publication(repo, organization_mirror, repository),
             {:ok, repository_mirror} <-
               bind_repository_mirror(repo, organization_mirror, repository, item, now),
             {:ok, resource_count} <- promote_resources(repo, repository_mirror, item, now),
             {:ok, ref_count} <- seed_refs(repo, repository_mirror, repository, now),
             {:ok, replay_count} <-
               make_buffered_deliveries_eligible(repo, organization_mirror, item, now),
             {:ok, operation} <- record_reconciliation(repo, repository_mirror, item, now) do
          {:ok,
           %{
             repository: repository,
             repository_mirror: repository_mirror,
             reconciliation_operation: operation,
             promoted_resources: resource_count,
             seeded_refs: ref_count,
             eligible_deliveries: replay_count
           }}
        end

      %OrganizationMirror{} ->
        {:error, :bootstrap_handoff_unavailable}
    end
  end

  defp hold_lfs_publication(repo, organization_mirror, repository) do
    if Map.get(organization_mirror.capabilities || %{}, "lfs") in [
         true,
         :enabled,
         :active,
         "enabled",
         "active"
       ] do
      repository
      |> Ecto.Changeset.change(lifecycle: :synchronizing)
      |> repo.update()
    else
      {:ok, repository}
    end
  end

  defp bootstrap_mirror(repo, run_id) do
    OrganizationMirror
    |> where(
      [mirror],
      mirror.bootstrap_import_run_id == ^run_id and mirror.provider == "github"
    )
    |> order_by([mirror], desc: mirror.id)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp validate_publication(organization_mirror, repository, item, item_id) do
    cond do
      item.id != item_id ->
        {:error, :bootstrap_handoff_mismatch}

      repository.id != item.hidden_repository_id ->
        {:error, :bootstrap_handoff_mismatch}

      repository.owner_user_id != organization_mirror.organization_id ->
        {:error, :bootstrap_handoff_mismatch}

      not (is_integer(item.github_repository_id) and item.github_repository_id > 0) ->
        {:error, :bootstrap_handoff_mismatch}

      true ->
        :ok
    end
  end

  defp bind_repository_mirror(repo, organization_mirror, repository, item, now) do
    existing =
      RepositoryMirror
      |> where(
        [mirror],
        mirror.organization_mirror_id == ^organization_mirror.id and
          mirror.github_repository_id == ^item.github_repository_id and
          mirror.state != :tombstoned
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    attrs = %{
      organization_mirror_id: organization_mirror.id,
      repository_id: repository.id,
      github_repository_id: item.github_repository_id,
      github_full_name: item.source_full_name,
      bootstrap_repository_item_id: item.id,
      last_inventory_at: item.source_observed_at || now
    }

    changeset =
      case existing do
        nil -> RepositoryMirror.create_changeset(%RepositoryMirror{}, attrs)
        %RepositoryMirror{} = mirror -> RepositoryMirror.update_changeset(mirror, attrs)
      end

    repo.insert_or_update(changeset)
  end

  defp promote_resources(repo, repository_mirror, item, now) do
    mappings =
      repo.all(
        from mapping in ObjectMapping,
          where: mapping.repository_item_id == ^item.id,
          order_by: [asc: mapping.id]
      )
      |> Enum.sort_by(fn mapping -> if mapping.object_kind == "label", do: 0, else: 1 end)

    Enum.reduce_while(mappings, {:ok, 0}, fn mapping, {:ok, count} ->
      with {:ok, attrs} <- resource_attrs(repo, repository_mirror, mapping, now),
           {:ok, _state} <- persist_resource_state(repo, repository_mirror.id, attrs) do
        {:cont, {:ok, count + 1}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resource_attrs(repo, repository_mirror, mapping, now) do
    with {:ok, kind} <- resource_kind(mapping.object_kind),
         {:ok, resource} <- local_resource(repo, mapping),
         :ok <- validate_local_resource(repo, resource, repository_mirror.repository_id),
         {:ok, snapshot} <- resource_snapshot(kind, resource, repo, repository_mirror.id),
         {:ok, fingerprint} <- ForgeMirrors.resource_fingerprint(snapshot),
         %DateTime{} = remote_updated_at <- Map.get(resource, :updated_at) do
      {:ok,
       %{
         repository_mirror_id: repository_mirror.id,
         resource_kind: kind,
         local_resource_type: mapping.local_resource_type,
         local_resource_id: resource.id,
         github_object_id: mapping.github_object_id,
         github_number: resource_number(kind, resource, repo),
         confirmed_local_version: resource_local_version(resource, remote_updated_at),
         confirmed_remote_updated_at: remote_updated_at,
         confirmed_fingerprint: fingerprint,
         confirmed_snapshot: snapshot,
         state: :confirmed,
         lock_version: 1,
         inserted_at: now,
         updated_at: now
       }}
    else
      nil -> {:error, :bootstrap_mapping_missing}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :bootstrap_mapping_invalid}
    end
  end

  defp resource_kind("label"), do: {:ok, :label}
  defp resource_kind("issue"), do: {:ok, :issue}
  defp resource_kind("comment"), do: {:ok, :issue_comment}
  defp resource_kind("pull_request"), do: {:ok, :pull}
  defp resource_kind(_kind), do: {:error, :bootstrap_mapping_unsupported}

  defp local_resource(repo, %{object_kind: "label", local_resource_id: id}),
    do: fetch_resource(repo, Label, id)

  defp local_resource(repo, %{object_kind: "issue", local_resource_id: id}),
    do: fetch_resource(repo, Issue, id)

  defp local_resource(repo, %{object_kind: "comment", local_resource_id: id}),
    do: fetch_resource(repo, Comment, id)

  defp local_resource(repo, %{object_kind: "pull_request", local_resource_id: id}) do
    case repo.get(PullRequest, id) do
      %PullRequest{} = pull ->
        {:ok, pull}

      nil ->
        case repo.get_by(PullRequest, issue_id: id) do
          %PullRequest{} = pull -> {:ok, pull}
          nil -> {:error, :bootstrap_mapping_missing}
        end
    end
  end

  defp fetch_resource(repo, schema, id) when is_integer(id) and id > 0 do
    case repo.get(schema, id) do
      nil -> {:error, :bootstrap_mapping_missing}
      resource -> {:ok, resource}
    end
  end

  defp fetch_resource(_repo, _schema, _id), do: {:error, :bootstrap_mapping_invalid}

  defp validate_local_resource(_repo, %Label{repository_id: repository_id}, repository_id),
    do: :ok

  defp validate_local_resource(_repo, %Issue{repository_id: repository_id}, repository_id),
    do: :ok

  defp validate_local_resource(repo, %Comment{issue_id: issue_id}, repository_id) do
    case repo.get(Issue, issue_id) do
      %Issue{repository_id: ^repository_id} -> :ok
      _other -> {:error, :bootstrap_mapping_mismatch}
    end
  end

  defp validate_local_resource(
         _repo,
         %PullRequest{repository_id: repository_id},
         repository_id
       ),
       do: :ok

  defp validate_local_resource(_repo, _resource, _repository_id),
    do: {:error, :bootstrap_mapping_mismatch}

  defp resource_snapshot(:label, label, _repo, _mirror_id),
    do:
      {:ok,
       %{
         "name" => label.name,
         "color" => label.color,
         "description" => label.description,
         "default" => label.default
       }}

  defp resource_snapshot(:issue, issue, _repo, mirror_id),
    do: canonical_issue_snapshot(issue.repository_id, :issue, issue.id, mirror_id)

  defp resource_snapshot(:issue_comment, comment, repo, mirror_id) do
    case repo.get(Issue, comment.issue_id) do
      %Issue{} = issue ->
        canonical_issue_snapshot(issue.repository_id, :issue_comment, comment.id, mirror_id)

      nil ->
        {:error, :bootstrap_mapping_missing}
    end
  end

  defp resource_snapshot(:pull, pull, repo, _mirror_id) do
    case repo.get(Issue, pull.issue_id) do
      %Issue{} = issue ->
        {:ok,
         %{
           "number" => issue.number,
           "head_ref" => pull.head_ref,
           "base_ref" => pull.base_ref,
           "head_sha" => pull.head_sha,
           "base_sha" => pull.base_sha,
           "merged_at" => datetime_value(pull.merged_at),
           "merge_commit_sha" => pull.merge_commit_sha
         }}

      nil ->
        {:error, :bootstrap_mapping_missing}
    end
  end

  defp canonical_issue_snapshot(repository_id, kind, local_id, mirror_id) do
    with {:ok, projection} <- ForgeIssues.sync_projection(repository_id, kind, local_id),
         {:ok, relationships} <-
           ForgeMirrors.resolve_issue_relationships(
             mirror_id,
             :local,
             projection.label_ids,
             projection.assignee_refs
           ),
         {:ok, canonical} <- ForgeGitHub.IssueSyncProjection.from_local(projection, relationships) do
      {:ok, canonical.snapshot}
    end
  end

  defp resource_number(:issue, issue, _repo), do: issue.number

  defp resource_number(:issue_comment, comment, repo) do
    case repo.get(Issue, comment.issue_id) do
      %Issue{} = issue -> issue.number
      nil -> nil
    end
  end

  defp resource_number(:pull, pull, repo) do
    case repo.get(Issue, pull.issue_id) do
      %Issue{} = issue -> issue.number
      nil -> nil
    end
  end

  defp resource_number(_kind, _resource, _repo), do: nil

  defp persist_resource_state(repo, repository_mirror_id, attrs) do
    existing =
      MirrorResourceState
      |> where(
        [state],
        state.repository_mirror_id == ^repository_mirror_id and
          state.resource_kind == ^attrs.resource_kind and
          state.github_object_id == ^attrs.github_object_id
      )
      |> lock("FOR UPDATE")
      |> repo.one()

    case existing do
      nil ->
        %MirrorResourceState{}
        |> MirrorResourceState.persistence_changeset(attrs)
        |> repo.insert()

      %MirrorResourceState{local_resource_id: local_id} = state
      when local_id == attrs.local_resource_id ->
        state
        |> MirrorResourceState.persistence_changeset(attrs)
        |> repo.update()

      %MirrorResourceState{} ->
        {:error, :bootstrap_mapping_mismatch}
    end
  end

  defp seed_refs(repo, repository_mirror, repository, _now) do
    case GitCore.list_refs(ForgeRepos.absolute_storage_path(repository)) do
      {:ok, refs} ->
        refs
        |> Enum.filter(&standard_ref?/1)
        |> Enum.reduce_while({:ok, 0}, fn ref, {:ok, count} ->
          attrs = %{
            repository_mirror_id: repository_mirror.id,
            ref_name: ref.name,
            ref_kind: ref_kind(ref.name),
            confirmed_oid: nil,
            last_local_oid: ref.target,
            last_remote_oid: ref.target,
            state: :pending,
            last_confirmed_at: nil,
            lock_version: 1
          }

          case persist_ref_state(repo, attrs) do
            {:ok, _state} -> {:cont, {:ok, count + 1}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, _error} ->
        {:error, :git_baseline_unavailable}
    end
  end

  defp standard_ref?(%{name: "refs/heads/" <> _name}), do: true
  defp standard_ref?(%{name: "refs/tags/" <> _name}), do: true
  defp standard_ref?(_ref), do: false

  defp ref_kind("refs/heads/" <> _name), do: :branch
  defp ref_kind("refs/tags/" <> _name), do: :tag

  defp persist_ref_state(repo, attrs) do
    existing =
      repo.get_by(MirrorRefState,
        repository_mirror_id: attrs.repository_mirror_id,
        ref_name: attrs.ref_name
      )

    (existing || %MirrorRefState{})
    |> MirrorRefState.persistence_changeset(attrs)
    |> repo.insert_or_update()
  end

  defp make_buffered_deliveries_eligible(repo, organization_mirror, item, now) do
    {count, _rows} =
      repo.update_all(
        from(delivery in MirrorWebhookDelivery,
          where:
            delivery.organization_mirror_id == ^organization_mirror.id and
              delivery.github_repository_id == ^item.github_repository_id and
              delivery.state == :pending_unsupported and
              delivery.event in ^@supported_repository_events
        ),
        set: [state: :pending, next_attempt_at: now, failure_class: nil, updated_at: now]
      )

    {:ok, count}
  end

  defp record_reconciliation(repo, repository_mirror, item, now) do
    dedupe_key = "bootstrap-handoff:item:#{item.id}"

    case repo.get_by(MirrorOperation, dedupe_key: dedupe_key) do
      %MirrorOperation{} = operation ->
        {:ok, operation}

      nil ->
        %MirrorOperation{}
        |> MirrorOperation.enqueue_changeset(%{
          organization_mirror_id: repository_mirror.organization_mirror_id,
          repository_mirror_id: repository_mirror.id,
          kind: "reconcile.repository.bootstrap",
          dedupe_key: dedupe_key,
          cursor: %{
            "bootstrap_repository_item_id" => item.id,
            "baseline" => "seeded"
          },
          next_attempt_at: now
        })
        |> repo.insert()
    end
  end

  defp resource_local_version(%{sync_version: version}, _updated_at), do: version

  defp resource_local_version(%{id: id}, updated_at),
    do: max(DateTime.to_unix(updated_at, :microsecond), id)

  defp datetime_value(nil), do: nil
  defp datetime_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
