defmodule ForgeImports.GitHub.ReleaseAssets do
  @moduledoc false

  import Ecto.Query

  alias ForgeGitHub.{Error, ReleaseAssetClient}
  alias ForgeImports.{ImportRun, ObjectMapping, PageCheckpoint, RepositoryItem, ReportEntry}
  alias Fornacast.Repo

  @resource "release_assets_v1"
  @terminal "__terminal_v1__"
  @allow_test_callbacks Mix.env() == :test

  def stage(item, repository, checkout, opts) when is_function(checkout, 1) do
    with :ok <- heartbeat(opts),
         :ok <- import_mappings(item, repository, checkout, opts),
         :ok <- complete(item, opts) do
      :ok
    end
  end

  def initial_fence(item, repository) do
    fn repo ->
      observed_run = repo.get(ImportRun, item.import_run_id)

      actor =
        if observed_run do
          repo.one(
            from user in ForgeAccounts.User,
              where: user.id == ^observed_run.actor_user_id,
              lock: "FOR UPDATE"
          )
        end

      run =
        repo.one(from run in ImportRun, where: run.id == ^item.import_run_id, lock: "FOR UPDATE")

      current =
        repo.one(
          from candidate in RepositoryItem, where: candidate.id == ^item.id, lock: "FOR UPDATE"
        )

      stored = repo.get(ForgeRepos.Repository, repository.id)
      now = DateTime.utc_now(:second)

      lease_valid =
        if @allow_test_callbacks and is_nil(item.lease_owner) do
          current && current.state in [:git_staged, :staging_metadata]
        else
          (current && current.state == :staging_metadata) and
            current.lease_owner == item.lease_owner and is_binary(item.lease_owner) and
            is_struct(current.lease_expires_at, DateTime) and
            DateTime.compare(current.lease_expires_at, now) == :gt
        end

      # RepositoryWorker claims lock the actor before the run and item. Keep
      # the same order before recovery authorization rechecks those user rows.
      if actor && run && run.actor_user_id == actor.id && run.state == :running && lease_valid &&
           current.selected &&
           is_nil(current.cleanup_state) && current.hidden_repository_id == repository.id &&
           current.github_repository_id == item.github_repository_id &&
           current.source_full_name == item.source_full_name && stored &&
           stored.lifecycle == :importing && stored.generation == repository.generation &&
           is_nil(stored.deleted_at) do
        ForgeImports.CredentialProvider.authorize_recovery_locked(run, current)
      else
        {:error, :lost_lease}
      end
    end
  end

  defp import_mappings(item, repository, checkout, opts) do
    mappings =
      Repo.all(
        from mapping in ObjectMapping,
          where:
            mapping.hidden_repository_id == ^repository.id and
              mapping.github_repository_id == ^item.github_repository_id and
              mapping.object_kind == "release",
          order_by: mapping.github_object_id
      )

    Enum.reduce_while(mappings, :ok, fn mapping, :ok ->
      if complete_release?(item.id, mapping.github_object_id) do
        {:cont, :ok}
      else
        result =
          if get_in(mapping.source_evidence || %{}, ["asset_count"]) == 0 do
            complete_release(item, mapping, opts)
          else
            import_pages(item, repository, mapping, checkout, nil, opts)
          end

        case result do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, report_failure(item, mapping, normalize_reason(reason), opts)}
        end
      end
    end)
  end

  defp import_pages(
         item,
         repository,
         mapping,
         checkout,
         cursor,
         opts,
         count \\ 0,
         seen \\ MapSet.new()
       ) do
    [owner, name] = String.split(item.source_full_name, "/", parts: 2)
    client = client(opts)

    with :ok <- heartbeat(opts),
         {:ok, %{assets: assets, next_cursor: next_cursor}} <-
           checkout.(fn credential, metadata ->
             client.list_assets_page(
               credential,
               owner,
               name,
               mapping.github_object_id,
               cursor,
               client_options(opts, metadata)
             )
           end),
         {:ok, count, seen} <- inventory(assets, count, seen),
         :ok <- import_assets(item, repository, mapping, assets, checkout, owner, name, opts) do
      if next_cursor do
        import_pages(item, repository, mapping, checkout, next_cursor, opts, count, seen)
      else
        expected = get_in(mapping.source_evidence || %{}, ["asset_count"]) || 0

        if count >= expected,
          do: complete_release(item, mapping, opts),
          else: {:error, :release_asset_inventory_changed}
      end
    else
      {:error, %Error{kind: kind}} -> {:error, kind}
      {:error, _} = error -> error
    end
  end

  defp inventory(assets, count, seen) when is_list(assets) and length(assets) <= 100 do
    ids = Enum.map(assets, & &1["id"])
    all_ids = MapSet.union(seen, MapSet.new(ids))
    total = count + length(ids)

    if total <= 10_000 and MapSet.size(all_ids) == total,
      do: {:ok, total, all_ids},
      else: {:error, :invalid_release_asset_inventory}
  end

  defp inventory(_, _, _), do: {:error, :invalid_release_asset_inventory}

  defp import_assets(item, repository, mapping, assets, checkout, owner, name, opts) do
    Enum.reduce_while(assets, :ok, fn asset, :ok ->
      case import_asset(item, repository, mapping, asset, checkout, owner, name, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp import_asset(item, repository, mapping, asset, checkout, owner, name, opts) do
    with :ok <- heartbeat(opts),
         {:ok, uploader} <- observe_uploader(asset["uploader"], item.source_observed_at, opts),
         {:ok, created, 0} <- DateTime.from_iso8601(asset["created_at"]),
         {:ok, updated, 0} <- DateTime.from_iso8601(asset["updated_at"]) do
      attrs = %{
        name: asset["name"],
        label: asset["label"],
        content_type: asset["content_type"],
        size: asset["size"],
        source_digest: asset["digest"],
        source_asset_id: asset["id"],
        uploader_github_identity_id: uploader.id,
        source_download_count: asset["download_count"],
        inserted_at: DateTime.truncate(created, :second),
        updated_at: DateTime.truncate(updated, :second)
      }

      options =
        asset_options(opts)
        |> Keyword.put(
          :source_key,
          "github-import:#{repository.id}:#{item.github_repository_id}:asset:#{asset["id"]}"
        )
        |> Keyword.put(:fence, Keyword.fetch!(opts, :asset_fence))
        |> Keyword.put(:heartbeat, fn -> heartbeat(opts) end)
        |> Keyword.put(:publish, fn repo, local ->
          publish_mapping(repo, item, repository, mapping, asset, local)
        end)

      result =
        case ForgeReleases.resume_import_asset(
               repository,
               mapping.local_resource_id,
               attrs,
               options
             ) do
          :download ->
            consumer = fn reader, state ->
              ForgeReleases.import_asset(
                repository,
                mapping.local_resource_id,
                attrs,
                reader,
                state,
                options
              )
            end

            checkout.(fn credential, metadata ->
              client(opts).download(
                credential,
                owner,
                name,
                asset,
                consumer,
                client_options(opts, metadata)
              )
            end)

          result ->
            result
        end

      case result do
        {:ok, _asset} -> :ok
        {:error, %Error{kind: kind}} -> {:error, kind}
        {:error, _} = error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_release_asset}
    end
  end

  defp publish_mapping(repo, item, repository, release_mapping, source, local) do
    attrs = %{
      repository_item_id: item.id,
      hidden_repository_id: repository.id,
      github_repository_id: item.github_repository_id,
      object_kind: "release_asset",
      github_object_id: source["id"],
      local_resource_type: "ForgeReleases.Asset",
      local_resource_id: local.id,
      source_evidence: %{
        "v" => 1,
        "github_node_id" => source["node_id"],
        "release_id" => release_mapping.github_object_id
      }
    }

    with {:ok, _} <-
           repo.insert(ObjectMapping.create_changeset(%ObjectMapping{}, attrs),
             on_conflict: :nothing,
             conflict_target: [
               :hidden_repository_id,
               :github_repository_id,
               :object_kind,
               :github_object_id
             ]
           ),
         %ObjectMapping{local_resource_id: local_id} when local_id == local.id <-
           repo.get_by(ObjectMapping,
             hidden_repository_id: repository.id,
             github_repository_id: item.github_repository_id,
             object_kind: "release_asset",
             github_object_id: source["id"]
           ) do
      :ok
    else
      _ -> {:error, :asset_mapping_conflict}
    end
  end

  defp observe_uploader(%{"id" => id, "node_id" => node_id, "login" => login}, observed, opts) do
    Repo.transaction(fn ->
      case Keyword.fetch!(opts, :asset_fence).(Repo) do
        :ok ->
          existing = Repo.get_by(ForgeAccounts.GitHubIdentity, github_user_id: id)

          case ForgeAccounts.observe_github_identity(
                 %{
                   github_user_id: id,
                   github_node_id: node_id,
                   login: login,
                   avatar_url: existing && existing.avatar_url,
                   profile_url: existing && existing.profile_url
                 },
                 observed || DateTime.utc_now(:second)
               ) do
            {:ok, identity} -> identity
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp complete_release(item, mapping, opts) do
    transaction(opts, fn repo ->
      with :ok <- checkpoint(repo, item.id, "release:#{mapping.github_object_id}") do
        repo.update_all(
          from(report in ReportEntry,
            where:
              report.repository_item_id == ^item.id and
                report.source_object_id == ^mapping.github_object_id and
                report.classification == "unsupported_release_assets"
          ),
          set: [
            outcome: :imported,
            classification: "release_assets_imported",
            summary: "Release assets imported into local storage"
          ]
        )

        repo.update_all(
          from(report in ReportEntry,
            where:
              report.repository_item_id == ^item.id and
                report.source_object_id == ^mapping.github_object_id and
                report.classification == "release_asset_transfer_failed"
          ),
          set: [
            outcome: :imported,
            classification: "release_assets_recovered",
            summary: "Release assets imported after retry"
          ]
        )

        :ok
      end
    end)
  end

  defp complete(item, opts), do: transaction(opts, &checkpoint(&1, item.id, @terminal))

  defp checkpoint(repo, item_id, page_key) do
    changeset =
      PageCheckpoint.create_changeset(%PageCheckpoint{}, %{
        repository_item_id: item_id,
        resource_kind: @resource,
        page_key: page_key,
        item_count: 0,
        cursor_metadata: %{},
        committed_at: DateTime.utc_now(:second)
      })

    case repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:repository_item_id, :resource_kind, :page_key]
         ) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :checkpoint_failed}
    end
  end

  defp transaction(opts, fun) do
    case Repo.transaction(fn ->
           case Keyword.fetch!(opts, :asset_fence).(Repo) do
             :ok ->
               case fun.(Repo) do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  defp report_failure(item, mapping, reason, opts) do
    if reason not in [:lost_lease, :request_gate_busy] do
      transaction(opts, fn repo ->
        repo.insert(
          ReportEntry.create_changeset(%ReportEntry{}, %{
            import_run_id: item.import_run_id,
            repository_item_id: item.id,
            idempotency_key: "release-asset-failure-#{item.id}-#{mapping.github_object_id}",
            scope: :object,
            object_kind: "release",
            source_object_id: mapping.github_object_id,
            outcome: :failed,
            classification: "release_asset_transfer_failed",
            summary: "Release assets could not be imported",
            metadata: %{"phase" => @resource, "code" => to_string(reason)},
            source_count: 1
          }),
          on_conflict: :nothing,
          conflict_target: [:import_run_id, :idempotency_key]
        )

        :ok
      end)
    end

    {:error, reason}
  end

  defp complete_release?(item_id, release_id),
    do:
      Repo.exists?(
        from page in PageCheckpoint,
          where:
            page.repository_item_id == ^item_id and page.resource_kind == ^@resource and
              page.page_key == ^"release:#{release_id}"
      )

  defp heartbeat(opts), do: Keyword.get(opts, :heartbeat, fn -> :ok end).()
  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(%Error{kind: kind}), do: kind
  defp normalize_reason(_), do: :invalid_release_asset

  defp client(opts),
    do:
      if(@allow_test_callbacks,
        do: Keyword.get(opts, :asset_client, ReleaseAssetClient),
        else: ReleaseAssetClient
      )

  defp asset_options(opts),
    do:
      if(@allow_test_callbacks,
        do: Keyword.take(Keyword.get(opts, :asset_options, []), [:test_after_commit]),
        else: []
      )

  defp client_options(opts, metadata),
    do: Keyword.put(Keyword.get(opts, :client_options, []), :gate_key, metadata.gate_key)
end
