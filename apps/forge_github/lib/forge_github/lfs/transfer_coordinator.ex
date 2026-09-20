defmodule ForgeGitHub.LFS.TransferCoordinator do
  @moduledoc "Coordinates one bounded page of provider and local LFS object availability."

  alias ForgeGitHub.{Error, LFS, RepositoryReference}
  alias ForgeGitHub.LFS.{Action, Object}
  alias ForgeRepos.Repository
  alias GitLFS.PointerScanner
  alias GitLFS.PointerScanner.Scan

  @page_limit 100
  @maximum_object_size 9_223_372_036_854_775_807
  @oid_regex ~r/\A[0-9a-f]{64}\z/
  @allow_test_callbacks Mix.env() == :test

  @type direction :: :inbound | :outbound | :converge
  @type option ::
          {:gate_key, {:github_installation | :saved_credential | :one_time_run, pos_integer()}}
          | {:authorize, (-> :ok | {:error, term()})}

  @doc """
  Synchronizes one completed pointer-scan page without advancing its cursor on failure.

  Requires a GitHub installation, saved credential, or one-time import run `gate_key`
  so every Batch request is serialized with other requests using that credential identity.
  Trusted callers may supply a runtime `authorize` callback returning `:ok` or an error.
  It is checked before every new provider request; it does not abort an in-flight request.
  """
  @spec process_page(
          Repository.t(),
          Scan.t(),
          direction(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          [option()]
        ) :: {:ok, String.t() | nil} | {:error, term()}
  def process_page(
        repository,
        scan,
        direction,
        token,
        remote_owner,
        remote_repository,
        after_oid,
        options \\ []
      )

  def process_page(
        %Repository{} = repository,
        %Scan{} = scan,
        direction,
        token,
        remote_owner,
        remote_repository,
        after_oid,
        options
      )
      when direction in [:inbound, :outbound, :converge] and is_binary(token) and
             is_binary(remote_owner) and is_binary(remote_repository) and is_list(options) do
    with :ok <- validate_capabilities(repository, scan),
         :ok <- validate_remote(token, remote_owner, remote_repository),
         :ok <- validate_after_oid(after_oid),
         {:ok, gate_key, callbacks} <- coordinator_options(options),
         :ok <- authorize!(callbacks),
         {:ok, page} <-
           call(callbacks.list_requirements, [
             scan,
             [after_oid: after_oid, limit: @page_limit]
           ]),
         {:ok, requirements, next_cursor} <- validate_page(page),
         :ok <-
           synchronize_with_refresh(
             direction,
             repository,
             requirements,
             token,
             remote_owner,
             remote_repository,
             gate_key,
             callbacks,
             0
           ) do
      {:ok, next_cursor}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> local_error(reason)
      _invalid -> error(:invalid_request)
    end
  catch
    {:lfs_authorization, reason} -> {:error, reason}
  end

  def process_page(
        _repository,
        _scan,
        _direction,
        _token,
        _remote_owner,
        _remote_repository,
        _after_oid,
        _options
      ),
      do: error(:invalid_request)

  defp synchronize_with_refresh(
         direction,
         repository,
         requirements,
         token,
         remote_owner,
         remote_repository,
         gate_key,
         callbacks,
         refresh_count
       ) do
    result =
      synchronize(
        direction,
        repository,
        requirements,
        token,
        remote_owner,
        remote_repository,
        gate_key,
        callbacks
      )

    case result do
      {:error, %Error{kind: :action_expired}} when refresh_count == 0 ->
        synchronize_with_refresh(
          direction,
          repository,
          requirements,
          token,
          remote_owner,
          remote_repository,
          gate_key,
          callbacks,
          1
        )

      other ->
        other
    end
  end

  defp synchronize(
         _direction,
         _repository,
         [],
         _token,
         _owner,
         _remote,
         _gate_key,
         _callbacks
       ),
       do: :ok

  defp synchronize(
         :inbound,
         repository,
         requirements,
         token,
         owner,
         remote,
         gate_key,
         callbacks
       ) do
    with {:ok, pairs} <-
           remote_pairs(:download, requirements, token, owner, remote, gate_key, callbacks) do
      reduce_pairs(pairs, fn requirement, remote_object ->
        synchronize_inbound(repository, requirement, remote_object, callbacks)
      end)
    end
  end

  defp synchronize(
         :outbound,
         repository,
         requirements,
         token,
         owner,
         remote,
         gate_key,
         callbacks
       ) do
    with :ok <- reduce_requirements(requirements, &ensure_local_ready(repository, &1, callbacks)),
         {:ok, pairs} <-
           remote_pairs(:upload, requirements, token, owner, remote, gate_key, callbacks) do
      reduce_pairs(pairs, fn requirement, remote_object ->
        synchronize_outbound(repository, requirement, remote_object, callbacks)
      end)
    end
  end

  defp synchronize(
         :converge,
         repository,
         requirements,
         token,
         owner,
         remote,
         gate_key,
         callbacks
       ) do
    with {:ok, outbound, inbound} <- partition_converge(repository, requirements, callbacks),
         :ok <-
           synchronize(
             :outbound,
             repository,
             outbound,
             token,
             owner,
             remote,
             gate_key,
             callbacks
           ),
         :ok <-
           synchronize(
             :inbound,
             repository,
             inbound,
             token,
             owner,
             remote,
             gate_key,
             callbacks
           ) do
      :ok
    end
  end

  defp remote_pairs(operation, requirements, token, owner, remote, gate_key, callbacks) do
    objects = Enum.map(requirements, &Map.take(&1, [:oid, :size]))
    options = [gate_key: gate_key]

    options =
      case callbacks.authorize do
        :error -> options
        {:ok, authorize} -> Keyword.put(options, :authorize, authorize)
      end

    with {:ok, remote_objects} <-
           guarded_call(callbacks, :batch, [token, owner, remote, operation, objects, options]),
         true <- is_list(remote_objects) and length(remote_objects) == length(requirements),
         {:ok, remote_by_oid} <- validate_remote_objects(remote_objects, operation, objects) do
      {:ok, Enum.map(requirements, &{&1, Map.fetch!(remote_by_oid, &1.oid)})}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> throw({:lfs_authorization, reason})
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp validate_remote_objects(remote_objects, operation, requested) do
    requested_by_oid = Map.new(requested, &{&1.oid, &1})

    Enum.reduce_while(remote_objects, {:ok, %{}}, fn
      %Object{oid: oid, size: size, actions: actions, error: nil} = object, {:ok, acc} ->
        valid_action =
          case operation do
            :download -> match?(%Action{operation: :download}, actions[:download])
            :upload -> valid_upload_actions?(actions)
          end

        if match?(%{size: ^size}, requested_by_oid[oid]) and valid_action and
             not Map.has_key?(acc, oid) do
          {:cont, {:ok, Map.put(acc, oid, object)}}
        else
          {:halt, error(:invalid_lfs_response)}
        end

      %Object{error: %Error{} = error}, {:ok, _acc} ->
        {:halt, {:error, error}}

      _invalid, {:ok, _acc} ->
        {:halt, error(:invalid_lfs_response)}
    end)
    |> case do
      {:ok, values} when map_size(values) == map_size(requested_by_oid) -> {:ok, values}
      {:ok, _values} -> error(:invalid_lfs_response)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp valid_upload_actions?(actions) when is_map(actions) do
    case actions do
      actions when map_size(actions) == 0 ->
        true

      %{upload: %Action{operation: :upload}} ->
        map_size(actions) == 1 or
          (map_size(actions) == 2 and match?(%Action{operation: :verify}, actions[:verify]))

      _invalid ->
        false
    end
  end

  defp valid_upload_actions?(_actions), do: false

  defp synchronize_inbound(repository, requirement, remote_object, callbacks) do
    with %Action{} = action <- remote_object.actions[:download] do
      case call(callbacks.verify_local, [repository, requirement.oid, requirement.size]) do
        :ok ->
          :ok

        {:error, :not_found} ->
          attach_or_download(repository, requirement, action, callbacks)

        {:error, reason} ->
          local_error(reason)

        _invalid ->
          error(:local_storage)
      end
    else
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp attach_or_download(repository, requirement, action, callbacks) do
    case call(callbacks.ensure_local, [
           repository,
           requirement.oid,
           requirement.size,
           requirement.first_seen_ref
         ]) do
      :ok ->
        verify_attached(repository, requirement, callbacks)

      {:error, :not_found} ->
        download_under_lock(repository, requirement, action, callbacks)

      {:error, reason} ->
        local_error(reason)

      _invalid ->
        error(:local_storage)
    end
  end

  defp verify_attached(repository, requirement, callbacks) do
    case call(callbacks.verify_local, [repository, requirement.oid, requirement.size]) do
      :ok -> :ok
      {:error, reason} -> local_error(reason)
      _invalid -> error(:local_storage)
    end
  end

  defp download_under_lock(repository, requirement, action, callbacks) do
    case call(callbacks.with_upload_lock, [
           repository,
           requirement.oid,
           fn ->
             download_locked(repository, requirement, action, callbacks)
           end
         ]) do
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> local_error(reason)
      _invalid -> error(:local_storage)
    end
  end

  defp download_locked(repository, requirement, action, callbacks) do
    case call(callbacks.verify_local, [repository, requirement.oid, requirement.size]) do
      :ok ->
        :ok

      {:error, :not_found} ->
        reserve_and_download(repository, requirement, action, callbacks)

      {:error, reason} ->
        local_error(reason)

      _invalid ->
        error(:local_storage)
    end
  end

  defp reserve_and_download(repository, requirement, action, callbacks) do
    case call(callbacks.reserve_upload, [repository, requirement.oid, requirement.size]) do
      {:ok, :already_present} ->
        verify_attached(repository, requirement, callbacks)

      {:ok, reservation} ->
        recover_or_download(reservation, requirement, action, callbacks)

      {:error, reason} ->
        local_error(reason)

      _invalid ->
        error(:local_storage)
    end
  end

  defp recover_or_download(reservation, requirement, action, callbacks) do
    case call(callbacks.recover_upload, [reservation]) do
      {:ok, staged} ->
        commit_download(staged, requirement.first_seen_ref, callbacks)

      {:error, :not_found} ->
        stream_download(reservation, requirement, action, callbacks)

      {:error, reason} when reason in [:integrity_mismatch, :invalid_source] ->
        with :ok <- cleanup_staging(reservation, callbacks) do
          stream_download(reservation, requirement, action, callbacks)
        end

      {:error, reason} ->
        local_error(reason)

      _invalid ->
        error(:local_storage)
    end
  end

  defp cleanup_staging(reservation, callbacks) do
    case call(callbacks.cleanup_upload, [reservation]) do
      :ok -> :ok
      {:error, reason} -> local_error(reason)
      _invalid -> error(:local_storage)
    end
  end

  defp stream_download(reservation, requirement, action, callbacks) do
    consumer = fn reader, source -> callbacks.stage_upload.(reservation, reader, source) end

    case guarded_call(callbacks, :consume_download, [action, requirement, consumer, []]) do
      {:ok, staged} ->
        commit_download(staged, requirement.first_seen_ref, callbacks)

      {:error, %Error{kind: :sink}, reason} ->
        local_error(reason)

      {:error, %Error{} = error, _reason} ->
        {:error, error}

      {:error, %Error{} = error} ->
        {:error, error}

      _invalid ->
        error(:local_storage)
    end
  end

  defp commit_download(staged, first_seen_ref, callbacks) do
    case call(callbacks.commit_download, [staged, first_seen_ref]) do
      {:ok, _object} -> :ok
      {:error, reason} -> local_error(reason)
      _invalid -> error(:local_storage)
    end
  end

  defp ensure_local_ready(repository, requirement, callbacks) do
    case call(callbacks.verify_local, [repository, requirement.oid, requirement.size]) do
      :ok ->
        :ok

      {:error, reason} ->
        local_error(reason)

      _invalid ->
        error(:local_storage)
    end
  end

  defp synchronize_outbound(repository, requirement, remote_object, callbacks) do
    case remote_object.actions do
      actions when map_size(actions) == 0 ->
        :ok

      %{upload: %Action{} = upload_action} = actions ->
        upload_local(repository, requirement, upload_action, actions[:verify], callbacks)

      _invalid ->
        error(:invalid_lfs_response)
    end
  end

  defp upload_local(repository, requirement, upload_action, verify_action, callbacks) do
    case call(callbacks.open_local, [repository, requirement.oid, requirement.size, :all]) do
      {:ok, source, %{size: size}} when size == requirement.size ->
        upload_open_source(source, requirement, upload_action, verify_action, callbacks)

      {:ok, source, _metadata} ->
        _ = close_local(source, callbacks)
        error(:integrity_mismatch)

      {:error, reason} ->
        local_error(reason)

      _invalid ->
        error(:local_storage)
    end
  end

  defp upload_open_source(source, requirement, upload_action, verify_action, callbacks) do
    reader = fn length, current_source ->
      case callbacks.read_local.(current_source, length) do
        {:ok, chunk, next_source} -> {:ok, chunk, next_source}
        :eof -> {:eof, current_source}
        {:error, _reason} -> {:error, :source, current_source}
        _invalid -> {:error, :source, current_source}
      end
    end

    result =
      try do
        guarded_call(callbacks, :upload, [upload_action, requirement, reader, source, []])
      catch
        {:lfs_authorization, _reason} = denied ->
          _ = close_local(source, callbacks)
          throw(denied)
      end

    case result do
      {:ok, final_source} ->
        with :ok <- close_local(final_source, callbacks),
             :ok <- verify_remote(verify_action, requirement, callbacks) do
          :ok
        end

      {:error, %Error{} = error, final_source} ->
        _ = close_local(final_source, callbacks)
        {:error, error}

      {:error, %Error{} = error} ->
        _ = close_local(source, callbacks)
        {:error, error}

      _invalid ->
        _ = close_local(source, callbacks)
        error(:local_storage)
    end
  end

  defp close_local(source, callbacks) do
    case call(callbacks.close_local, [source]) do
      :ok -> :ok
      _error -> error(:local_storage)
    end
  end

  defp verify_remote(nil, _requirement, _callbacks), do: :ok

  defp verify_remote(%Action{} = action, requirement, callbacks) do
    case guarded_call(callbacks, :verify_remote, [action, requirement, []]) do
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> error(:invalid_lfs_response)
    end
  end

  defp partition_converge(repository, requirements, callbacks) do
    Enum.reduce_while(requirements, {:ok, [], []}, fn requirement, {:ok, outbound, inbound} ->
      case converge_direction(repository, requirement, callbacks) do
        {:ok, :outbound} -> {:cont, {:ok, [requirement | outbound], inbound}}
        {:ok, :inbound} -> {:cont, {:ok, outbound, [requirement | inbound]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, outbound, inbound} -> {:ok, Enum.reverse(outbound), Enum.reverse(inbound)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp converge_direction(repository, requirement, callbacks) do
    case call(callbacks.verify_local, [repository, requirement.oid, requirement.size]) do
      :ok ->
        {:ok, :outbound}

      {:error, :not_found} ->
        # A pointer is not proof of access to another repository's global bytes.
        # Inbound Batch proof must precede any shared-object adoption.
        {:ok, :inbound}

      {:error, reason} ->
        local_error(reason)

      _invalid ->
        error(:local_storage)
    end
  end

  defp reduce_requirements(requirements, function) do
    Enum.reduce_while(requirements, :ok, fn requirement, :ok ->
      case function.(requirement) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp reduce_pairs(pairs, function) do
    Enum.reduce_while(pairs, :ok, fn {requirement, remote_object}, :ok ->
      case function.(requirement, remote_object) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_capabilities(repository, scan) do
    if is_integer(repository.id) and repository.id > 0 and is_integer(repository.generation) and
         repository.generation > 0 and scan.repository_id == repository.id and
         scan.repository_generation == repository.generation and
         scan.state in [:complete, :prepared, :published],
       do: :ok,
       else: :error
  end

  defp validate_remote(token, owner, remote) do
    if byte_size(token) in 1..16_384 and String.valid?(token) and
         :binary.match(token, <<0>>) == :nomatch and RepositoryReference.valid_owner?(owner) and
         RepositoryReference.valid_repository?(remote),
       do: :ok,
       else: :error
  end

  defp validate_after_oid(nil), do: :ok

  defp validate_after_oid(after_oid) when is_binary(after_oid) do
    if Regex.match?(@oid_regex, after_oid), do: :ok, else: :error
  end

  defp validate_after_oid(_after_oid), do: :error

  defp validate_page(%{objects: objects, next_cursor: next_cursor})
       when is_list(objects) and length(objects) <= @page_limit do
    with {:ok, requirements} <- validate_requirements(objects),
         :ok <- validate_next_cursor(next_cursor, requirements) do
      {:ok, requirements, next_cursor}
    end
  end

  defp validate_page(_page), do: error(:invalid_lfs_response)

  defp validate_requirements(objects) do
    Enum.reduce_while(objects, {:ok, [], MapSet.new()}, fn
      %{oid: oid, size: size, first_seen_ref: first_seen_ref} = object, {:ok, acc, seen}
      when is_binary(oid) and is_integer(size) and size in 0..@maximum_object_size and
             is_binary(first_seen_ref) and byte_size(first_seen_ref) in 1..1_024 ->
        if Regex.match?(@oid_regex, oid) and valid_first_seen_ref?(first_seen_ref) and
             not MapSet.member?(seen, oid) do
          requirement = Map.take(object, [:oid, :size, :first_seen_ref])
          {:cont, {:ok, [requirement | acc], MapSet.put(seen, oid)}}
        else
          {:halt, error(:invalid_lfs_response)}
        end

      _invalid, _state ->
        {:halt, error(:invalid_lfs_response)}
    end)
    |> case do
      {:ok, requirements, _seen} -> {:ok, Enum.reverse(requirements)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp valid_first_seen_ref?(ref) do
    (String.starts_with?(ref, "refs/heads/") or String.starts_with?(ref, "refs/tags/")) and
      String.valid?(ref) and :binary.match(ref, <<0>>) == :nomatch
  end

  defp validate_next_cursor(nil, _requirements), do: :ok

  defp validate_next_cursor(next_cursor, requirements) when is_binary(next_cursor) do
    case List.last(requirements) do
      %{oid: ^next_cursor} -> :ok
      _invalid -> :error
    end
  end

  defp validate_next_cursor(_next_cursor, _requirements), do: :error

  if @allow_test_callbacks do
    defp coordinator_options(options) when is_list(options) do
      with true <- Keyword.keyword?(options),
           [] <- Keyword.keys(options) -- [:gate_key, :callbacks, :authorize],
           true <- length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))),
           {:ok, gate_key} <- Keyword.fetch(options, :gate_key),
           true <- valid_gate_key?(gate_key),
           overrides <- Keyword.get(options, :callbacks, %{}),
           true <- is_map(overrides),
           callbacks <- Map.merge(default_callbacks(), overrides),
           true <- valid_callbacks?(callbacks) do
        {:ok, gate_key, Map.put(callbacks, :authorize, Keyword.fetch(options, :authorize))}
      else
        _invalid -> error(:invalid_request)
      end
    end
  else
    defp coordinator_options(options) when is_list(options) do
      with true <- Keyword.keyword?(options),
           [] <- Keyword.keys(options) -- [:gate_key, :authorize],
           true <- length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))),
           {:ok, gate_key} <- Keyword.fetch(options, :gate_key),
           true <- valid_gate_key?(gate_key) do
        {:ok, gate_key,
         Map.put(default_callbacks(), :authorize, Keyword.fetch(options, :authorize))}
      else
        _invalid -> error(:invalid_request)
      end
    end
  end

  defp valid_gate_key?({kind, id})
       when kind in [:github_installation, :saved_credential, :one_time_run] and
              is_integer(id) and id > 0 and id <= @maximum_object_size,
       do: true

  defp valid_gate_key?(_gate_key), do: false

  defp default_callbacks do
    %{
      list_requirements: &PointerScanner.list_requirements/2,
      batch: &LFS.batch/6,
      verify_local: &GitLFS.verify_object/3,
      ensure_local: &GitLFS.ensure_synchronized_object/4,
      with_upload_lock: &GitLFS.with_upload_lock/3,
      reserve_upload: &GitLFS.reserve_upload/3,
      recover_upload: &GitLFS.recover_upload/1,
      cleanup_upload: &GitLFS.cleanup_upload/1,
      consume_download: &LFS.consume_download/4,
      stage_upload: &GitLFS.stage_upload/3,
      commit_download: &GitLFS.commit_synchronized_upload/2,
      open_local: &GitLFS.open_object/4,
      read_local: &GitLFS.read/2,
      close_local: &GitLFS.close/1,
      upload: &LFS.upload/5,
      verify_remote: &LFS.verify/3
    }
  end

  if @allow_test_callbacks do
    defp valid_callbacks?(callbacks) do
      is_function(callbacks.list_requirements, 2) and is_function(callbacks.batch, 6) and
        is_function(callbacks.verify_local, 3) and is_function(callbacks.ensure_local, 4) and
        is_function(callbacks.with_upload_lock, 3) and
        is_function(callbacks.reserve_upload, 3) and
        is_function(callbacks.recover_upload, 1) and
        is_function(callbacks.cleanup_upload, 1) and
        is_function(callbacks.consume_download, 4) and
        is_function(callbacks.stage_upload, 3) and
        is_function(callbacks.commit_download, 2) and is_function(callbacks.open_local, 4) and
        is_function(callbacks.read_local, 2) and is_function(callbacks.close_local, 1) and
        is_function(callbacks.upload, 5) and is_function(callbacks.verify_remote, 3)
    end
  end

  defp call(function, arguments) do
    apply(function, arguments)
  rescue
    _exception -> {:error, :local_storage}
  catch
    {:lfs_authorization, _reason} = denied -> throw(denied)
    _kind, _reason -> {:error, :local_storage}
  end

  defp guarded_call(callbacks, key, arguments) do
    authorize!(callbacks)
    call(Map.fetch!(callbacks, key), arguments)
  end

  defp authorize!(%{authorize: :error}), do: :ok

  defp authorize!(%{authorize: {:ok, authorize}}) do
    result =
      try do
        authorize.()
      rescue
        _ -> {:error, :invalid_authorization}
      catch
        _, _ -> {:error, :invalid_authorization}
      end

    case result do
      :ok -> :ok
      {:error, reason} -> throw({:lfs_authorization, reason})
      _ -> throw({:lfs_authorization, :invalid_authorization})
    end
  end

  defp local_error(reason)
       when reason in [:integrity_mismatch, :sha256_mismatch, :size_mismatch],
       do: error(:integrity_mismatch)

  defp local_error(:not_found), do: error(:object_missing)
  defp local_error(:invalid_argument), do: error(:invalid_request)
  defp local_error(:invalid_request), do: error(:invalid_request)
  defp local_error(%Error{} = error), do: {:error, error}
  defp local_error(_reason), do: error(:local_storage)

  defp error(kind), do: {:error, Error.new(kind)}
end
