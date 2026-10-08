defmodule ForgeImports.PatSyncProgress do
  @moduledoc false
  import Ecto.Query

  alias ForgeImports.{
    ImportRun,
    ObjectMapping,
    PageCheckpoint,
    RepositoryItem,
    RepositoryPublisher
  }

  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitLFS.PointerScanner.{Scan, WorkItem}

  def restore_ancestor_imports(job, run, progress, current_items) do
    with %ImportRun{} = current <- Repo.get(ImportRun, run.id),
         {:ok, lineage} <-
           matching_lineage(job, current, current.source_owner_github_id, MapSet.new()) do
      {:ok, restore_import_rows(job, current, lineage, progress, current_items)}
    else
      nil -> {:error, :import_unavailable}
      {:error, _} = error -> error
    end
  end

  defp restore_import_rows(job, run, lineage, progress, current_items) do
    current_ids = MapSet.new(current_items, &to_string(&1.id))

    retained =
      Map.reject(progress, fn {id, row} ->
        row["mode"] == "import" and not MapSet.member?(current_ids, id)
      end)

    represented =
      MapSet.new(
        Enum.map(current_items, & &1.github_repository_id) ++
          Enum.map(Map.values(retained), & &1["github_repository_id"])
      )

    ancestors = Enum.reject(lineage, &(&1.id == run.id))
    run_ids = Enum.map(ancestors, & &1.id)
    order = run_ids |> Enum.with_index() |> Map.new()

    Repo.all(
      from item in RepositoryItem,
        left_join: repository in Repository,
        on: repository.id == item.hidden_repository_id,
        where:
          item.import_run_id in ^run_ids and item.selected == true and
            item.state in [:published, :completed],
        select: {item, repository}
    )
    |> Enum.sort_by(fn {item, _repository} -> {order[item.import_run_id], item.id} end)
    |> Enum.reduce({retained, represented}, fn {item, repository}, {rows, seen} ->
      if not MapSet.member?(seen, item.github_repository_id) do
        valid? = valid_publication?(job, item, repository)

        row = %{
          "github_repository_id" => item.github_repository_id,
          "source_full_name" => item.source_full_name,
          "mode" => "import",
          "status" => if(valid?, do: "succeeded", else: "failed"),
          "error" => if(valid?, do: nil, else: "publication_inconsistent")
        }

        {Map.put(rows, to_string(item.id), row), MapSet.put(seen, item.github_repository_id)}
      else
        {rows, seen}
      end
    end)
    |> elem(0)
  end

  defp matching_lineage(job, %ImportRun{} = run, source_id, seen) do
    if not MapSet.member?(seen, run.id) and run.source_kind == :organization and
         run.actor_user_id == job.owner_user_id and
         run.github_identity_id == job.github_identity_id and
         run.destination_organization_id == job.organization_id and
         run.source_owner_login == job.github_organization and
         run.source_owner_github_id == source_id do
      if run.predecessor_run_id do
        with %ImportRun{} = predecessor <- Repo.get(ImportRun, run.predecessor_run_id),
             {:ok, ancestors} <-
               matching_lineage(job, predecessor, source_id, MapSet.put(seen, run.id)) do
          {:ok, [run | ancestors]}
        else
          nil -> {:error, :invalid_import_lineage}
          {:error, _} = error -> error
        end
      else
        {:ok, [run]}
      end
    else
      {:error, :invalid_import_lineage}
    end
  end

  defp matching_lineage(_job, _run, _source_id, _seen), do: {:error, :invalid_import_lineage}

  defp valid_publication?(job, item, %Repository{} = repository) do
    evidence = item.publication_evidence

    RepositoryPublisher.valid_committed_evidence?(evidence, %{
      item_id: item.id,
      hidden_repository_id: item.hidden_repository_id
    }) and
      evidence["run_id"] == item.import_run_id and
      evidence["attempt_number"] == item.attempt_count and
      item.destination_owner_id == job.organization_id and
      item.source_full_name == "#{job.github_organization}/#{item.source_name}" and
      repository.owner_user_id == job.organization_id and
      evidence["owner_user_id"] == job.organization_id and
      repository.generation == evidence["generation"] and repository.slug == evidence["slug"] and
      repository.slug == item.destination_slug and
      repository.lifecycle in [:ready, :synchronizing] and
      is_nil(repository.deleted_at) and is_nil(repository.storage_reclaimed_at)
  end

  defp valid_publication?(_job, _item, _repository), do: false

  def snapshots(items) do
    ids = Enum.map(items, & &1.id)

    releases =
      Repo.all(
        from m in ObjectMapping,
          where: m.repository_item_id in ^ids and m.object_kind == "release",
          group_by: m.repository_item_id,
          select:
            {m.repository_item_id,
             sum(fragment("COALESCE((?->>'asset_count')::integer, 0)", m.source_evidence))}
      )
      |> Map.new()

    assets =
      Repo.all(
        from m in ObjectMapping,
          where: m.repository_item_id in ^ids and m.object_kind == "release_asset",
          group_by: m.repository_item_id,
          select: {m.repository_item_id, count(m.id)}
      )
      |> Map.new()

    pages =
      Repo.all(
        from p in PageCheckpoint,
          where: p.repository_item_id in ^ids,
          group_by: p.repository_item_id,
          select: {p.repository_item_id, count(p.id)}
      )
      |> Map.new()

    scan_ids =
      for item <- items,
          scan_id = get_in(item.checkpoint, ["lfs_import", "scan_id"]),
          is_integer(scan_id),
          do: scan_id

    scans =
      Repo.all(
        from w in WorkItem,
          join: s in Scan,
          on: s.id == w.scan_id,
          where: s.id in ^scan_ids,
          group_by: [s.id, s.repository_id],
          select: {s.id, s.repository_id, filter(count(w.id), w.state == :done), count(w.id)}
      )
      |> Map.new(fn {id, repository_id, done, total} -> {id, {repository_id, done, total}} end)

    Map.new(items, fn item ->
      scan_id = get_in(item.checkpoint, ["lfs_import", "scan_id"])

      progress =
        cond do
          get_in(item.checkpoint, ["lfs_import", "status"]) == "scan" and
              match?(
                {repository_id, _, _} when repository_id == item.hidden_repository_id,
                scans[scan_id]
              ) ->
            {_, done, total} = scans[scan_id]
            %{"phase" => "lfs_scan", "completed" => done, "total" => total}

          Map.get(releases, item.id, 0) > 0 ->
            %{
              "phase" => "release_assets",
              "completed" => Map.get(assets, item.id, 0),
              "total" => releases[item.id]
            }

          item.state in [:git_staged, :staging_metadata, :ready_to_publish] ->
            %{"phase" => "metadata", "completed" => Map.get(pages, item.id, 0)}

          true ->
            %{}
        end

      {item.id, progress}
    end)
  end
end
