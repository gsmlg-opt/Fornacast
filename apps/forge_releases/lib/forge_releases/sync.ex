defmodule ForgeReleases.Sync do
  @moduledoc """
  Trusted release synchronization boundary.

  Coordinators own provider mappings, confirmed tag baselines, and operation
  leases. This module atomically projects or applies canonical metadata. GitHub
  writes are audited and emit provider-origin events so outbound consumers can
  suppress echoes without losing durable local observation.
  `published_at` is part of confirmed snapshots but only canonical provider
  responses may write it.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeReleases.Release
  alias Fornacast.{Audit, DomainOutbox, Repo}

  @max_id 9_223_372_036_854_775_807
  @max_body_codepoints 65_536
  @max_body_bytes 262_144
  @field_keys ~w(body draft name prerelease published_at tag_name target_commitish)
  @create_keys ~w(action author_github_identity_id expected_fields expected_local_version fields inserted_at local_resource_id provenance repository_id tag_proof updated_at)a
  @update_keys ~w(action expected_deleted expected_fields expected_local_version fields local_resource_id provenance repository_id tag_proof updated_at)a
  @delete_keys ~w(action expected_deleted expected_fields expected_local_version fields local_resource_id provenance repository_id updated_at)a
  @exact_observation_keys ~w(expected_deleted expected_fields expected_local_version local_resource_id repository_id)a
  @minimum_observation_keys ~w(expected_deleted expected_fields local_resource_id minimum_local_version repository_id)a
  @provenance_keys ~w(causation_id correlation_id origin)a
  @tag_proof_keys ~w(confirmed_at confirmed_oid local_oid ref_name ref_state_lock_version remote_oid repository_id tag_name)a
  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  defguardp valid_id(id) when is_integer(id) and id > 0 and id <= @max_id

  def release_sync_projection(repository_id, release_id) do
    case Repo.transaction(fn ->
           with :ok <- repository(Repo, repository_id),
                {:ok, release} <- release(Repo, repository_id, release_id) do
             projection(release)
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def append_sync_release_observe(%Multi{} = multi, key, expected) do
    Multi.run(multi, key, fn repo, _changes ->
      with :ok <- validate_expected(expected),
           {:ok, expected_fields} <- canonical_fields(expected.expected_fields),
           :ok <- repository(repo, expected.repository_id),
           {:ok, release} <- release(repo, expected.repository_id, expected.local_resource_id),
           :ok <- observation_matches(release, expected, expected_fields) do
        {:ok, projection(release)}
      end
    end)
  end

  def append_sync_release_apply(%Multi{} = multi, key, request) do
    write_key = {key, :sync_write}

    multi
    |> Multi.run(write_key, fn repo, _changes ->
      with :ok <- validate_request(request),
           :ok <- repository(repo, request.repository_id),
           {:ok, release} <- apply_release(repo, request) do
        {:ok, release}
      end
    end)
    |> DomainOutbox.record_multi({key, :sync_outbox}, fn changes ->
      release = Map.fetch!(changes, write_key)

      %{
        event_id: Ecto.UUID.generate(),
        aggregate_type: "release",
        aggregate_id: to_string(release.id),
        event_type: event_type(request.action),
        origin: :github,
        causation_id: provenance_value(request, :causation_id),
        correlation_id: provenance_value(request, :correlation_id),
        payload: cursor(release)
      }
    end)
    |> Audit.record_multi(
      {key, :sync_audit},
      nil,
      audit_action(request),
      "release",
      fn changes -> Map.fetch!(changes, write_key).id end,
      fn changes ->
        release = Map.fetch!(changes, write_key)

        %{
          "repository_id" => release.repository_id,
          "release_id" => release.id,
          "sync_version" => release.sync_version,
          "result" => "success"
        }
      end,
      operation_id: provenance_value(request, :correlation_id),
      request_id: provenance_value(request, :causation_id)
    )
    |> Multi.run(key, fn _repo, changes ->
      {:ok, projection(Map.fetch!(changes, write_key))}
    end)
  end

  defp validate_request(
         %{
           action: :create,
           repository_id: repository_id,
           local_resource_id: nil,
           expected_local_version: :missing,
           expected_fields: expected_fields,
           fields: fields,
           tag_proof: tag_proof,
           author_github_identity_id: author_id,
           inserted_at: %DateTime{},
           updated_at: %DateTime{},
           provenance: %{origin: :github}
         } = request
       )
       when valid_id(repository_id) and valid_id(author_id) and map_size(expected_fields) == 0 and
              is_map(fields) do
    with true <- exact_keys?(request, @create_keys),
         true <- valid_provenance?(request.provenance),
         true <- valid_time?(request.inserted_at),
         true <- valid_time?(request.updated_at),
         true <- DateTime.compare(request.inserted_at, request.updated_at) != :gt,
         :ok <- validate_canonical_fields(fields),
         :ok <- validate_tag_proof(tag_proof, repository_id, fields) do
      :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_sync_request}
    end
  end

  defp validate_request(
         %{
           action: :update,
           repository_id: repository_id,
           local_resource_id: release_id,
           expected_local_version: version,
           expected_fields: expected_fields,
           expected_deleted: false,
           fields: fields,
           tag_proof: tag_proof,
           updated_at: %DateTime{},
           provenance: %{origin: :github}
         } = request
       )
       when valid_id(repository_id) and valid_id(release_id) and valid_id(version) and
              is_map(expected_fields) and is_map(fields) do
    with true <- exact_keys?(request, @update_keys),
         true <- valid_provenance?(request.provenance),
         true <- valid_time?(request.updated_at),
         :ok <- validate_canonical_fields(expected_fields),
         :ok <- validate_canonical_fields(fields),
         :ok <- validate_tag_proof(tag_proof, repository_id, fields) do
      :ok
    else
      false -> {:error, :invalid_sync_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_request(
         %{
           action: :delete,
           repository_id: repository_id,
           local_resource_id: release_id,
           expected_local_version: version,
           expected_fields: expected_fields,
           expected_deleted: false,
           fields: fields,
           updated_at: %DateTime{},
           provenance: %{origin: :github}
         } = request
       )
       when valid_id(repository_id) and valid_id(release_id) and valid_id(version) and
              is_map(expected_fields) and is_map(fields) and map_size(fields) == 0 do
    with true <- exact_keys?(request, @delete_keys),
         true <- valid_provenance?(request.provenance),
         true <- valid_time?(request.updated_at),
         :ok <- validate_canonical_fields(expected_fields) do
      :ok
    else
      false -> {:error, :invalid_sync_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_request(_request), do: {:error, :invalid_sync_request}

  defp validate_expected(
         %{
           repository_id: repository_id,
           local_resource_id: release_id,
           expected_local_version: version,
           expected_fields: fields,
           expected_deleted: deleted
         } = expected
       )
       when valid_id(repository_id) and valid_id(release_id) and valid_id(version) and
              is_map(fields) and is_boolean(deleted) do
    if exact_keys?(expected, @exact_observation_keys),
      do: validate_canonical_fields(fields),
      else: {:error, :invalid_sync_request}
  end

  defp validate_expected(
         %{
           repository_id: repository_id,
           local_resource_id: release_id,
           minimum_local_version: version,
           expected_fields: fields,
           expected_deleted: deleted
         } = expected
       )
       when valid_id(repository_id) and valid_id(release_id) and valid_id(version) and
              is_map(fields) and is_boolean(deleted) do
    if exact_keys?(expected, @minimum_observation_keys),
      do: validate_canonical_fields(fields),
      else: {:error, :invalid_sync_request}
  end

  defp validate_expected(_expected), do: {:error, :invalid_sync_request}

  defp validate_canonical_fields(fields) do
    case canonical_fields(fields) do
      {:ok, _fields} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_fields(
         %{
           "tag_name" => tag_name,
           "name" => name,
           "body" => body,
           "draft" => draft,
           "prerelease" => prerelease,
           "target_commitish" => target_commitish,
           "published_at" => published_at
         } = fields
       )
       when map_size(fields) == 7 and is_boolean(draft) and is_boolean(prerelease) do
    valid_publication =
      (draft and is_nil(published_at)) or (not draft and valid_time?(published_at))

    if Enum.sort(Map.keys(fields)) == @field_keys and valid_text?(tag_name, 255, false) and
         tag_name != "" and valid_text?(target_commitish, 255, false) and
         target_commitish != "" and valid_text?(name, 255, true) and
         valid_text?(body, @max_body_codepoints, true, :codepoints) and
         valid_text?(body, @max_body_bytes, true, :bytes) and valid_publication do
      {:ok, fields}
    else
      {:error, :invalid_sync_request}
    end
  end

  defp canonical_fields(_fields), do: {:error, :invalid_sync_request}

  defp valid_text?(nil, _limit, true), do: true

  defp valid_text?(value, limit, _nullable) when is_binary(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      (limit == :unbounded or String.length(value) <= limit)
  end

  defp valid_text?(_value, _limit, _nullable), do: false

  defp valid_text?(nil, _limit, true, _count), do: true

  defp valid_text?(value, limit, _nullable, :codepoints) when is_binary(value),
    do:
      String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
        length(:unicode.characters_to_list(value)) <= limit

  defp valid_text?(value, limit, _nullable, :bytes) when is_binary(value),
    do:
      String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
        byte_size(value) <= limit

  defp valid_text?(_value, _limit, _nullable, _count), do: false

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp valid_provenance?(%{origin: :github} = provenance) do
    Enum.all?(Map.keys(provenance), &(&1 in @provenance_keys)) and
      Enum.all?(
        [Map.get(provenance, :causation_id), Map.get(provenance, :correlation_id)],
        &bounded_identifier?/1
      )
  end

  defp bounded_identifier?(nil), do: true

  defp bounded_identifier?(value) when is_binary(value),
    do:
      value != "" and value == String.trim(value) and String.valid?(value) and
        :binary.match(value, <<0>>) == :nomatch and byte_size(value) <= 255

  defp bounded_identifier?(_value), do: false

  defp valid_time?(%DateTime{
         time_zone: "Etc/UTC",
         utc_offset: 0,
         std_offset: 0,
         microsecond: {0, _precision}
       }),
       do: true

  defp valid_time?(_value), do: false

  defp validate_tag_proof(
         %{
           tag_name: tag_name,
           ref_name: ref_name,
           confirmed_oid: confirmed_oid,
           local_oid: local_oid,
           remote_oid: remote_oid,
           confirmed_at: confirmed_at,
           ref_state_lock_version: lock_version,
           repository_id: proof_repository_id
         } = proof,
         repository_id,
         fields
       ) do
    if exact_keys?(proof, @tag_proof_keys) and proof_repository_id == repository_id and
         tag_name == fields["tag_name"] and ref_name == "refs/tags/#{tag_name}" and
         valid_id(lock_version) and canonical_oid?(confirmed_oid) and
         local_oid == confirmed_oid and remote_oid == confirmed_oid and valid_time?(confirmed_at),
       do: :ok,
       else: {:error, :invalid_sync_request}
  end

  defp validate_tag_proof(_proof, _repository_id, _fields),
    do: {:error, :invalid_sync_request}

  defp canonical_oid?(oid) when is_binary(oid), do: Regex.match?(@oid_pattern, oid)
  defp canonical_oid?(_oid), do: false

  defp repository(repo, repository_id) when valid_id(repository_id) do
    if repo.exists?(
         from repository in ForgeRepos.Repository,
           where:
             repository.id == ^repository_id and is_nil(repository.deleted_at) and
               repository.lifecycle in [:ready, :synchronizing]
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  defp repository(_repo, _repository_id), do: {:error, :not_found}

  defp release(repo, repository_id, release_id)
       when valid_id(repository_id) and valid_id(release_id) do
    case repo.one(
           from release in Release,
             where: release.id == ^release_id and release.repository_id == ^repository_id,
             lock: "FOR UPDATE"
         ) do
      %Release{} = release -> {:ok, release}
      nil -> {:error, :not_found}
    end
  end

  defp release(_repo, _repository_id, _release_id), do: {:error, :not_found}

  defp apply_release(repo, %{action: :create} = request) do
    with :ok <- author_exists(request.author_github_identity_id),
         {:ok, fields} <- canonical_fields(request.fields),
         {:ok, release} <-
           repo.insert(
             Release.import_changeset(
               %Release{
                 repository_id: request.repository_id,
                 author_github_identity_id: request.author_github_identity_id
               },
               fields
               |> Map.put("inserted_at", request.inserted_at)
               |> Map.put("updated_at", request.updated_at)
             )
           ) do
      {:ok, release}
    else
      {:error, %Ecto.Changeset{} = changeset} -> changeset_error(changeset)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_release(repo, request) do
    with {:ok, release} <- release(repo, request.repository_id, request.local_resource_id),
         {:ok, expected_fields} <- canonical_fields(request.expected_fields),
         :ok <- exact_snapshot(release, request, expected_fields) do
      mutate(repo, release, request)
    end
  end

  defp mutate(repo, release, %{action: :update} = request) do
    release
    |> Release.sync_changeset(Map.put(request.fields, "updated_at", request.updated_at))
    |> repo.update(force: true, stale_error_field: :id)
    |> mutation_result()
  end

  defp mutate(repo, release, %{action: :delete} = request) do
    release
    |> Release.sync_delete_changeset(request.updated_at)
    |> repo.update(force: true, stale_error_field: :id)
    |> mutation_result()
  end

  defp mutation_result({:ok, release}), do: {:ok, release}

  defp mutation_result({:error, %Ecto.Changeset{} = changeset}) do
    if Enum.any?(changeset.errors, fn {_field, {_message, metadata}} -> metadata[:stale] end),
      do: {:error, :stale_local_version},
      else: changeset_error(changeset)
  end

  defp changeset_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
         metadata[:constraint] == :unique and
           metadata[:constraint_name] == "releases_active_repository_tag_index"
       end),
       do: {:error, :namespace_collision},
       else: {:error, :invalid_sync_request}
  end

  defp exact_snapshot(release, expected, expected_fields) do
    if release.sync_version == expected.expected_local_version,
      do: snapshot_matches(release, expected, expected_fields),
      else: {:error, :stale_local_version}
  end

  defp observation_matches(
         release,
         %{minimum_local_version: minimum} = expected,
         expected_fields
       ) do
    cond do
      release.sync_version < minimum ->
        {:error, :stale_local_version}

      release.sync_version == minimum ->
        snapshot_matches(release, expected, expected_fields)

      true ->
        :ok
    end
  end

  defp observation_matches(release, expected, expected_fields),
    do: exact_snapshot(release, expected, expected_fields)

  defp snapshot_matches(release, expected, expected_fields) do
    if fields(release) == expected_fields and
         not is_nil(release.deleted_at) == expected.expected_deleted,
       do: :ok,
       else: {:error, :stale_local_snapshot}
  end

  defp author_exists(identity_id) do
    if Map.has_key?(
         ForgeAccounts.resolve_attributions([{:github, identity_id}]),
         {:github, identity_id}
       ),
       do: :ok,
       else: {:error, :invalid_author}
  end

  defp fields(release) do
    %{
      "tag_name" => release.tag_name,
      "name" => release.name,
      "body" => release.body,
      "draft" => release.draft,
      "prerelease" => release.prerelease,
      "target_commitish" => release.target_commitish,
      "published_at" => release.published_at
    }
  end

  defp projection(release) do
    %{
      repository_id: release.repository_id,
      resource_kind: :release,
      local_resource_id: release.id,
      local_resource_type: "ForgeReleases.Release",
      local_version: release.sync_version,
      deleted: not is_nil(release.deleted_at),
      fields: fields(release)
    }
  end

  defp cursor(release) do
    %{
      "repository_id" => release.repository_id,
      "release_id" => release.id,
      "tag_name" => release.tag_name,
      "sync_version" => release.sync_version,
      "deleted" => not is_nil(release.deleted_at)
    }
  end

  defp event_type(:create), do: "release.created"
  defp event_type(:update), do: "release.updated"
  defp event_type(:delete), do: "release.deleted"

  defp audit_action(%{action: :create}), do: "github_sync.release_created"
  defp audit_action(%{action: :update}), do: "github_sync.release_updated"
  defp audit_action(%{action: :delete}), do: "github_sync.release_deleted"
  defp audit_action(_request), do: "github_sync.release_invalid"

  defp provenance_value(%{provenance: provenance}, key) when is_map(provenance),
    do: Map.get(provenance, key)

  defp provenance_value(_request, _key), do: nil
end
