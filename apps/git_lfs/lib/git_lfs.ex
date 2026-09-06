defmodule GitLFS do
  @moduledoc """
  Repository-scoped Git LFS metadata, transfer planning, and blob access.
  """

  import Ecto.Query

  alias ForgeRepos.Repository
  alias Fornacast.Repo

  alias GitLFS.{
    LFSObject,
    Principal,
    RepositoryObject,
    StagedUpload,
    TransferToken,
    UploadReservation
  }

  @oid_regex ~r/\A[0-9a-f]{64}\z/
  @maximum_object_size 9_223_372_036_854_775_807
  @maximum_batch_objects 100
  @read_options [length: 1_048_576, read_length: 64 * 1_024, read_timeout: 30_000]

  @spec reserve_upload(Repository.t(), String.t(), non_neg_integer()) ::
          {:ok, UploadReservation.t() | :already_present} | {:error, atom()}
  def reserve_upload(%Repository{} = repository, oid, size) do
    with :ok <- validate_object(oid, size),
         {:ok, repository} <- current_repository(repository) do
      case verified_repository_object(repository.id, oid, size) do
        :ok -> {:ok, :already_present}
        {:error, :not_found} -> {:ok, reservation(repository, oid, size)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def reserve_upload(_repository, _oid, _size), do: {:error, :invalid_request}

  @spec stage_upload(UploadReservation.t(), function(), state) ::
          {:ok, StagedUpload.t(), state} | {:error, atom(), state}
        when state: term()
  def stage_upload(%UploadReservation{} = reservation, reader, state)
      when is_function(reader, 2) do
    with :ok <- validate_reservation(reservation) do
      case ForgeBlobs.stage_from_reader(
             reservation.staging_key,
             reader,
             state,
             max_size: max(reservation.size, 1),
             read_options: @read_options
           ) do
        {:ok, staged_ref, %{size: size}, next_state} when size != reservation.size ->
          _ = ForgeBlobs.discard(staged_ref)
          {:error, :size_mismatch, next_state}

        {:ok, staged_ref, %{sha256_digest: digest}, next_state}
        when digest != reservation.oid ->
          _ = ForgeBlobs.discard(staged_ref)
          {:error, :sha256_mismatch, next_state}

        {:ok, staged_ref, _metadata, next_state} ->
          {:ok, %StagedUpload{reservation: reservation, staged_ref: staged_ref}, next_state}

        {:error, :entity_too_large, next_state} ->
          {:error, :size_mismatch, next_state}

        {:error, reason, next_state} ->
          {:error, reason, next_state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def stage_upload(_reservation, _reader, state), do: {:error, :invalid_request, state}

  @spec recover_upload(UploadReservation.t()) ::
          {:ok, StagedUpload.t()} | {:error, atom()}
  def recover_upload(%UploadReservation{} = reservation) do
    with :ok <- validate_reservation(reservation),
         {:ok, staged_ref} <-
           ForgeBlobs.recover_stage(
             reservation.staging_key,
             reservation.oid,
             reservation.size
           ) do
      {:ok, %StagedUpload{reservation: reservation, staged_ref: staged_ref}}
    end
  end

  def recover_upload(_reservation), do: {:error, :invalid_request}

  @doc "Removes one validated upload survivor so a locked caller can retry staging."
  @spec cleanup_upload(UploadReservation.t()) :: :ok | {:error, atom()}
  def cleanup_upload(%UploadReservation{} = reservation) do
    with :ok <- validate_reservation(reservation),
         {:ok, _repository} <- reservation_repository(reservation) do
      ForgeBlobs.cleanup_staging(reservation.staging_key)
    end
  end

  def cleanup_upload(_reservation), do: {:error, :invalid_request}

  @doc "Serializes recovery, cleanup, and staging for one repository generation and OID."
  @spec with_upload_lock(Repository.t(), String.t(), (-> result)) ::
          result | {:error, atom()}
        when result: term()
  def with_upload_lock(%Repository{} = repository, oid, fun)
      when is_binary(oid) and is_function(fun, 0) do
    with true <- valid_oid?(oid),
         {:ok, repository} <- current_repository(repository) do
      lock = {{__MODULE__, :upload, repository.id, repository.generation, oid}, self()}

      case :global.trans(lock, fun, Enum.uniq([node() | Node.list()]), :infinity) do
        :aborted -> {:error, :unavailable}
        {:aborted, _reason} -> {:error, :unavailable}
        result -> result
      end
    else
      false -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def with_upload_lock(_repository, _oid, _fun), do: {:error, :invalid_request}

  @spec commit_upload(StagedUpload.t()) :: {:ok, LFSObject.t()} | {:error, atom()}
  def commit_upload(%StagedUpload{reservation: reservation, staged_ref: staged_ref}) do
    commit_staged_upload(reservation, staged_ref, nil)
  end

  def commit_upload(_staged), do: {:error, :invalid_request}

  @doc "Commits a provider-verified upload and records its first synchronized ref."
  @spec commit_synchronized_upload(StagedUpload.t(), String.t()) ::
          {:ok, LFSObject.t()} | {:error, atom()}
  def commit_synchronized_upload(
        %StagedUpload{reservation: reservation, staged_ref: staged_ref},
        first_seen_ref
      ) do
    with true <- standard_ref?(first_seen_ref) do
      commit_staged_upload(reservation, staged_ref, first_seen_ref)
    else
      false -> {:error, :invalid_request}
    end
  end

  def commit_synchronized_upload(_staged, _first_seen_ref),
    do: {:error, :invalid_request}

  defp commit_staged_upload(reservation, staged_ref, first_seen_ref) do
    with :ok <- validate_reservation(reservation),
         {:ok, repository} <- reservation_repository(reservation),
         {:ok, %{sha256_digest: oid, storage_key: storage_key, size: size}} <-
           ForgeBlobs.commit(staged_ref),
         true <- oid == reservation.oid and size == reservation.size,
         {:ok, object} <-
           persist_ready_object(repository, oid, size, storage_key, first_seen_ref) do
      {:ok, object}
    else
      false -> {:error, :integrity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Attaches verified global bytes after a trusted provider proves repository reachability."
  @spec ensure_synchronized_object(Repository.t(), String.t(), non_neg_integer(), String.t()) ::
          :ok | {:error, atom()}
  def ensure_synchronized_object(%Repository{} = repository, oid, size, first_seen_ref) do
    with :ok <- validate_object(oid, size),
         true <- standard_ref?(first_seen_ref),
         {:ok, repository} <- current_repository(repository),
         {:ok, %{size: ^size}} <- ForgeBlobs.stat(oid),
         :ok <- ForgeBlobs.verify(oid),
         {:ok, _object} <- persist_ready_object(repository, oid, size, oid, first_seen_ref) do
      :ok
    else
      false -> {:error, :invalid_request}
      {:ok, _metadata} -> {:error, :integrity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure_synchronized_object(_repository, _oid, _size, _first_seen_ref),
    do: {:error, :invalid_request}

  @spec verify_object(Repository.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def verify_object(%Repository{} = repository, oid, size) do
    with :ok <- validate_object(oid, size),
         {:ok, repository} <- current_repository(repository),
         %LFSObject{storage_key: storage_key} <- repository_object(repository.id, oid, size),
         :ok <- ForgeBlobs.verify(storage_key) do
      :ok
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_object(_repository, _oid, _size), do: {:error, :not_found}

  @doc "Returns repository-scoped metadata without exposing global object existence."
  @spec object_metadata(Repository.t(), String.t()) ::
          {:ok, %{size: non_neg_integer()}} | {:error, :not_found}
  def object_metadata(%Repository{} = repository, oid) do
    with true <- valid_oid?(oid),
         {:ok, repository} <- current_repository(repository),
         %LFSObject{size: size} <- repository_object(repository.id, oid) do
      {:ok, %{size: size}}
    else
      _missing -> {:error, :not_found}
    end
  end

  def object_metadata(_repository, _oid), do: {:error, :not_found}

  @spec open_object(
          Repository.t(),
          String.t(),
          non_neg_integer(),
          :all | {non_neg_integer(), non_neg_integer()}
        ) :: {:ok, ForgeBlobs.Source.t(), map()} | {:error, atom()}
  def open_object(%Repository{} = repository, oid, size, range) do
    with :ok <- validate_object(oid, size),
         {:ok, repository} <- current_repository(repository),
         %LFSObject{storage_key: storage_key} <- repository_object(repository.id, oid, size),
         {:ok, metadata} <- range_metadata(size, range),
         {:ok, source} <- ForgeBlobs.open(storage_key, size, range) do
      {:ok, source, metadata}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def open_object(_repository, _oid, _size, _range), do: {:error, :not_found}

  defdelegate read(source, requested_bytes), to: ForgeBlobs
  defdelegate close(source), to: ForgeBlobs

  @spec remove_repository_objects(Repository.t()) :: :ok
  def remove_repository_objects(%Repository{id: repository_id}) when is_integer(repository_id) do
    RepositoryObject
    |> where([mapping], mapping.repository_id == ^repository_id)
    |> Repo.delete_all()

    :ok
  end

  @spec batch(Repository.t(), Principal.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def batch(repository, principal, request, base_url, options \\ [])

  def batch(%Repository{} = repository, %Principal{} = principal, request, base_url, options)
      when is_map(request) and is_binary(base_url) and is_list(options) do
    with {:ok, operation, objects} <- validate_batch_request(request),
         {:ok, principal, repository} <-
           TransferToken.authorize(principal, repository, operation, options),
         {:ok, owner} <- repository_owner(repository),
         {:ok, rendered} <-
           render_batch_objects(
             operation,
             objects,
             repository,
             principal,
             object_url(base_url, owner.username, repository.slug),
             options
           ) do
      {:ok, %{"transfer" => "basic", "hash_algo" => "sha256", "objects" => rendered}}
    end
  end

  def batch(_repository, _principal, _request, _base_url, _options),
    do: {:error, :invalid_request}

  defp reservation(repository, oid, size) do
    %UploadReservation{
      repository_id: repository.id,
      repository_generation: repository.generation,
      oid: oid,
      size: size,
      staging_key: "lfs-#{repository.id}-#{repository.generation}-#{oid}"
    }
  end

  defp validate_reservation(%UploadReservation{} = reservation) do
    with :ok <- validate_object(reservation.oid, reservation.size),
         true <- is_integer(reservation.repository_id) and reservation.repository_id > 0,
         true <-
           is_integer(reservation.repository_generation) and
             reservation.repository_generation > 0,
         true <-
           reservation.staging_key ==
             "lfs-#{reservation.repository_id}-#{reservation.repository_generation}-#{reservation.oid}" do
      :ok
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp current_repository(%Repository{id: id, generation: generation})
       when is_integer(id) and id > 0 and is_integer(generation) and generation > 0 do
    case live_repository(id, generation) do
      %Repository{} = repository -> {:ok, repository}
      nil -> {:error, :not_found}
    end
  end

  defp current_repository(_repository), do: {:error, :not_found}

  defp reservation_repository(%UploadReservation{
         repository_id: id,
         repository_generation: generation
       }) do
    case live_repository(id, generation) do
      %Repository{} = repository -> {:ok, repository}
      nil -> {:error, :not_found}
    end
  end

  defp live_repository(repository_id, generation) do
    Repository
    |> where(
      [repository],
      repository.id == ^repository_id and repository.generation == ^generation and
        repository.lifecycle in [:ready, :synchronizing] and is_nil(repository.deleted_at)
    )
    |> Repo.one()
  end

  defp persist_ready_object(repository, oid, size, storage_key, first_seen_ref) do
    now = DateTime.utc_now(:second)

    transaction =
      Repo.transaction(fn ->
        attrs = %{
          oid_sha256: oid,
          size: size,
          storage_key: storage_key,
          verified_at: now
        }

        case %LFSObject{}
             |> LFSObject.ready_changeset(attrs)
             |> Repo.insert(on_conflict: :nothing, conflict_target: [:oid_sha256]) do
          {:ok, _object} -> :ok
          {:error, changeset} -> Repo.rollback({:validation, changeset})
        end

        case ready_object(oid) do
          %LFSObject{size: ^size, storage_key: ^storage_key} = object ->
            case attach(repository.id, oid, first_seen_ref, now) do
              :ok -> object
              {:error, reason} -> Repo.rollback(reason)
            end

          %LFSObject{} ->
            Repo.rollback(:integrity_mismatch)

          nil ->
            Repo.rollback(:not_found)
        end
      end)

    case transaction do
      {:ok, %LFSObject{} = object} -> {:ok, object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach(repository_id, oid, first_seen_ref, now) do
    attrs = %{
      repository_id: repository_id,
      oid_sha256: oid,
      first_seen_ref: first_seen_ref,
      reachable: true,
      last_reconciled_at: now
    }

    case %RepositoryObject{}
         |> RepositoryObject.changeset(attrs)
         |> Repo.insert(
           on_conflict: [set: [reachable: true, last_reconciled_at: now, updated_at: now]],
           conflict_target: [:repository_id, :oid_sha256]
         ) do
      {:ok, _mapping} -> :ok
      {:error, changeset} -> {:error, {:validation, changeset}}
    end
  end

  defp ready_object(oid), do: Repo.get_by(LFSObject, oid_sha256: oid, state: :ready)

  defp repository_object(repository_id, oid) do
    LFSObject
    |> join(:inner, [object], mapping in RepositoryObject,
      on: mapping.oid_sha256 == object.oid_sha256
    )
    |> where(
      [object, mapping],
      mapping.repository_id == ^repository_id and mapping.oid_sha256 == ^oid and
        mapping.reachable == true and object.state == :ready
    )
    |> Repo.one()
  end

  defp repository_object(repository_id, oid, size) do
    LFSObject
    |> join(:inner, [object], mapping in RepositoryObject,
      on: mapping.oid_sha256 == object.oid_sha256
    )
    |> where(
      [object, mapping],
      mapping.repository_id == ^repository_id and mapping.oid_sha256 == ^oid and
        mapping.reachable == true and object.state == :ready and object.size == ^size
    )
    |> Repo.one()
  end

  defp available_repository_object(repository_id, oid, size) do
    case repository_object(repository_id, oid, size) do
      %LFSObject{storage_key: storage_key} ->
        case ForgeBlobs.stat(storage_key) do
          {:ok, %{size: ^size}} -> :ok
          {:ok, _metadata} -> {:error, :integrity_mismatch}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp verified_repository_object(repository_id, oid, size) do
    case repository_object(repository_id, oid, size) do
      %LFSObject{storage_key: storage_key} -> ForgeBlobs.verify(storage_key)
      nil -> {:error, :not_found}
    end
  end

  defp range_metadata(size, range) when range in [:all, nil],
    do: {:ok, %{size: size, total_size: size, offset: 0}}

  defp range_metadata(size, {offset, length})
       when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 and
              offset <= size and length <= size - offset,
       do: {:ok, %{size: length, total_size: size, offset: offset}}

  defp range_metadata(_size, _range), do: {:error, :invalid_request}

  defp validate_batch_request(request) do
    with operation when operation in ["upload", "download"] <- request["operation"],
         :ok <- validate_hash_algorithm(Map.get(request, "hash_algo", "sha256")),
         :ok <- validate_transfers(Map.get(request, "transfers", ["basic"])),
         {:ok, objects} <- validate_batch_objects(request["objects"]) do
      {:ok, String.to_existing_atom(operation), objects}
    else
      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_request}
    end
  end

  defp validate_hash_algorithm("sha256"), do: :ok
  defp validate_hash_algorithm(_algorithm), do: {:error, :unsupported_hash_algorithm}

  defp validate_transfers(transfers) when is_list(transfers) do
    if "basic" in transfers, do: :ok, else: {:error, :unsupported_transfer}
  end

  defp validate_transfers(_transfers), do: {:error, :unsupported_transfer}

  defp validate_batch_objects(objects) when is_list(objects) and objects != [] do
    cond do
      length(objects) > @maximum_batch_objects -> {:error, :too_many_objects}
      not Enum.all?(objects, &valid_batch_object?/1) -> {:error, :invalid_request}
      not unique_batch_oids?(objects) -> {:error, :invalid_request}
      true -> {:ok, objects}
    end
  end

  defp validate_batch_objects(_objects), do: {:error, :invalid_request}

  defp valid_batch_object?(%{"oid" => oid, "size" => size}), do: validate_object(oid, size) == :ok
  defp valid_batch_object?(_object), do: false

  defp unique_batch_oids?(objects) do
    objects
    |> Enum.map(& &1["oid"])
    |> MapSet.new()
    |> MapSet.size()
    |> Kernel.==(length(objects))
  end

  defp render_batch_objects(operation, objects, repository, principal, object_base, options) do
    Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, rendered} ->
      case render_batch_object(operation, object, repository, principal, object_base, options) do
        {:ok, response} -> {:cont, {:ok, [response | rendered]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  defp render_batch_object(
         :upload,
         %{"oid" => oid, "size" => size} = object,
         repository,
         principal,
         object_base,
         options
       ) do
    case reserve_upload(repository, oid, size) do
      {:ok, :already_present} ->
        {:ok, object}

      {:ok, %UploadReservation{}} ->
        with {:ok, upload, _ttl} <-
               TransferToken.issue(
                 principal,
                 repository,
                 :object,
                 :upload,
                 oid,
                 Keyword.put(options, :object_size, size)
               ),
             {:ok, verify, _ttl} <-
               TransferToken.issue(
                 principal,
                 repository,
                 :object,
                 :verify,
                 oid,
                 Keyword.put(options, :object_size, size)
               ) do
          href = object_base <> "/" <> oid

          {:ok,
           Map.put(object, "actions", %{
             "upload" => token_action(href, upload),
             "verify" => token_action(href <> "/verify", verify)
           })}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_batch_object(
         :download,
         %{"oid" => oid, "size" => size} = object,
         repository,
         principal,
         object_base,
         options
       ) do
    case available_repository_object(repository.id, oid, size) do
      :ok ->
        with {:ok, token, _ttl} <-
               TransferToken.issue(
                 principal,
                 repository,
                 :object,
                 :download,
                 oid,
                 Keyword.put(options, :object_size, size)
               ) do
          {:ok,
           object
           |> Map.put("authenticated", true)
           |> Map.put("actions", %{
             "download" => token_action(object_base <> "/" <> oid, token)
           })}
        end

      {:error, :not_found} ->
        {:ok,
         Map.put(object, "error", %{
           "code" => 404,
           "message" => "Object does not exist"
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp token_action(href, token) do
    %{"href" => href, "header" => %{"Authorization" => "Bearer " <> token}}
  end

  defp repository_owner(%Repository{owner_user_id: owner_id}) do
    case ForgeAccounts.get_account(owner_id) do
      %{username: username, state: :active} = owner when is_binary(username) -> {:ok, owner}
      _missing -> {:error, :not_found}
    end
  end

  defp object_url(base_url, owner, repository) do
    String.trim_trailing(base_url, "/") <>
      "/#{owner}/#{repository}.git/info/lfs/objects"
  end

  defp validate_object(oid, size) do
    if valid_oid?(oid) and is_integer(size) and size >= 0 and size <= @maximum_object_size,
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp valid_oid?(oid) when is_binary(oid), do: Regex.match?(@oid_regex, oid)
  defp valid_oid?(_oid), do: false

  defp standard_ref?("refs/heads/" <> name), do: valid_ref_tail?(name)
  defp standard_ref?("refs/tags/" <> name), do: valid_ref_tail?(name)
  defp standard_ref?(_ref), do: false

  defp valid_ref_tail?(name) when is_binary(name) do
    byte_size(name) in 1..1_000 and String.valid?(name) and
      not String.starts_with?(name, ["/", "."]) and
      not String.ends_with?(name, ["/", ".", ".lock"]) and
      not String.contains?(name, [<<0>>, "//", "..", "@{", "\\", "~", "^", ":", "?", "*", "["]) and
      not String.match?(name, ~r/[\x00-\x20\x7f]/)
  end
end
