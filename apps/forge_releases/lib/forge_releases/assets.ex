defmodule ForgeReleases.Assets do
  @moduledoc "Repository-authorized release assets with durable streamed publication."
  import Ecto.Query
  alias ForgeReleases.{Asset, AssetBlob, AssetOperation, AssetStorage, Release}
  alias Fornacast.{Audit, OperationLease, Page, Repo}

  @lease_seconds 120
  @maximum_assets_per_release 1_000
  @read_options [length: 1_048_576, read_length: 65_536, read_timeout: 30_000]

  def list(actor, owner, repo, release_id, filters) do
    with {:ok, _release} <- ForgeReleases.get(actor, owner, repo, release_id),
         page when is_integer(page) and page > 0 <- value(filters, :page, 1),
         per_page when is_integer(per_page) and per_page in 1..100 <-
           value(filters, :per_page, 30) do
      query = from a in Asset, where: a.release_id == ^release_id and a.state == :uploaded

      entries =
        query
        |> order_by(asc: :id)
        |> limit(^per_page)
        |> offset(^((page - 1) * per_page))
        |> Repo.all()
        |> Enum.map(&decorate/1)

      {:ok,
       %Page{
         entries: entries,
         total: Repo.aggregate(query, :count),
         page: page,
         per_page: per_page
       }}
    else
      {:error, _} = error -> error
      _ -> invalid(:page)
    end
  end

  def get(actor, owner, repo, asset_id) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_read),
         %Asset{} = asset <-
           Repo.get_by(Asset, id: asset_id, repository_id: repository.id, state: :uploaded),
         {:ok, _} <- ForgeReleases.get(actor, owner, repo, asset.release_id) do
      {:ok, decorate(asset)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def upload(actor, owner, repo, release_id, attrs, reader, state, options \\ []) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo, :repository_write) do
      options =
        Keyword.merge(options,
          source_key: "local-#{Ecto.UUID.generate()}",
          kind: :local,
          actor: actor,
          fence: local_fence(actor, repository, release_id)
        )

      attrs = string_keys(attrs) |> Map.put("uploader_user_id", actor.id)
      transfer(repository, release_id, attrs, reader, state, options)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def import_asset(repository, release_id, attrs, reader, state, options) do
    if is_function(options[:fence], 1) and is_binary(options[:source_key]) do
      transfer(
        repository,
        release_id,
        string_keys(attrs),
        reader,
        state,
        Keyword.put(options, :kind, :import)
      )
    else
      {:error, :invalid_import_fence, state}
    end
  end

  def resume_import_asset(repository, release_id, attrs, options) do
    options = Keyword.put(options, :kind, :import)

    with_operation_lock(options[:source_key], fn ->
      case Repo.get_by(AssetOperation, source_key: options[:source_key]) do
        %AssetOperation{state: state} when state in [:staged, :metadata_ready, :completed] ->
          case reserve(repository, release_id, string_keys(attrs), options) do
            {:ok, %AssetOperation{state: :completed} = op} ->
              republish(op, options)

            {:ok, op} ->
              case resume(op, nil, options) do
                {:ok, asset, nil} -> {:ok, asset}
                {:error, reason, nil} -> {:error, reason}
              end

            {:error, _} = error ->
              error
          end

        _ ->
          :download
      end
    end)
  end

  def update(actor, owner, repo, asset_id, attrs, metadata) do
    mutate(actor, owner, repo, asset_id, "release_asset.updated", metadata, fn asset ->
      Repo.update(Asset.changeset(asset, string_keys(attrs) |> Map.take(["name", "label"])))
    end)
  end

  def delete(actor, owner, repo, asset_id, metadata) do
    case mutate(actor, owner, repo, asset_id, "release_asset.deleted", metadata, fn asset ->
           Repo.update(Ecto.Changeset.change(asset, state: :deleted))
         end) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def open(actor, owner, repo, asset_id, range \\ :all) do
    with {:ok, asset} <- get(actor, owner, repo, asset_id) do
      ForgeBlobs.with_digest_lock(asset.storage_key, fn ->
        with %Asset{state: :uploaded} <- Repo.get(Asset, asset.id),
             {:ok, source} <- AssetStorage.open(asset.storage_key, asset.size, range) do
          {:ok, asset, source}
        else
          {:error, reason} -> storage_error(reason)
          _ -> {:error, :not_found}
        end
      end)
    end
  end

  def complete_download(asset_id) do
    Repo.update_all(from(a in Asset, where: a.id == ^asset_id and a.state == :uploaded),
      inc: [download_count: 1]
    )

    :ok
  end

  def for_release(release_id),
    do:
      Repo.all(
        from a in Asset,
          where: a.release_id == ^release_id and a.state == :uploaded,
          order_by: a.id
      )
      |> Enum.map(&decorate/1)

  def delete_release_assets(repo, release_id) do
    repo.update_all(from(a in Asset, where: a.release_id == ^release_id and a.state != :deleted),
      set: [state: :deleted, updated_at: now()]
    )

    :ok
  end

  defp mutate(actor, owner, repo_slug, asset_id, action, metadata, mutation) do
    with {:ok, repository} <-
           ForgeRepos.fetch_authorized_repository(actor, owner, repo_slug, :repository_write) do
      Repo.transaction(fn ->
        observed =
          Repo.get_by(Asset, id: asset_id, repository_id: repository.id, state: :uploaded) ||
            Repo.rollback(:not_found)

        check!(local_fence(actor, repository, observed.release_id), Repo)

        asset =
          Repo.one(
            from a in Asset,
              where:
                a.id == ^asset_id and a.repository_id == ^repository.id and
                  a.release_id == ^observed.release_id and a.state == :uploaded,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:not_found)

        case mutation.(asset) do
          {:ok, result} ->
            audit!(actor, action, result, metadata)
            decorate(result)

          {:error, changeset} ->
            Repo.rollback(validation(changeset))
        end
      end)
    end
  end

  defp transfer(repository, release_id, attrs, reader, state, options) do
    source_key = options[:source_key]

    if is_binary(source_key) and byte_size(source_key) in 1..255 and is_function(reader, 2) do
      with_operation_lock(source_key, fn ->
        case reserve(repository, release_id, attrs, options) do
          {:ok, %AssetOperation{state: :completed} = op} ->
            case republish(op, options) do
              {:ok, asset} -> {:ok, decorate(asset), state}
              {:error, reason} -> {:error, reason, state}
            end

          {:ok, %AssetOperation{state: state_name} = op}
          when state_name in [:staged, :metadata_ready] ->
            resume(op, state, options)

          {:ok, op} ->
            stage(op, attrs, reader, state, options)

          {:error, reason} ->
            {:error, reason, state}
        end
      end)
    else
      {:error, :invalid_source, state}
    end
  end

  defp reserve(repository, release_id, attrs, options) do
    Repo.transaction(fn ->
      check!(options[:fence], Repo)

      current =
        Repo.one(
          from r in ForgeRepos.Repository,
            where:
              r.id == ^repository.id and r.generation == ^repository.generation and
                is_nil(r.deleted_at),
            lock: "FOR UPDATE"
        ) || Repo.rollback(:not_found)

      release =
        Repo.one(
          from r in Release,
            where:
              r.id == ^release_id and r.repository_id == ^current.id and is_nil(r.deleted_at),
            lock: "FOR UPDATE"
        ) || Repo.rollback(:not_found)

      if options[:kind] == :local, do: mutable!(release)

      case Repo.get_by(AssetOperation, source_key: options[:source_key]) do
        %AssetOperation{repository_id: id, asset_id: asset_id} = op when id == current.id ->
          asset = Repo.get!(Asset, asset_id)
          if asset.release_id != release_id, do: Repo.rollback(:invalid_source)
          reclaim_or_restart(op, asset, attrs)

        nil ->
          new_operation(current, release, attrs, options)

        _ ->
          Repo.rollback(:invalid_source)
      end
    end)
  end

  defp new_operation(repository, release, attrs, options) do
    validate_source!(attrs)
    reserve_quota!(release.id)

    base = %Asset{
      repository_id: repository.id,
      release_id: release.id,
      uploader_user_id: attrs["uploader_user_id"],
      uploader_github_identity_id: attrs["uploader_github_identity_id"],
      source_asset_id: attrs["source_asset_id"],
      source_download_count: attrs["source_download_count"] || 0
    }

    if is_nil(base.uploader_user_id) == is_nil(base.uploader_github_identity_id),
      do: Repo.rollback(:invalid_uploader)

    changeset = Asset.changeset(base, attrs)

    changeset =
      Enum.reduce([:inserted_at, :updated_at], changeset, fn key, changeset ->
        case attrs[Atom.to_string(key)] do
          %DateTime{} = time ->
            Ecto.Changeset.put_change(changeset, key, DateTime.truncate(time, :second))

          _ ->
            changeset
        end
      end)

    asset = insert!(changeset)

    insert!(
      Ecto.Changeset.change(%AssetOperation{}, %{
        repository_id: repository.id,
        repository_generation: repository.generation,
        asset_id: asset.id,
        kind: options[:kind],
        source_key: options[:source_key],
        staging_key: "release-#{Ecto.UUID.generate()}",
        lease_owner: Ecto.UUID.generate(),
        lease_expires_at: DateTime.add(now(), @lease_seconds)
      })
    )
  end

  defp reclaim_or_restart(%AssetOperation{state: :completed} = op, _asset, _attrs), do: op

  defp reclaim_or_restart(%AssetOperation{state: :failed} = op, asset, attrs) do
    validate_source!(attrs)
    reserve_quota!(asset.release_id)

    if op.staging_key && AssetStorage.cleanup_staging(op.staging_key) != :ok,
      do: Repo.rollback(:unavailable)

    insert_or_update!(
      Asset.changeset(asset, attrs)
      |> Ecto.Changeset.put_change(:state, :pending)
    )

    insert_or_update!(
      Ecto.Changeset.change(op,
        state: :staging,
        storage_key: nil,
        size: nil,
        failure: nil,
        staging_key: "release-#{Ecto.UUID.generate()}",
        lease_owner: Ecto.UUID.generate(),
        lease_expires_at: DateTime.add(now(), @lease_seconds),
        lock_version: op.lock_version + 1
      )
    )
  end

  defp reclaim_or_restart(op, _asset, _attrs) do
    # The local operation lock excludes a live owner. A stopped call may retain
    # an unexpired SQL lease; release only this exact version before reclaiming.
    if op.lease_owner do
      case OperationLease.release(AssetOperation, op) do
        :ok -> :ok
        _ -> Repo.rollback(:lost_lease)
      end
    end

    case OperationLease.claim(AssetOperation, op.id, Ecto.UUID.generate(), now(), @lease_seconds) do
      {:ok, claimed} -> claimed
      _ -> Repo.rollback(:lost_lease)
    end
  end

  defp stage(op, attrs, reader, state, options) do
    deadline = System.monotonic_time(:millisecond) + 1_800_000
    failure_key = {__MODULE__, :reader_failure, op.id}
    Process.delete(failure_key)

    wrapped = fn {reader_state, current_op}, read_options ->
      with true <- System.monotonic_time(:millisecond) < deadline,
           :ok <- heartbeat(options),
           {:ok, renewed} <- renew(current_op, options) do
        try do
          case read_chunk(reader, reader_state, read_options, op.kind) do
            {kind, chunk, next} when kind in [:ok, :more] -> {kind, chunk, {next, renewed}}
            {:error, reason, next} -> {:error, reason, {next, renewed}}
            _ -> {:error, :invalid_source, {reader_state, renewed}}
          end
        rescue
          _ -> {:error, :invalid_source, {reader_state, renewed}}
        catch
          _, _ -> {:error, :invalid_source, {reader_state, renewed}}
        end
      else
        {:error, reason} ->
          Process.put(failure_key, reason)
          {:error, :invalid_source, {reader_state, current_op}}

        _ ->
          Process.put(failure_key, :timeout)
          {:error, :invalid_source, {reader_state, current_op}}
      end
    end

    max_size = min(Fornacast.Config.blob_max_bytes(), 2_147_483_648)

    case AssetStorage.stage_from_reader(op.staging_key, wrapped, {state, op},
           max_size: max_size,
           read_options: @read_options
         ) do
      {:ok, staged, metadata, {next, current_op}} ->
        if expected_content?(attrs, metadata) do
          case persist_stage(current_op, metadata, options) do
            {:ok, staged_op} ->
              commit(staged_op, staged, next, options)

            {:error, reason} ->
              _ = AssetStorage.discard(staged)
              {:error, reason, next}
          end
        else
          _ = AssetStorage.discard(staged)
          fail(current_op, :integrity_mismatch, options)
          {:error, :integrity_mismatch, next}
        end

      {:error, storage_reason, {next, current_op}} ->
        reason = Process.delete(failure_key) || storage_reason
        fail(current_op, reason, options)
        {:error, reason, next}
    end
  end

  # Mint's pull cursor signals EOF separately; Plug marks its last chunk :ok.
  defp read_chunk(reader, state, options, :import) do
    case reader.(state, Keyword.take(options, [:length, :read_timeout])) do
      {:ok, bytes, next} -> {:more, bytes, next}
      {:eof, next} -> {:ok, "", next}
      other -> other
    end
  end

  defp read_chunk(reader, state, options, :local), do: reader.(state, options)

  defp persist_stage(op, metadata, options) do
    ForgeBlobs.with_digest_lock(metadata.storage_key, fn ->
      Repo.transaction(fn ->
        check!(options[:fence], Repo)
        touch_blob!(metadata.storage_key, metadata.size)
        owned_update!(op, state: :staged, storage_key: metadata.storage_key, size: metadata.size)
      end)
    end)
  end

  defp commit(op, staged, state, options) do
    ForgeBlobs.with_digest_lock(op.storage_key, fn ->
      with :ok <- heartbeat(options),
           {:ok, op} <- renew(op, options),
           {:ok, %{size: size, storage_key: key}} <-
             bounded(op.storage_key, fn -> AssetStorage.commit(staged) end),
           true <- size == op.size and key == op.storage_key,
           :ok <- after_commit(options),
           {:ok, asset} <- publish(op, options) do
        _ = AssetStorage.cleanup_staging(op.staging_key)
        {:ok, decorate(asset), state}
      else
        false -> {:error, :integrity_mismatch, state}
        {:error, reason} -> {:error, reason, state}
      end
    end)
  end

  defp resume(op, state, options) do
    ForgeBlobs.with_digest_lock(op.storage_key, fn ->
      case ensure_bytes(op) do
        :ok ->
          case publish(op, options) do
            {:ok, asset} ->
              _ = AssetStorage.cleanup_staging(op.staging_key)
              {:ok, decorate(asset), state}

            {:error, reason} ->
              {:error, reason, state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    end)
  end

  defp publish(op, options) do
    Repo.transaction(fn ->
      check!(options[:fence], Repo)
      current = owned_update!(op, state: :metadata_ready)
      asset = Repo.get!(Asset, op.asset_id)
      if asset.state == :deleted, do: Repo.rollback(:not_found)
      release = Repo.get!(Release, asset.release_id)
      if release.deleted_at, do: Repo.rollback(:not_found)
      if op.kind == :local, do: mutable!(release)

      asset =
        insert_or_update!(
          Ecto.Changeset.change(asset,
            state: :uploaded,
            size: op.size,
            storage_key: op.storage_key,
            sha256_digest: op.storage_key,
            updated_at: asset.updated_at
          )
        )

      Repo.update_all(from(b in AssetBlob, where: b.storage_key == ^op.storage_key),
        set: [state: :ready, gc_after: nil],
        inc: [version: 1]
      )

      check_publish!(options, asset)

      if op.kind == :local,
        do:
          audit!(
            options[:actor],
            "release_asset.created",
            asset,
            options[:request_metadata] || %{}
          )

      case OperationLease.update_owned(AssetOperation, current, state: :completed) do
        {:ok, _} -> asset
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp republish(op, options) do
    Repo.transaction(fn ->
      check!(options[:fence], Repo)

      case Repo.get(Asset, op.asset_id) do
        %Asset{state: :uploaded} = asset ->
          check_publish!(options, asset)
          asset

        _ ->
          Repo.rollback(:not_found)
      end
    end)
  end

  defp check_publish!(options, asset) do
    case Keyword.get(options, :publish, fn _repo, _asset -> :ok end).(Repo, decorate(asset)) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_bytes(op) do
    case AssetStorage.stat(op.storage_key) do
      {:ok, %{size: size}} when size == op.size ->
        bounded(op.storage_key, fn -> AssetStorage.verify(op.storage_key) end)

      {:ok, _} ->
        {:error, :integrity_mismatch}

      {:error, :not_found} ->
        with {:ok, staged} <- AssetStorage.recover_stage(op.staging_key, op.storage_key, op.size),
             {:ok, _} <- bounded(op.storage_key, fn -> AssetStorage.commit(staged) end),
             do: :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def recover do
    operations =
      Repo.all(
        from o in AssetOperation,
          where:
            o.state in [:staging, :staged, :metadata_ready] and
              (is_nil(o.lease_expires_at) or o.lease_expires_at <= ^now()),
          limit: 50
      )

    Enum.each(operations, &recover_operation/1)

    terminal =
      Repo.all(
        from o in AssetOperation,
          where: o.state in [:completed, :failed] and not is_nil(o.staging_key),
          limit: 50
      )

    Enum.each(terminal, fn op ->
      try_operation_lock(op.source_key, fn ->
        if AssetStorage.cleanup_staging(op.staging_key) == :ok do
          Repo.update_all(
            from(o in AssetOperation,
              where: o.id == ^op.id and o.lock_version == ^op.lock_version
            ),
            set: [staging_key: nil]
          )
        end
      end)
    end)

    :ok
  end

  defp recover_operation(op) do
    try_operation_lock(op.source_key, fn ->
      case OperationLease.claim(
             AssetOperation,
             op.id,
             Ecto.UUID.generate(),
             now(),
             @lease_seconds
           ) do
        {:ok, claimed} -> recover_claimed(claimed)
        _ -> :ok
      end
    end)
  end

  defp recover_claimed(%AssetOperation{state: :staging} = op) do
    fail(op, :interrupted, fence: fn _ -> :ok end)
  end

  defp recover_claimed(op) do
    if unreachable?(op) do
      fail(op, :not_found, fence: fn _ -> :ok end)
    else
      recover_reachable(op)
    end
  end

  defp unreachable?(op) do
    case Repo.transaction(fn ->
           repository =
             Repo.one(
               from r in ForgeRepos.Repository,
                 where: r.id == ^op.repository_id,
                 lock: "FOR UPDATE"
             )

           asset = Repo.get(Asset, op.asset_id)

           release =
             if asset,
               do:
                 Repo.one(from r in Release, where: r.id == ^asset.release_id, lock: "FOR UPDATE")

           is_nil(repository) or repository.generation != op.repository_generation or
             not is_nil(repository.deleted_at) or is_nil(release) or
             not is_nil(release.deleted_at) or
             asset.state == :deleted or
             (op.kind == :local and release.immutable and not release.draft)
         end) do
      {:ok, result} -> result
      _ -> false
    end
  end

  defp recover_reachable(op) do
    ForgeBlobs.with_digest_lock(op.storage_key, fn ->
      case ensure_bytes(op) do
        :ok ->
          if op.kind == :import do
            # Current importer ownership and mapping callback are needed to
            # publish. Recovery only preserves verified bytes for that retry.
            _ = OperationLease.update_owned(AssetOperation, op, state: :metadata_ready)
          else
            asset = Repo.get!(Asset, op.asset_id)
            actor = ForgeAccounts.get_account(asset.uploader_user_id)
            repository = Repo.get!(ForgeRepos.Repository, op.repository_id)
            options = [actor: actor, fence: local_fence(actor, repository, asset.release_id)]

            case publish(op, options) do
              {:ok, _} ->
                AssetStorage.cleanup_staging(op.staging_key)

              {:error, reason} when reason in [:not_found, :forbidden] ->
                fail(op, reason, fence: fn _ -> :ok end)

              _ ->
                OperationLease.release(AssetOperation, op)
            end
          end

        {:error, reason} when reason in [:integrity_mismatch, :invalid_source, :not_found] ->
          if reason == :integrity_mismatch,
            do:
              Repo.update_all(from(b in AssetBlob, where: b.storage_key == ^op.storage_key),
                set: [state: :corrupt]
              )

          fail(op, reason, fence: fn _ -> :ok end)

        _ ->
          OperationLease.release(AssetOperation, op)
      end
    end)
  end

  def collect_garbage do
    blobs =
      Repo.all(
        from b in AssetBlob,
          where: b.state in [:pending, :ready, :candidate, :deleting],
          limit: 100,
          order_by: b.updated_at
      )

    Enum.each(blobs, fn blob ->
      ForgeBlobs.with_digest_lock(blob.storage_key, fn -> collect_blob(blob.storage_key) end)
    end)

    :ok
  end

  defp collect_blob(key) do
    blob = Repo.get!(AssetBlob, key)

    unless referenced?(key) do
      cond do
        blob.state in [:pending, :ready] ->
          Repo.update!(
            Ecto.Changeset.change(blob,
              state: :candidate,
              gc_after: DateTime.add(now(), Fornacast.Config.blob_gc_grace_seconds()),
              version: blob.version + 1
            )
          )

        blob.state == :deleting or
            (blob.state == :candidate and DateTime.compare(blob.gc_after, now()) != :gt) ->
          Repo.update!(Ecto.Changeset.change(blob, state: :deleting, version: blob.version + 1))

          case bounded(key, fn -> AssetStorage.delete(key) end) do
            :ok ->
              Repo.update_all(from(b in AssetBlob, where: b.storage_key == ^key),
                set: [state: :absent, gc_after: nil],
                inc: [version: 1]
              )

            _ ->
              :ok
          end

        true ->
          :ok
      end
    end
  end

  defp referenced?(key) do
    Repo.exists?(from a in Asset, where: a.storage_key == ^key and a.state != :deleted) or
      Repo.exists?(
        from o in AssetOperation,
          where: o.storage_key == ^key and o.state not in [:completed, :failed]
      ) or
      Repo.exists?(from l in "lfs_objects", where: l.storage_key == ^key)
  end

  defp touch_blob!(key, size) do
    case Repo.get(AssetBlob, key) do
      nil ->
        Repo.insert!(%AssetBlob{storage_key: key, size: size, state: :pending})

      %AssetBlob{size: ^size, state: state} = blob
      when state in [:pending, :ready, :candidate, :absent] ->
        Repo.update!(
          Ecto.Changeset.change(blob, state: :pending, gc_after: nil, version: blob.version + 1)
        )

      _ ->
        Repo.rollback(:integrity_mismatch)
    end
  end

  defp fail(op, reason, options) do
    result =
      Repo.transaction(fn ->
        check!(options[:fence], Repo)

        case OperationLease.update_owned(AssetOperation, op,
               state: :failed,
               failure: sanitized_failure(reason)
             ) do
          {:ok, _} ->
            Repo.update_all(from(a in Asset, where: a.id == ^op.asset_id and a.state == :pending),
              set: [state: :deleted]
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    if match?({:ok, _}, result), do: AssetStorage.cleanup_staging(op.staging_key)
    result
  end

  defp local_fence(actor, repository, release_id) do
    fn repo ->
      current =
        repo.one(
          from r in ForgeRepos.Repository,
            where:
              r.id == ^repository.id and r.generation == ^repository.generation and
                r.lifecycle == :ready and is_nil(r.deleted_at),
            lock: "FOR UPDATE"
        )

      current_actor = if actor, do: ForgeAccounts.get_account(actor.id)

      release =
        repo.one(
          from r in Release,
            where:
              r.id == ^release_id and r.repository_id == ^repository.id and is_nil(r.deleted_at),
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) or is_nil(release) ->
          {:error, :not_found}

        not Fornacast.Access.allowed?(current_actor, :repository_write, current) ->
          {:error, :forbidden}

        release.immutable and not release.draft ->
          invalid(:immutable)

        true ->
          :ok
      end
    end
  end

  defp mutable!(%Release{immutable: true, draft: false}),
    do: Repo.rollback(elem(invalid(:immutable), 1))

  defp mutable!(_), do: :ok

  defp check!(fence, repo) do
    case fence.(repo) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp renew(op, options) do
    Repo.transaction(fn ->
      check!(options[:fence], Repo)

      case OperationLease.renew_owned(AssetOperation, op,
             now: now(),
             lease_seconds: @lease_seconds
           ) do
        {:ok, renewed} -> renewed
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp owned_update!(op, updates) do
    case OperationLease.update_owned(AssetOperation, op, updates,
           now: now(),
           lease_seconds: @lease_seconds
         ) do
      {:ok, next} -> next
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp heartbeat(options), do: Keyword.get(options, :heartbeat, fn -> :ok end).()

  if Mix.env() == :test do
    defp after_commit(options), do: Keyword.get(options, :test_after_commit, fn -> :ok end).()
  else
    defp after_commit(_options), do: :ok
  end

  defp bounded(digest, fun), do: ForgeReleases.StorageTask.run(digest, fun)

  defp validate_source!(attrs) do
    for key <- ["size", "source_download_count", "source_asset_id"], value = attrs[key] do
      unless is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807,
        do: Repo.rollback(:invalid_source)
    end

    if is_integer(attrs["size"]) and attrs["size"] > Fornacast.Config.blob_max_bytes(),
      do: Repo.rollback(:entity_too_large)

    digest = attrs["source_digest"]

    if not is_nil(digest) and
         (not is_binary(digest) or not Regex.match?(~r/\A(?:sha256:)?[0-9a-f]{64}\z/, digest)),
       do: Repo.rollback(:invalid_source)
  end

  defp expected_content?(attrs, metadata) do
    (is_nil(attrs["size"]) or attrs["size"] == metadata.size) and
      (is_nil(attrs["source_digest"]) or
         String.replace_prefix(attrs["source_digest"], "sha256:", "") == metadata.sha256_digest)
  end

  defp reserve_quota!(release_id) do
    # The release row is already locked; pending names count toward admission.
    count =
      Repo.aggregate(
        from(a in Asset, where: a.release_id == ^release_id and a.state != :deleted),
        :count
      )

    if count >= @maximum_assets_per_release, do: Repo.rollback(elem(invalid(:asset_count), 1))
  end

  defp audit!(actor, action, asset, metadata) do
    multi =
      Ecto.Multi.new()
      |> Audit.record_multi(
        :asset_audit,
        actor,
        action,
        "release_asset",
        asset.id,
        %{"repository_id" => asset.repository_id, "result" => "success"},
        request_metadata: metadata
      )

    case Repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, _, reason, _} -> Repo.rollback(reason)
    end
  end

  defp insert!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(validation(changeset))
    end
  end

  defp insert_or_update!(changeset) do
    case Repo.update(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(validation(changeset))
    end
  end

  defp validation(changeset),
    do:
      {:validation,
       Enum.map(changeset.errors, fn {key, _} ->
         %{resource: "ReleaseAsset", field: Atom.to_string(key), code: :invalid}
       end)}

  defp invalid(field),
    do:
      {:error,
       {:validation, [%{resource: "ReleaseAsset", field: Atom.to_string(field), code: :invalid}]}}

  defp storage_error(:not_found), do: {:error, :not_found}
  defp storage_error(_), do: {:error, {:unavailable, :asset_storage}}
  defp sanitized_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitized_failure(_), do: "transfer_failed"

  defp decorate(asset) do
    uploader =
      if asset.uploader_user_id,
        do: ForgeAccounts.get_account(asset.uploader_user_id),
        else: Repo.get(ForgeAccounts.GitHubIdentity, asset.uploader_github_identity_id)

    %{asset | uploader: uploader}
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp string_keys(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  defp now, do: DateTime.utc_now(:second)

  defp with_operation_lock(key, fun),
    do: :global.trans({{__MODULE__, key}, self()}, fun, [node()])

  defp try_operation_lock(key, fun) do
    lock = {{__MODULE__, key}, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        fun.()
      after
        :global.del_lock(lock, [node()])
      end
    end
  end
end
