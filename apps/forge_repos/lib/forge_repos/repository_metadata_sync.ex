defmodule ForgeRepos.RepositoryMetadataSync do
  @moduledoc false

  import Ecto.Query

  alias ForgeRepos.Repository
  alias Fornacast.{DomainOutbox, Repo}

  @metadata_fields [:name, :slug, :description, :visibility, :default_branch]
  @remote_fields [:name, :description, :visibility, :default_branch]
  @max_identifier_bytes 255

  def apply(input) when is_map(input) do
    with {:ok, input} <- normalize_input(input),
         {:ok, repository} <- transact(input) do
      {:ok, repository}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def apply(_input), do: {:error, :invalid_argument}

  defp normalize_input(input) do
    with {:ok, repository_id} <- fetch_and_validate(input, :repository_id, &positive/1),
         {:ok, owner_user_id} <- fetch_and_validate(input, :owner_user_id, &positive/1),
         {:ok, generation} <- fetch_and_validate(input, :generation, &positive/1),
         {:ok, write_version} <- fetch_and_validate(input, :write_version, &non_negative/1),
         {:ok, expected} <- fetch_and_validate(input, :expected, &exact_metadata/1),
         {:ok, remote} <- fetch_and_validate(input, :remote, &remote_metadata/1),
         :ok <- fetch_and_validate(input, :causation_id, &bounded_identifier/1),
         :ok <- fetch_and_validate(input, :correlation_id, &bounded_identifier/1) do
      {:ok,
       %{
         input
         | repository_id: repository_id,
           owner_user_id: owner_user_id,
           generation: generation,
           write_version: write_version,
           expected: expected,
           remote: remote
       }}
    else
      {:error, :unsupported_remote_metadata} = error -> error
      _invalid -> {:error, :invalid_argument}
    end
  end

  defp transact(input) do
    if Repo.in_transaction?() do
      apply_in_transaction(input)
    else
      Repo.transaction(fn ->
        case apply_in_transaction(input) do
          {:ok, repository} -> repository
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, repository} -> {:ok, repository}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp apply_in_transaction(input) do
    with {:ok, repository} <- lock_expected_repository(Repo, input),
         :ok <- validate_default_branch(repository, input.remote.default_branch),
         {:ok, updated} <- update_repository(repository, input.remote) do
      case DomainOutbox.record(event_attrs(updated, input)) do
        {:ok, _event} -> {:ok, updated}
        {:error, reason} -> Repo.rollback({:outbox, reason})
      end
    end
  end

  defp update_repository(repository, remote) do
    repository
    |> Repository.api_update_changeset(remote)
    |> Ecto.Changeset.optimistic_lock(:write_version)
    |> Repo.update(mode: :savepoint)
    |> case do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if namespace_collision?(changeset), do: {:error, :namespace_collision}, else: error

      result ->
        result
    end
  end

  defp lock_expected_repository(_repo, input) do
    case Repo.one(
           from repository in Repository,
             where:
               repository.id == ^input.repository_id and
                 repository.owner_user_id == ^input.owner_user_id and
                 repository.generation == ^input.generation and
                 repository.write_version == ^input.write_version and
                 repository.lifecycle in [:ready, :synchronizing] and
                 is_nil(repository.deleted_at),
             lock: "FOR UPDATE"
         ) do
      %Repository{} = repository ->
        if metadata(repository) == input.expected, do: {:ok, repository}, else: {:error, :stale}

      nil ->
        {:error, :stale}
    end
  end

  defp validate_default_branch(repository, branch) when branch == repository.default_branch,
    do: :ok

  defp validate_default_branch(repository, branch),
    do: ForgeRepos.validate_sync_default_branch(repository, branch)

  defp exact_metadata(value) when is_map(value) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(@metadata_fields) and
         is_binary(value.name) and is_binary(value.slug) and
         (is_nil(value.description) or is_binary(value.description)) and
         value.visibility in [:public, :private] and is_binary(value.default_branch) do
      {:ok, value}
    else
      {:error, :invalid_argument}
    end
  end

  defp exact_metadata(_), do: {:error, :invalid_argument}

  defp remote_metadata(value) when is_map(value) do
    cond do
      Map.has_key?(value, :archived) or Map.has_key?(value, :internal) ->
        {:error, :unsupported_remote_metadata}

      Map.keys(value) |> Enum.sort() != Enum.sort(@remote_fields) ->
        {:error, :invalid_argument}

      value.visibility not in [:public, :private] ->
        {:error, :unsupported_remote_metadata}

      not is_binary(value.name) or not is_binary(value.default_branch) or
          not (is_nil(value.description) or is_binary(value.description)) ->
        {:error, :invalid_argument}

      true ->
        {:ok,
         value
         |> Map.put(:name, String.trim(value.name))
         |> Map.put(:slug, Repository.normalize_slug(value.name))}
    end
  end

  defp remote_metadata(_), do: {:error, :invalid_argument}

  defp metadata(repository), do: Map.take(repository, @metadata_fields)

  defp event_attrs(repository, input) do
    %{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(repository.id),
      event_type: "repository.updated",
      origin: :github,
      causation_id: input.causation_id,
      correlation_id: input.correlation_id,
      payload: %{
        "repository_id" => repository.id,
        "owner_id" => repository.owner_user_id,
        "slug" => repository.slug,
        "visibility" => Atom.to_string(repository.visibility),
        "default_branch" => repository.default_branch,
        "generation" => repository.generation,
        "write_version" => repository.write_version
      }
    }
  end

  defp positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(_), do: {:error, :invalid_argument}
  defp non_negative(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative(_), do: {:error, :invalid_argument}

  defp bounded_identifier(value)
       when is_binary(value) and byte_size(value) in 1..@max_identifier_bytes do
    if String.valid?(value) and value == String.trim(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, :invalid_argument}
  end

  defp bounded_identifier(_), do: {:error, :invalid_argument}

  defp fetch_and_validate(input, key, validator) do
    case Map.fetch(input, key) do
      {:ok, value} -> validator.(value)
      :error -> {:error, :invalid_argument}
    end
  end

  defp namespace_collision?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, options}} ->
      options[:constraint] == :unique and
        to_string(options[:constraint_name]) =~ "repositories_owner_user_id_slug"
    end)
  end
end
