defmodule ForgeGitHub.LFSReconciliation do
  @moduledoc "Bounded authoritative LFS reachability reconciliation after per-ref transfer."

  alias Fornacast.Repo
  alias GitLFS.PointerScanner

  @test_callbacks Mix.env() == :test

  def run(operation, sync, finalize, options \\ []) do
    if @test_callbacks or options == [] do
      with {:ok, repository} <- ForgeRepos.fetch_live_repository(sync.repository_id),
           true <- repository.generation == sync.repository_generation,
           {:ok, baselines} <- baselines(sync.repository_path),
           :ok <- confirmed_baselines(baselines, sync),
           fingerprint <- fingerprint(baselines),
           checkpoint <- matching_checkpoint(operation.checkpoint, fingerprint),
           key <- checkpoint["scan_key"] || "lfs-reconcile:#{operation.id}:#{fingerprint}",
           {:ok, scan} <- PointerScanner.begin_scan(repository, key, baselines, batch_limit: 100) do
        advance(operation, sync, repository, scan, fingerprint, checkpoint, finalize, options)
      else
        false -> {:error, :stale_repository}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_argument}
    end
    |> normalize_result()
  end

  defp normalize_result({:error, reason})
       when reason in [:pointer_size_mismatch, :candidate_size_mismatch],
       do: {:error, :lfs_integrity}

  defp normalize_result({:error, :requirements_unavailable}), do: {:error, :lfs_missing}
  defp normalize_result(result), do: result

  defp advance(
         operation,
         sync,
         _repository,
         %{state: :scanning} = scan,
         fingerprint,
         _checkpoint,
         _finalize,
         _options
       ) do
    owner = "lfs-reconcile:#{operation.id}:#{operation.attempt_count}"

    with {:ok, work} <- PointerScanner.claim_work(scan, owner, limit: 1, lease_seconds: 300),
         :ok <- expand(work, owner, sync.repository_path, scan.batch_limit) do
      {:incomplete, checkpoint(scan.scan_key, fingerprint, nil)}
    end
  end

  defp advance(
         _operation,
         _sync,
         _repository,
         %{state: :published} = scan,
         fingerprint,
         _checkpoint,
         _finalize,
         _options
       ) do
    restart(scan, fingerprint)
  end

  defp advance(operation, sync, repository, scan, fingerprint, checkpoint, finalize, options) do
    with {:ok, %{objects: objects, next_cursor: cursor}} <-
           PointerScanner.list_requirements(scan, after_oid: checkpoint["after_oid"], limit: 100),
         :ok <- verify_objects(repository, objects) do
      if cursor do
        {:incomplete, checkpoint(scan.scan_key, fingerprint, cursor)}
      else
        publish(operation, sync, scan, fingerprint, finalize, options)
      end
    end
  end

  defp expand([], _owner, _path, _limit), do: :ok

  defp expand([work], owner, path, limit) do
    with {:ok, expansion} <-
           GitCore.expand_lfs_scan_object(
             path,
             work.object_oid,
             work.object_kind,
             work.tree_offset,
             limit
           ),
         {:ok, _result} <- PointerScanner.record_expansion(work, owner, expansion),
         do: :ok
  end

  defp verify_objects(repository, objects) do
    Enum.reduce_while(objects, :ok, fn object, :ok ->
      case GitLFS.verify_object(repository, object.oid, object.size) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:halt, {:error, :lfs_missing}}
        {:error, _reason} -> {:halt, {:error, :lfs_integrity}}
      end
    end)
  end

  defp publish(operation, sync, scan, fingerprint, finalize, options) do
    Keyword.get(options, :before_publish, fn -> :ok end).()
    deadline = System.monotonic_time(:millisecond) + GitCore.Limits.get(:ref_deadline_ms)

    with {:ok, lease} <- GitCore.RepositoryWriteLimiter.acquire(sync.repository_id, deadline) do
      try do
        context = Keyword.get(options, :context, &ForgeMirrors.git_repository_operation_context/1)

        with {:ok, current} <- baselines(sync.repository_path),
             true <- fingerprint(current) == fingerprint,
             {:ok, fresh_sync} <- context.(operation),
             true <- fresh_sync.repository_generation == sync.repository_generation,
             :ok <- confirmed_baselines(current, fresh_sync) do
          Repo.transaction(fn ->
            with {:ok, _published} <- PointerScanner.publish_scan(scan) do
              case finalize.() do
                {:error, reason} -> Repo.rollback(reason)
                result -> result
              end
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
          |> case do
            {:ok, result} -> result
            {:error, :superseded} -> restart(scan, fingerprint)
            {:error, reason} -> {:error, reason}
          end
        else
          false -> restart(scan, fingerprint)
          {:error, reason} -> {:error, reason}
        end
      after
        :ok = GitCore.RepositoryWriteLimiter.release(lease)
      end
    end
  end

  defp baselines(path) do
    with {:ok, refs} <- GitCore.list_refs(path) do
      {:ok,
       refs
       |> Enum.flat_map(fn
         %{name: "refs/heads/" <> _ = name, target: oid} ->
           [%{ref_name: name, ref_kind: :branch, oid: oid}]

         %{name: "refs/tags/" <> _ = name, target: oid} ->
           [%{ref_name: name, ref_kind: :tag, oid: oid}]

         _other ->
           []
       end)
       |> Enum.sort_by(& &1.ref_name)}
    end
  end

  defp confirmed_baselines(baselines, sync) do
    actual = Map.new(baselines, &{&1.ref_name, &1.oid})
    if actual == sync.confirmed_ref_oids, do: :ok, else: {:error, :bootstrap_refs_unconfirmed}
  end

  defp fingerprint(baselines),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(baselines)) |> Base.encode16(case: :lower)

  defp matching_checkpoint(%{"fingerprint" => fingerprint} = checkpoint, fingerprint),
    do: checkpoint

  defp matching_checkpoint(_checkpoint, _fingerprint), do: %{}

  defp checkpoint(key, fingerprint, cursor),
    do: %{"scan_key" => key, "fingerprint" => fingerprint, "after_oid" => cursor}

  defp restart(scan, fingerprint) do
    key = scan.scan_key |> String.split(":r", parts: 2) |> hd()
    {:incomplete, checkpoint(key <> ":r#{scan.id}", fingerprint, nil)}
  end
end
