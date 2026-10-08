defmodule ForgeImports.GitHub.LFSImporter do
  @moduledoc false

  import Ecto.Query

  alias ForgeImports.{ImportRun, RepositoryItem}
  alias ForgeMirrors.{MirrorOperation, OrganizationMirror, RepositoryMirror}
  alias Fornacast.Repo
  alias GitLFS.PointerScanner
  alias GitLFS.PointerScanner.Scan

  @batch_limit 100
  @scan_expansions_per_advance 100
  @scan_time_budget_ms 250
  @lease_seconds 300
  @allow_test_callbacks Mix.env() == :test

  def advance(item, run, transfer, authorize, opts \\ [])

  def advance(%RepositoryItem{} = item, %ImportRun{} = run, transfer, authorize, opts)
      when is_function(transfer, 3) and is_function(authorize, 0) and is_list(opts) do
    with {:ok, callbacks} <- callbacks(opts),
         :ok <- authorize.(),
         {:ok, repository} <- importing_repository(item),
         mode <- import_mode(run),
         {:ok, result} <- advance(mode, item, repository, transfer, authorize, callbacks) do
      result
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_lfs_state}
    end
  rescue
    _ -> {:error, :invalid_lfs_state}
  catch
    _, _ -> {:error, :invalid_lfs_state}
  end

  def advance(_, _, _, _, _), do: {:error, :invalid_argument}

  def complete?(%RepositoryItem{} = item) do
    with {:ok, repository} <- importing_repository(item),
         %ImportRun{} = run <- Repo.get(ImportRun, item.import_run_id) do
      completion_valid?(import_mode(run), item, repository, run)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def complete?(_), do: false

  defp advance(:mirror_handoff, item, repository, _transfer, _authorize, _callbacks) do
    {:ok,
     {:complete,
      put_evidence(item, %{
        "status" => "mirror_handoff",
        "repository_generation" => repository.generation
      })}}
  end

  defp advance(:standalone, item, repository, transfer, authorize, callbacks) do
    with {:ok, refs} <- callbacks.list_refs.(ForgeRepos.absolute_storage_path(repository)),
         {:ok, baselines} <- baselines(refs),
         {:ok, %Scan{} = scan} <-
           callbacks.begin_scan.(
             repository,
             scan_key(item, repository),
             baselines,
             batch_limit: @batch_limit
           ),
         :ok <- authorize.() do
      advance_scan(
        item,
        repository,
        scan,
        matching_evidence(item, repository, scan),
        transfer,
        authorize,
        callbacks
      )
    end
  end

  defp scan_key(%RepositoryItem{predecessor_item_id: predecessor} = item, repository)
       when is_integer(predecessor) do
    evidence = get_in(item.checkpoint, ["lfs_import"]) || %{}
    key = evidence["scan_key"]

    with true <- is_binary(key),
         {:ok, scan} <- PointerScanner.resume_scan(repository, key),
         true <-
           scan.id == evidence["scan_id"] and
             scan.repository_generation == evidence["repository_generation"] and
             scan.baseline_fingerprint == evidence["baseline_fingerprint"] do
      key
    else
      _ -> "github-import:#{item.id}:#{item.attempt_count}"
    end
  end

  defp scan_key(item, _repository), do: "github-import:#{item.id}:#{item.attempt_count}"

  defp advance_scan(
         item,
         repository,
         %Scan{state: :scanning} = scan,
         evidence,
         transfer,
         authorize,
         callbacks
       ) do
    scan_batch(
      item,
      repository,
      scan,
      evidence,
      transfer,
      authorize,
      callbacks,
      @scan_expansions_per_advance,
      callbacks.monotonic_time.() + @scan_time_budget_ms
    )
  end

  defp advance_scan(
         item,
         repository,
         %Scan{state: state} = scan,
         evidence,
         transfer,
         authorize,
         callbacks
       )
       when state in [:complete, :prepared, :published] do
    cursor = evidence["object_cursor"]

    with :ok <- authorize.(),
         {:ok, %{objects: objects}} <-
           callbacks.list_requirements.(scan, after_oid: cursor, limit: 1) do
      if objects == [] and is_nil(cursor) do
        finish(item, repository, scan, authorize, callbacks)
      else
        case transfer.(repository, scan, cursor) do
          {:ok, nil} ->
            finish(item, repository, scan, authorize, callbacks)

          {:ok, next} when is_binary(next) ->
            {:ok,
             {:incomplete, put_evidence(item, scan_evidence(repository, scan, "transfer", next))}}

          {:error, %ForgeGitHub.Error{} = error} ->
            {:error, error}

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, :invalid_lfs_state}
        end
      end
    end
  end

  defp scan_batch(
         item,
         repository,
         scan,
         evidence,
         transfer,
         authorize,
         callbacks,
         remaining,
         deadline
       ) do
    owner = "github-import-lfs:#{item.id}:#{item.attempt_count}"

    case callbacks.claim_work.(scan, owner, limit: 1, lease_seconds: @lease_seconds) do
      {:ok, [work]} ->
        with :ok <- authorize.(),
             {:ok, expansion} <-
               expand_work(repository, scan, work, callbacks),
             :ok <- authorize.(),
             {:ok, %{scan: next_scan}} <- callbacks.record_expansion.(work, owner, expansion),
             :ok <- authorize.() do
          next_evidence = scan_evidence(repository, next_scan, "scan", nil)

          if next_scan.state == :scanning and remaining > 1 and
               callbacks.monotonic_time.() < deadline do
            scan_batch(
              item,
              repository,
              next_scan,
              next_evidence,
              transfer,
              authorize,
              callbacks,
              remaining - 1,
              deadline
            )
          else
            # Persist the scan identity before provider transfer can pause or fail.
            {:ok, {:incomplete, put_evidence(item, next_evidence)}}
          end
        end

      {:ok, []} ->
        with {:ok, resumed} <- callbacks.resume_scan.(repository, scan.scan_key) do
          if resumed.state == :scanning,
            do: {:ok, {:incomplete, put_evidence(item, evidence)}},
            else:
              advance_scan(item, repository, resumed, evidence, transfer, authorize, callbacks)
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_lfs_state}
    end
  end

  defp expand_work(repository, scan, work, callbacks) do
    case callbacks.cached_expansion.(scan, work) do
      {:ok, nil} ->
        callbacks.expand_object.(
          ForgeRepos.absolute_storage_path(repository),
          work.object_oid,
          work.object_kind,
          work.tree_offset,
          scan.batch_limit
        )

      {:ok, expansion} ->
        {:ok, expansion}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(item, repository, scan, authorize, callbacks) do
    with :ok <- authorize.(),
         {:ok, %Scan{state: :published} = published} <- callbacks.publish_scan.(scan),
         :ok <- authorize.() do
      {:ok,
       {:complete, put_evidence(item, scan_evidence(repository, published, "complete", nil))}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_lfs_state}
    end
  end

  defp completion_valid?(:standalone, item, repository, _run) do
    with %{} = evidence <- get_in(item.checkpoint || %{}, ["lfs_import"]),
         "complete" <- evidence["status"],
         true <- evidence["repository_generation"] == repository.generation,
         scan_id when is_integer(scan_id) <- evidence["scan_id"],
         %Scan{} = scan <- Repo.get(Scan, scan_id),
         true <-
           scan.repository_id == repository.id and
             scan.repository_generation == repository.generation,
         true <- scan.state == :published,
         true <- scan.scan_key == evidence["scan_key"],
         true <- scan.baseline_fingerprint == evidence["baseline_fingerprint"],
         {:ok, refs} <- GitCore.list_refs(ForgeRepos.absolute_storage_path(repository)),
         {:ok, baselines} <- baselines(refs),
         true <- baseline_fingerprint(baselines) == scan.baseline_fingerprint do
      true
    else
      _ -> false
    end
  end

  defp completion_valid?(:mirror_handoff, item, repository, run) do
    bootstrap_mirror?(run) and
      match?(
        %{
          "status" => "mirror_handoff",
          "repository_generation" => generation
        }
        when generation == repository.generation,
        get_in(item.checkpoint || %{}, ["lfs_import"])
      )
  end

  defp scan_evidence(repository, scan, status, cursor) do
    %{
      "status" => status,
      "repository_generation" => repository.generation,
      "scan_id" => scan.id,
      "scan_key" => scan.scan_key,
      "baseline_fingerprint" => scan.baseline_fingerprint,
      "object_cursor" => cursor
    }
  end

  defp matching_evidence(item, repository, scan) do
    case get_in(item.checkpoint || %{}, ["lfs_import"]) do
      %{
        "repository_generation" => generation,
        "scan_id" => id,
        "scan_key" => key,
        "baseline_fingerprint" => fingerprint
      } = evidence
      when generation == repository.generation and id == scan.id and key == scan.scan_key and
             fingerprint == scan.baseline_fingerprint ->
        evidence

      _ ->
        scan_evidence(repository, scan, "scan", nil)
    end
  end

  defp put_evidence(item, evidence),
    do: Map.put(item.checkpoint || %{}, "lfs_import", evidence)

  defp baselines(refs) when is_list(refs) do
    {:ok,
     refs
     |> Enum.filter(fn
       %{kind: :branch, name: "refs/heads/" <> suffix} -> suffix != ""
       %{kind: :tag, name: "refs/tags/" <> suffix} -> suffix != ""
       _ -> false
     end)
     |> Enum.map(&%{ref_name: &1.name, ref_kind: &1.kind, oid: &1.target})
     |> Enum.sort_by(& &1.ref_name)}
  end

  defp baselines(_), do: {:error, :invalid_lfs_state}

  defp baseline_fingerprint(baselines) do
    encoded =
      Enum.map_join(baselines, "\n", fn baseline ->
        "#{baseline.ref_kind}\0#{baseline.ref_name}\0#{baseline.oid}"
      end)

    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end

  defp importing_repository(%RepositoryItem{hidden_repository_id: id}) when is_integer(id) do
    ForgeRepos.fetch_importing_repository(id)
  end

  defp importing_repository(_), do: {:error, :stale_repository}

  defp import_mode(%ImportRun{} = run),
    do: if(bootstrap_mirror?(run), do: :mirror_handoff, else: :standalone)

  defp bootstrap_mirror?(%ImportRun{source_kind: :repository, mirror_operation_id: id} = run)
       when is_integer(id) do
    Repo.exists?(
      from operation in MirrorOperation,
        join: repository in RepositoryMirror,
        on: repository.id == operation.repository_mirror_id,
        join: mirror in OrganizationMirror,
        on: mirror.id == operation.organization_mirror_id,
        where:
          operation.id == ^id and operation.kind == "bootstrap.repository_import" and
            operation.state not in [:completed, :failed] and
            repository.github_repository_id == ^run.source_repository_github_id and
            mirror.github_account_id == ^run.source_owner_github_id and
            mirror.organization_id == ^run.destination_organization_id
    )
  end

  defp bootstrap_mirror?(%ImportRun{source_kind: :organization, id: id}) do
    Repo.exists?(
      from mirror in OrganizationMirror,
        where:
          mirror.bootstrap_import_run_id == ^id and mirror.provider == "github" and
            mirror.state != :revoked
    )
  end

  defp bootstrap_mirror?(_), do: false

  defp callbacks(opts) do
    allowed =
      ~w(begin_scan cached_expansion claim_work expand_object list_refs list_requirements monotonic_time publish_scan record_expansion resume_scan)a

    if Keyword.keyword?(opts) and (@allow_test_callbacks or opts == []) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      {:ok,
       %{
         begin_scan: callback(opts, :begin_scan, &PointerScanner.begin_scan/4),
         cached_expansion: callback(opts, :cached_expansion, &PointerScanner.cached_expansion/2),
         claim_work: callback(opts, :claim_work, &PointerScanner.claim_work/3),
         expand_object: callback(opts, :expand_object, &GitCore.expand_lfs_scan_object/5),
         list_refs: callback(opts, :list_refs, &GitCore.list_refs/1),
         list_requirements:
           callback(opts, :list_requirements, &PointerScanner.list_requirements/2),
         monotonic_time:
           callback(opts, :monotonic_time, fn -> System.monotonic_time(:millisecond) end),
         publish_scan: callback(opts, :publish_scan, &PointerScanner.publish_scan/1),
         record_expansion: callback(opts, :record_expansion, &PointerScanner.record_expansion/3),
         resume_scan: callback(opts, :resume_scan, &PointerScanner.resume_scan/2)
       }}
    else
      {:error, :invalid_argument}
    end
  end

  defp callback(opts, key, default) do
    case Keyword.get(opts, key, default) do
      fun when is_function(fun) -> fun
      _ -> raise ArgumentError, "invalid import LFS callback"
    end
  end
end
