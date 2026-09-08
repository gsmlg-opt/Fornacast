defmodule ForgeIssues.LabelSync do
  @moduledoc """
  Trusted, transactional label identity materialization for synchronization.

  Repository authorization and operation leases belong to the coordinator.
  Adoption never changes existing label metadata. Observations lock and compare
  both the monotonic version and complete metadata before mapping confirmation.
  """
  import Ecto.Query
  alias Ecto.Multi
  alias ForgeIssues.{DefaultLabels, Label}
  alias Fornacast.{Audit, DomainOutbox, Repo}

  @max_id 9_223_372_036_854_775_807
  defguardp valid_id(id) when is_integer(id) and id > 0 and id <= @max_id

  def label_sync_projection(repository_id, label_id) do
    case Repo.transaction(fn ->
           with :ok <- repository(Repo, repository_id),
                {:ok, label} <- label(Repo, repository_id, label_id) do
             projection(label)
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def append_sync_label_observe(%Multi{} = multi, key, expected) do
    Multi.run(multi, key, fn repo, _ ->
      with :ok <- validate_expected(expected),
           {:ok, fields} <- canonical_fields(expected.expected_fields),
           :ok <- repository(repo, expected.repository_id),
           {:ok, label} <- label(repo, expected.repository_id, expected.local_resource_id),
           :ok <- observation_matches(label, expected, fields) do
        {:ok, projection(label)}
      end
    end)
  end

  def append_sync_label_import(%Multi{} = multi, key, request) do
    write_key = {key, :label_write}

    multi
    |> Multi.run(write_key, fn repo, _ ->
      with :ok <- validate_import(request),
           {:ok, fields} <- canonical_fields(request.fields),
           :ok <- repository(repo, request.repository_id),
           {:ok, inserted} <-
             repo.insert(
               Label.import_changeset(
                 %Label{},
                 Map.merge(fields, %{
                   "repository_id" => request.repository_id,
                   "normalized_name" => DefaultLabels.normalize_name(fields["name"])
                 })
               ),
               on_conflict: :nothing,
               conflict_target: [:repository_id, :normalized_name]
             ),
           %Label{} = label <-
             repo.one(
               from l in Label,
                 where:
                   l.repository_id == ^request.repository_id and
                     l.normalized_name == ^DefaultLabels.normalize_name(fields["name"]),
                 lock: "FOR UPDATE"
             ),
           true <- fields(label) == fields || {:error, :namespace_collision} do
        {:ok, %{label: label, created?: not is_nil(inserted.id)}}
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.merge(fn changes ->
      case Map.fetch!(changes, write_key) do
        %{created?: true, label: label} ->
          Multi.new()
          |> DomainOutbox.record_multi({key, :label_outbox}, %{
            event_id: Ecto.UUID.generate(),
            aggregate_type: "label",
            aggregate_id: to_string(label.id),
            event_type: "label.created",
            origin: :github,
            causation_id: request.provenance[:causation_id],
            correlation_id: request.provenance[:correlation_id],
            payload: %{
              "repository_id" => label.repository_id,
              "label_id" => label.id,
              "sync_version" => label.sync_version
            }
          })
          |> Audit.record_multi(
            {key, :label_audit},
            nil,
            "github_sync.label_created",
            "label",
            label.id,
            %{
              "repository_id" => label.repository_id,
              "label_id" => label.id,
              "result" => "success"
            }
          )

        %{created?: false} ->
          Multi.new()
      end
    end)
    |> Multi.run(key, fn _repo, changes ->
      {:ok, projection(Map.fetch!(changes, write_key).label)}
    end)
  end

  defp validate_import(%{repository_id: id, fields: fields, provenance: %{origin: :github}})
       when valid_id(id) and is_map(fields), do: :ok

  defp validate_import(_), do: {:error, :invalid_sync_request}

  defp validate_expected(
         %{
           repository_id: repository_id,
           local_resource_id: id,
           expected_local_version: version,
           expected_fields: fields
         } = expected
       )
       when valid_id(repository_id) and valid_id(id) and valid_id(version) and is_map(fields) and
              not is_map_key(expected, :minimum_local_version),
       do: :ok

  defp validate_expected(
         %{
           repository_id: repository_id,
           local_resource_id: id,
           minimum_local_version: version,
           expected_fields: fields
         } = expected
       )
       when valid_id(repository_id) and valid_id(id) and valid_id(version) and is_map(fields) and
              not is_map_key(expected, :expected_local_version),
       do: :ok

  defp validate_expected(_), do: {:error, :invalid_sync_request}

  # Historical effect recovery observes the current row without acknowledging or
  # overwriting newer metadata. Only the coordinator may confirm its saved target.
  defp observation_matches(label, %{minimum_local_version: minimum}, expected_fields) do
    cond do
      label.sync_version < minimum ->
        {:error, :stale_local_version}

      label.sync_version == minimum and fields(label) != expected_fields ->
        {:error, :stale_local_snapshot}

      true ->
        :ok
    end
  end

  defp observation_matches(label, %{expected_local_version: version}, expected_fields) do
    cond do
      label.sync_version != version -> {:error, :stale_local_version}
      fields(label) != expected_fields -> {:error, :stale_local_snapshot}
      true -> :ok
    end
  end

  defp canonical_fields(
         %{"name" => name, "color" => color, "description" => description} = fields
       )
       when map_size(fields) == 3 and is_binary(name) and byte_size(name) <= 1020 and
              is_binary(color) and byte_size(color) == 6 do
    color = String.downcase(color)

    if valid_text?(name, 255) and String.trim(name) != "" and
         Regex.match?(~r/^[0-9a-f]{6}$/, color) and
         (is_nil(description) or valid_text?(description, 100)) do
      description =
        if is_binary(description) and String.trim(description) == "", do: nil, else: description

      {:ok, %{"name" => name, "color" => color, "description" => description}}
    else
      {:error, :invalid_sync_request}
    end
  end

  defp canonical_fields(_), do: {:error, :invalid_sync_request}

  defp valid_text?(value, limit) when is_binary(value),
    do:
      String.valid?(value) and byte_size(value) <= limit * 4 and String.length(value) <= limit and
        :binary.match(value, <<0>>) == :nomatch

  defp valid_text?(_, _), do: false

  defp repository(repo, id) when valid_id(id) do
    if repo.exists?(
         from r in ForgeRepos.Repository,
           where: r.id == ^id and is_nil(r.deleted_at) and r.lifecycle in [:ready, :synchronizing]
       ), do: :ok, else: {:error, :not_found}
  end

  defp repository(_, _), do: {:error, :not_found}

  defp label(repo, repository_id, id) when valid_id(id) do
    case repo.one(
           from l in Label,
             where: l.id == ^id and l.repository_id == ^repository_id,
             lock: "FOR UPDATE"
         ) do
      %Label{} = label -> {:ok, label}
      nil -> {:error, :not_found}
    end
  end

  defp label(_, _, _), do: {:error, :not_found}

  defp fields(label),
    do: %{"name" => label.name, "color" => label.color, "description" => label.description}

  defp projection(label),
    do: %{
      repository_id: label.repository_id,
      resource_kind: :label,
      local_resource_id: label.id,
      local_resource_type: "ForgeIssues.Label",
      local_version: label.sync_version,
      fields: fields(label)
    }
end
