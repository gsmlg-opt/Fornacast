defmodule ForgeImports.Destination do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.{Namespace, Organization, OrganizationMember, User}
  alias ForgeImports.GitHub.Repository, as: GitHubRepository
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  @type organization_plan :: %{
          action: :new | :existing,
          slug: String.t() | nil,
          organization_id: pos_integer() | nil,
          owner_id: pos_integer() | nil,
          status: :clean | :conflict | :invalid,
          classification: String.t() | nil
        }

  @spec personal(User.t()) :: {:ok, organization_plan()} | {:error, :invalid_destination}
  def personal(%User{id: actor_id, username: username, kind: :user, state: :active})
      when is_integer(actor_id) and actor_id > 0 do
    case Namespace.validate(username) do
      {:ok, _slug} ->
        {:ok,
         %{
           action: :existing,
           slug: username,
           requested_slug: username,
           submitted_slug: username,
           organization_id: nil,
           owner_id: actor_id,
           status: :clean,
           classification: nil
         }}

      _invalid_or_reserved ->
        {:error, :invalid_destination}
    end
  end

  def personal(_actor), do: {:error, :invalid_destination}

  @spec organization(User.t(), String.t(), map()) ::
          {:ok, organization_plan()} | {:error, :invalid_destination | :not_found}
  def organization(%User{id: actor_id}, source_login, destination)
      when is_integer(actor_id) and actor_id > 0 and is_binary(source_login) and
             is_map(destination) do
    case action(destination) do
      :new -> new_organization(source_login, destination)
      :existing -> existing_organization(actor_id, destination)
      _invalid -> {:error, :invalid_destination}
    end
  end

  def organization(_actor, _source_login, _destination), do: {:error, :invalid_destination}

  @doc false
  def safety_profiles(%{submitted_slug: nil}), do: {:ok, []}

  def safety_profiles(%{submitted_slug: value}) when is_binary(value) do
    normalized = String.downcase(String.trim(value))

    cond do
      not String.valid?(value) or byte_size(value) > 2_048 or
          :binary.match(value, <<0>>) != :nomatch ->
        {:error, :invalid_destination}

      String.contains?(normalized, "://") or String.starts_with?(normalized, "www.") ->
        {:error, :invalid_destination}

      true ->
        {:ok, [%{login: value}]}
    end
  end

  def safety_profiles(_destination), do: {:error, :invalid_destination}

  @spec repository_plans([GitHubRepository.t()], organization_plan(), DateTime.t()) :: [map()]
  def repository_plans(repositories, destination, %DateTime{} = observed_at)
      when is_list(repositories) and is_map(destination) do
    candidates = Enum.map(repositories, &candidate/1)

    duplicate_slugs =
      candidates
      |> Enum.reject(&is_nil(&1.slug))
      |> Enum.group_by(& &1.slug)
      |> Enum.filter(fn {_slug, entries} -> length(entries) > 1 end)
      |> MapSet.new(fn {slug, _entries} -> slug end)

    Enum.map(candidates, fn candidate ->
      collision = collision(candidate, destination, duplicate_slugs)
      warnings = source_warnings(candidate.repository)

      %{
        attrs:
          item_attrs(
            candidate,
            destination,
            collision,
            observed_at,
            length(warnings)
          ),
        warnings: warnings
      }
    end)
  end

  defp new_organization(source_login, destination) do
    requested = if has_key?(destination, :slug), do: fetch(destination, :slug), else: source_login

    case Namespace.validate(requested) do
      {:ok, slug} ->
        if Repo.exists?(from user in User, where: user.username == ^slug) do
          {:ok,
           %{
             action: :new,
             slug: slug,
             requested_slug: slug,
             submitted_slug: requested,
             organization_id: nil,
             owner_id: nil,
             status: :conflict,
             classification: "namespace_conflict"
           }}
        else
          {:ok,
           %{
             action: :new,
             slug: slug,
             requested_slug: slug,
             submitted_slug: requested,
             organization_id: nil,
             owner_id: nil,
             status: :clean,
             classification: nil
           }}
        end

      {:error, :reserved} ->
        {:ok,
         %{
           action: :new,
           slug: nil,
           requested_slug: safe_requested_slug(requested),
           submitted_slug: requested,
           organization_id: nil,
           owner_id: nil,
           status: :invalid,
           classification: "reserved_namespace"
         }}

      {:error, :invalid} ->
        {:ok,
         %{
           action: :new,
           slug: nil,
           requested_slug: safe_requested_slug(requested),
           submitted_slug: requested,
           organization_id: nil,
           owner_id: nil,
           status: :invalid,
           classification: "invalid_namespace"
         }}
    end
  end

  defp existing_organization(actor_id, destination) do
    with {:ok, organization_id} <- positive_id(fetch(destination, :id)),
         %Organization{} = organization <-
           Repo.one(
             from organization in Organization,
               join: membership in OrganizationMember,
               on: membership.organization_id == organization.id,
               where:
                 organization.id == ^organization_id and organization.kind == :organization and
                   organization.state == :active and membership.user_id == ^actor_id and
                   membership.role == :owner
           ),
         {:ok, slug} <- Namespace.validate(organization.username) do
      {:ok,
       %{
         action: :existing,
         slug: slug,
         requested_slug: slug,
         submitted_slug: slug,
         organization_id: organization.id,
         owner_id: organization.id,
         status: :clean,
         classification: nil
       }}
    else
      nil -> {:error, :not_found}
      :error -> {:error, :invalid_destination}
      {:error, _invalid_or_reserved} -> {:error, :invalid_destination}
    end
  end

  defp candidate(%GitHubRepository{} = repository) do
    slug = Repository.normalize_slug(repository.name)

    %{
      repository: repository,
      slug: if(Repository.canonical_slug?(slug), do: slug),
      normalized_slug: slug,
      normalized?: repository.name != slug
    }
  end

  defp collision(_candidate, %{status: :invalid, classification: classification}, _duplicates),
    do: %{state: :awaiting_resolution, classification: classification, clear_slug?: true}

  defp collision(_candidate, %{status: :conflict, classification: classification}, _duplicates),
    do: %{state: :awaiting_resolution, classification: classification, clear_slug?: false}

  defp collision(%{slug: nil}, _destination, _duplicates),
    do: %{
      state: :awaiting_resolution,
      classification: "invalid_repository_slug",
      clear_slug?: true
    }

  defp collision(%{slug: slug, normalized?: normalized?}, _destination, duplicates) do
    cond do
      MapSet.member?(duplicates, slug) ->
        %{
          state: :awaiting_resolution,
          classification: "normalized_slug_collision",
          clear_slug?: false
        }

      normalized? ->
        %{
          state: :awaiting_resolution,
          classification: "repository_slug_normalized",
          clear_slug?: false
        }

      true ->
        :pending_local_collision
    end
  end

  defp item_attrs(candidate, destination, collision, observed_at, warning_count) do
    collision = resolve_local_collision(candidate, destination, collision)
    repository = candidate.repository

    %{
      github_repository_id: repository.id,
      source_full_name: repository.full_name,
      source_name: repository.name,
      source_metadata: source_metadata(repository),
      source_observed_at: observed_at,
      destination_owner_id: destination.owner_id,
      destination_slug: if(collision.clear_slug?, do: nil, else: candidate.slug),
      destination_visibility: destination_visibility(repository.visibility),
      state: collision.state,
      wait_reason: collision.classification,
      warning_count: warning_count
    }
  end

  defp resolve_local_collision(_candidate, _destination, collision)
       when is_map(collision),
       do: collision

  defp resolve_local_collision(%{slug: slug}, %{owner_id: owner_id}, :pending_local_collision)
       when is_integer(owner_id) do
    if Repo.exists?(
         from repository in Repository,
           where:
             repository.owner_user_id == ^owner_id and repository.slug == ^slug and
               is_nil(repository.deleted_at)
       ) do
      %{state: :awaiting_resolution, classification: "repository_conflict", clear_slug?: false}
    else
      %{state: :queued, classification: nil, clear_slug?: false}
    end
  end

  defp resolve_local_collision(_candidate, _destination, :pending_local_collision),
    do: %{state: :queued, classification: nil, clear_slug?: false}

  defp source_metadata(repository) do
    %{
      "archived" => repository.archived,
      "fork" => repository.fork,
      "visibility" => Atom.to_string(repository.visibility),
      "default_branch" => repository.default_branch,
      "description" => repository.description,
      "has_issues" => repository.has_issues
    }
    |> put_if_boolean("allow_merge_commit", repository.allow_merge_commit)
    |> put_if_datetime("updated_at", repository.updated_at)
    |> put_if_datetime("pushed_at", repository.pushed_at)
  end

  defp source_warnings(repository) do
    []
    |> maybe_warning(repository.visibility == :internal, "visibility_downgraded")
    |> maybe_warning(repository.fork, "unsupported_fork_relationship")
    |> maybe_warning(repository.archived, "unsupported_archived_state")
    |> then(&["unsupported_releases" | &1])
    |> Enum.reverse()
  end

  defp destination_visibility(:public), do: :public
  defp destination_visibility(:private), do: :private
  defp destination_visibility(:internal), do: :private

  defp put_if_boolean(metadata, key, value) when is_boolean(value),
    do: Map.put(metadata, key, value)

  defp put_if_boolean(metadata, _key, _value), do: metadata

  defp put_if_datetime(metadata, key, %DateTime{} = value),
    do: Map.put(metadata, key, DateTime.to_iso8601(value))

  defp put_if_datetime(metadata, _key, _value), do: metadata

  defp maybe_warning(warnings, true, classification), do: [classification | warnings]
  defp maybe_warning(warnings, false, _classification), do: warnings

  defp action(destination) do
    case fetch(destination, :action) do
      :new -> :new
      "new" -> :new
      :existing -> :existing
      "existing" -> :existing
      _ -> :invalid
    end
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp has_key?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp safe_requested_slug(value) when is_binary(value) do
    value = String.trim(String.downcase(value))

    if String.valid?(value) and byte_size(value) in 1..255 and
         :binary.match(value, <<0>>) == :nomatch,
       do: value,
       else: nil
  end

  defp safe_requested_slug(_value), do: nil

  defp positive_id(value) do
    case Ecto.Type.cast(:integer, value) do
      {:ok, id} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end
end
