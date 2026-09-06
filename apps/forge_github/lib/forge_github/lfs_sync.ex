defmodule ForgeGitHub.LFSSync do
  @moduledoc """
  Orders reachable Git LFS availability before one Git ref publication.

  Pointer traversal lives in a durable database queue. The mirror operation checkpoint only
  identifies that scan and its bounded transfer cursor; provider credentials and action URLs
  are never persisted.
  """

  alias ForgeGitHub.{Error, LFS.TransferCoordinator}
  alias ForgeMirrors.MirrorOperation
  alias ForgeRepos.Repository
  alias GitLFS.PointerScanner
  alias GitLFS.PointerScanner.Scan

  @scan_batch_limit 100
  @work_lease_seconds 300
  @oid_regex ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @allow_test_callbacks Mix.env() == :test

  @type direction :: :inbound | :outbound | :converge

  @doc "Ensures the target ref's complete history has LFS availability in its transfer direction."
  @spec ensure(MirrorOperation.t(), map(), direction(), String.t() | nil, binary(), map()) ::
          :ok | {:incomplete, map()} | {:error, term()}
  def ensure(operation, sync, direction, target_oid, token, request) do
    ensure(operation, sync, direction, target_oid, token, request, [])
  end

  @doc false
  def ensure(
        %MirrorOperation{} = operation,
        sync,
        direction,
        target_oid,
        token,
        _request,
        options
      )
      when is_map(sync) and direction in [:inbound, :outbound, :converge] and
             (is_nil(target_oid) or is_binary(target_oid)) and is_binary(token) and
             is_list(options) do
    with :ok <- validate_inputs(operation, sync, target_oid, token),
         {:ok, callbacks} <- callbacks(options),
         {:ok, %Repository{} = repository} <- callbacks.fetch_repository.(sync.repository_id),
         true <- repository.generation == sync.repository_generation,
         {:ok, refs} <- callbacks.list_refs.(sync.repository_path),
         {:ok, baselines} <- prospective_baselines(refs, sync, target_oid),
         fingerprint <- baseline_fingerprint(baselines),
         scan_key <- scan_key(operation, fingerprint),
         checkpoint <- matching_checkpoint(operation.checkpoint, fingerprint, direction),
         selected_key <- Map.get(checkpoint, "scan_key", scan_key),
         {:ok, %Scan{} = scan} <-
           callbacks.begin_scan.(repository, selected_key, baselines,
             batch_limit: @scan_batch_limit
           ) do
      advance(
        operation,
        sync,
        direction,
        token,
        repository,
        baselines,
        fingerprint,
        scan,
        checkpoint,
        callbacks
      )
    else
      false -> {:error, :stale_repository}
      {:error, reason} -> normalize_error(reason)
      _invalid -> {:error, :invalid_lfs_state}
    end
  rescue
    _exception -> {:error, :invalid_lfs_state}
  catch
    _kind, _reason -> {:error, :invalid_lfs_state}
  end

  def ensure(_operation, _sync, _direction, _target_oid, _token, _request, _options),
    do: {:error, :invalid_argument}

  defp advance(
         operation,
         _sync,
         direction,
         _token,
         _repository,
         _baselines,
         fingerprint,
         %Scan{state: state} = scan,
         _checkpoint,
         _callbacks
       )
       when state in [:prepared, :published] do
    retry_key = scan_key(operation, fingerprint) <> ":r#{scan.id}"
    {:incomplete, checkpoint(retry_key, fingerprint, direction, "scan", nil)}
  end

  defp advance(
         operation,
         sync,
         direction,
         token,
         repository,
         baselines,
         fingerprint,
         %Scan{state: :scanning} = scan,
         checkpoint,
         callbacks
       ) do
    owner = scan_owner(operation)

    case callbacks.claim_work.(scan, owner, limit: 1, lease_seconds: @work_lease_seconds) do
      {:ok, [work_item]} ->
        with {:ok, expansion} <-
               callbacks.expand_object.(
                 sync.repository_path,
                 work_item.object_oid,
                 work_item.object_kind,
                 work_item.tree_offset,
                 scan.batch_limit
               ),
             {:ok, %{scan: next_scan}} <-
               callbacks.record_expansion.(work_item, owner, expansion) do
          case next_scan.state do
            state when state in [:complete, :published] ->
              transfer(
                operation,
                sync,
                direction,
                token,
                repository,
                baselines,
                fingerprint,
                next_scan,
                checkpoint,
                callbacks
              )

            :scanning ->
              {:incomplete, checkpoint(next_scan.scan_key, fingerprint, direction, "scan", nil)}
          end
        else
          {:error, reason} -> normalize_error(reason)
          _invalid -> {:error, :invalid_lfs_state}
        end

      {:ok, []} ->
        case callbacks.resume_scan.(repository, scan.scan_key) do
          {:ok, %Scan{state: state} = resumed} when state in [:complete, :published] ->
            transfer(
              operation,
              sync,
              direction,
              token,
              repository,
              baselines,
              fingerprint,
              resumed,
              checkpoint,
              callbacks
            )

          {:ok, %Scan{state: :scanning}} ->
            {:incomplete, checkpoint(scan.scan_key, fingerprint, direction, "scan", nil)}

          {:error, reason} ->
            normalize_error(reason)

          _invalid ->
            {:error, :invalid_lfs_state}
        end

      {:error, reason} ->
        normalize_error(reason)

      _invalid ->
        {:error, :invalid_lfs_state}
    end
  end

  defp advance(
         operation,
         sync,
         direction,
         token,
         repository,
         baselines,
         fingerprint,
         %Scan{state: state} = scan,
         checkpoint,
         callbacks
       )
       when state in [:complete, :published] do
    transfer(
      operation,
      sync,
      direction,
      token,
      repository,
      baselines,
      fingerprint,
      scan,
      checkpoint,
      callbacks
    )
  end

  defp advance(
         _operation,
         _sync,
         _direction,
         _token,
         _repository,
         _baselines,
         _fingerprint,
         _scan,
         _checkpoint,
         _callbacks
       ),
       do: {:error, :invalid_lfs_state}

  defp transfer(
         operation,
         sync,
         direction,
         token,
         repository,
         _baselines,
         fingerprint,
         %Scan{state: state} = scan,
         checkpoint,
         callbacks
       )
       when state in [:complete, :published] do
    after_oid = Map.get(checkpoint, "requirement_cursor")

    options = [gate_key: {:github_installation, sync.github_installation_id}]

    case callbacks.transfer_page.(
           repository,
           scan,
           direction,
           token,
           sync.remote_owner,
           sync.remote_repository,
           after_oid,
           options
         ) do
      {:ok, nil} ->
        publish(operation, direction, fingerprint, scan, callbacks)

      {:ok, next_cursor} when is_binary(next_cursor) ->
        {:incomplete, checkpoint(scan.scan_key, fingerprint, direction, "transfer", next_cursor)}

      {:error, reason} ->
        normalize_error(reason)

      _invalid ->
        {:error, :invalid_lfs_state}
    end
  end

  defp publish(operation, direction, fingerprint, scan, callbacks) do
    case callbacks.publish_scan.(scan) do
      {:ok, %Scan{state: state}} when state in [:prepared, :published] ->
        :ok

      {:error, :superseded} ->
        retry_key = scan_key(operation, fingerprint) <> ":r#{scan.id}"
        {:incomplete, checkpoint(retry_key, fingerprint, direction, "scan", nil)}

      {:error, reason} ->
        normalize_error(reason)

      _invalid ->
        {:error, :invalid_lfs_state}
    end
  end

  defp prospective_baselines(refs, sync, target_oid) when is_list(refs) do
    # Each ref has its own operation and transfer direction. Other local refs may
    # still await outbound publication and therefore have no remote LFS proof yet.
    baselines = maybe_add_target([], sync, target_oid)

    if valid_baselines?(baselines), do: {:ok, baselines}, else: {:error, :invalid_ref}
  end

  defp prospective_baselines(_refs, _sync, _target_oid), do: {:error, :invalid_ref}

  defp maybe_add_target(baselines, _sync, nil), do: baselines

  defp maybe_add_target(baselines, sync, target_oid) do
    [
      %{ref_name: sync.ref_name, ref_kind: sync.ref_kind, oid: target_oid}
      | baselines
    ]
  end

  defp valid_baselines?(baselines) do
    names = Enum.map(baselines, & &1.ref_name)

    length(names) == length(Enum.uniq(names)) and
      Enum.all?(baselines, fn baseline ->
        valid_standard_ref?(baseline.ref_name, baseline.ref_kind) and
          is_binary(baseline.oid) and Regex.match?(@oid_regex, baseline.oid)
      end)
  end

  defp valid_standard_ref?("refs/heads/" <> suffix, :branch), do: suffix != ""
  defp valid_standard_ref?("refs/tags/" <> suffix, :tag), do: suffix != ""
  defp valid_standard_ref?(_ref, _kind), do: false

  defp baseline_fingerprint(baselines) do
    baselines
    |> Enum.map(fn baseline -> {baseline.ref_name, baseline.ref_kind, baseline.oid} end)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp scan_key(operation, fingerprint), do: "git-ref:#{operation.id}:#{fingerprint}"

  defp matching_checkpoint(checkpoint, fingerprint, direction) when is_map(checkpoint) do
    if checkpoint["baseline_fingerprint"] == fingerprint and
         checkpoint["direction"] == Atom.to_string(direction) and
         is_binary(checkpoint["scan_key"]) do
      checkpoint
    else
      %{}
    end
  end

  defp matching_checkpoint(_checkpoint, _fingerprint, _direction), do: %{}

  defp checkpoint(scan_key, fingerprint, direction, phase, cursor) do
    %{
      "baseline_fingerprint" => fingerprint,
      "direction" => Atom.to_string(direction),
      "phase" => phase,
      "requirement_cursor" => cursor,
      "scan_key" => scan_key
    }
  end

  defp scan_owner(operation) do
    "git-ref-lfs:#{operation.id}:#{operation.attempt_count}"
  end

  defp normalize_error(reason)
       when reason in [:candidate_size_mismatch, :pointer_size_mismatch],
       do: {:error, Error.new(:integrity_mismatch)}

  defp normalize_error(:requirements_unavailable),
    do: {:error, Error.new(:object_missing)}

  defp normalize_error(reason), do: {:error, reason}

  defp validate_inputs(operation, sync, target_oid, token) do
    valid_sync =
      is_integer(sync[:repository_id]) and sync.repository_id > 0 and
        is_integer(sync[:repository_generation]) and sync.repository_generation > 0 and
        is_integer(sync[:github_installation_id]) and sync.github_installation_id > 0 and
        is_binary(sync[:repository_path]) and sync.repository_path != "" and
        is_binary(sync[:remote_owner]) and sync.remote_owner != "" and
        is_binary(sync[:remote_repository]) and sync.remote_repository != "" and
        valid_standard_ref?(sync[:ref_name], sync[:ref_kind])

    valid_target = is_nil(target_oid) or Regex.match?(@oid_regex, target_oid)

    if is_integer(operation.id) and operation.id > 0 and valid_sync and valid_target and
         byte_size(token) in 1..16_384,
       do: :ok,
       else: {:error, :invalid_argument}
  end

  defp callbacks(options) do
    allowed = [
      :begin_scan,
      :claim_work,
      :expand_object,
      :fetch_repository,
      :list_refs,
      :publish_scan,
      :record_expansion,
      :resume_scan,
      :transfer_page
    ]

    if Keyword.keyword?(options) and
         (@allow_test_callbacks or Keyword.keys(options) == []) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      {:ok,
       %{
         begin_scan: callback(options, :begin_scan, &PointerScanner.begin_scan/4),
         claim_work: callback(options, :claim_work, &PointerScanner.claim_work/3),
         expand_object: callback(options, :expand_object, &GitCore.expand_lfs_scan_object/5),
         fetch_repository:
           callback(options, :fetch_repository, &ForgeRepos.fetch_live_repository/1),
         list_refs: callback(options, :list_refs, &GitCore.list_refs/1),
         # The prospective ref has not passed CAS yet. Retain old mappings across crashes
         # and concurrent ref writes; only fenced reachability reconciliation may prune.
         publish_scan: callback(options, :publish_scan, &PointerScanner.prepare_scan/1),
         record_expansion:
           callback(options, :record_expansion, &PointerScanner.record_expansion/3),
         resume_scan: callback(options, :resume_scan, &PointerScanner.resume_scan/2),
         transfer_page: callback(options, :transfer_page, &TransferCoordinator.process_page/8)
       }}
    else
      {:error, :invalid_argument}
    end
  end

  defp callback(options, key, default) do
    case Keyword.get(options, key, default) do
      function when is_function(function) -> function
      _invalid -> raise ArgumentError, "invalid Git LFS synchronization callback"
    end
  end
end
