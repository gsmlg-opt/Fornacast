defmodule ForgeImports.ReleaseAssetBackfill do
  @moduledoc false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeImports.{ImportRun, RepositoryItem}
  alias ForgeImports.GitHub.ReleaseAssets
  alias Fornacast.Repo

  @states [:published, :completed]
  @lease_seconds 300

  def run(actor, item_id, identity_id, metadata, opts \\ [])

  def run(%User{} = actor, item_id, identity_id, metadata, opts) do
    with true <-
           is_integer(item_id) and item_id > 0 and is_integer(identity_id) and identity_id > 0,
         {:ok, _} <- ForgeAccounts.validate_github_link_request(actor, metadata),
         {:ok, reference} <- ForgeAccounts.github_account_reference(actor, identity_id),
         true <- not is_nil(reference.credential),
         {:ok, context} <- claim(actor, item_id) do
      try do
        checkout = fn callback ->
          request = make_ref()
          caller = self()

          result =
            ForgeAccounts.with_github_credential(actor, identity_id, fn credential ->
              send(
                caller,
                {request,
                 callback.(credential, %{
                   gate_key: {:saved_credential, reference.credential.credential_id}
                 })}
              )

              :ok
            end)

          case result do
            {:ok, :ok} ->
              receive do
                {^request, response} -> response
              after
                0 -> {:error, :credential_service_unavailable}
              end

            {:error, _} = error ->
              error
          end
        end

        options =
          opts
          |> Keyword.put(:asset_fence, fn repo -> fence(repo, actor, context) end)
          |> Keyword.put(:heartbeat, fn -> heartbeat(actor, context) end)

        ReleaseAssets.stage(context.item, context.repository, checkout, options)
      after
        Repo.update_all(
          from(item in RepositoryItem,
            where:
              item.id == ^item_id and item.lease_owner == ^context.item.lease_owner and
                item.state in ^@states
          ),
          set: [lease_owner: nil, lease_expires_at: nil],
          inc: [lock_version: 1]
        )
      end
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  def run(_, _, _, _, _), do: {:error, :forbidden}

  defp claim(actor, item_id) do
    token =
      "release-asset-backfill-" <>
        Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    Repo.transaction(fn ->
      item = Repo.one(from item in RepositoryItem, where: item.id == ^item_id, lock: "FOR UPDATE")
      now = DateTime.utc_now(:second)

      with %RepositoryItem{state: state} when state in @states <- item,
           %ImportRun{actor_user_id: actor_id} when actor_id == actor.id <-
             Repo.get(ImportRun, item.import_run_id),
           %ForgeRepos.Repository{} = repository <-
             Repo.get(ForgeRepos.Repository, item.hidden_repository_id),
           :ok <- authorized(actor, repository),
           true <- is_nil(item.cleanup_state),
           true <-
             is_nil(item.lease_expires_at) or DateTime.compare(item.lease_expires_at, now) != :gt do
        case Repo.update_all(
               from(candidate in RepositoryItem,
                 where:
                   candidate.id == ^item.id and candidate.lock_version == ^item.lock_version and
                     candidate.state in ^@states
               ),
               set: [
                 lease_owner: token,
                 lease_expires_at: DateTime.add(now, @lease_seconds, :second)
               ],
               inc: [lock_version: 1]
             ) do
          {1, _} -> %{item: Repo.get!(RepositoryItem, item.id), repository: repository}
          _ -> Repo.rollback(:busy)
        end
      else
        false -> Repo.rollback(:busy)
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  defp fence(repo, actor, context) do
    item =
      repo.one(
        from item in RepositoryItem, where: item.id == ^context.item.id, lock: "FOR UPDATE"
      )

    repository = repo.get(ForgeRepos.Repository, context.repository.id)
    run = repo.get(ImportRun, context.item.import_run_id)
    now = DateTime.utc_now(:second)

    if item && item.state in @states && item.lease_owner == context.item.lease_owner &&
         is_struct(item.lease_expires_at, DateTime) &&
         DateTime.compare(item.lease_expires_at, now) == :gt &&
         item.hidden_repository_id == context.repository.id &&
         item.import_run_id == context.item.import_run_id &&
         item.github_repository_id == context.item.github_repository_id &&
         item.source_full_name == context.item.source_full_name && is_nil(item.cleanup_state) &&
         run && run.actor_user_id == actor.id &&
         repository && repository.generation == context.repository.generation &&
         repository.lifecycle == :ready && is_nil(repository.deleted_at) do
      authorized(actor, repository)
    else
      {:error, :lost_lease}
    end
  end

  defp heartbeat(actor, context) do
    case Repo.transaction(fn ->
           case fence(Repo, actor, context) do
             :ok ->
               Repo.update_all(
                 from(item in RepositoryItem,
                   where:
                     item.id == ^context.item.id and item.lease_owner == ^context.item.lease_owner
                 ),
                 set: [
                   lease_expires_at:
                     DateTime.add(DateTime.utc_now(:second), @lease_seconds, :second)
                 ],
                 inc: [lock_version: 1]
               )

               :ok

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  defp authorized(actor, repository) do
    owner = ForgeRepos.repository_owner(repository)

    with %User{} <- owner,
         %User{state: :active} <- ForgeAccounts.get_account(actor.id),
         {:ok, %{id: id}} when id == repository.id <-
           ForgeRepos.fetch_authorized_repository(
             actor,
             owner.username,
             repository.slug,
             :repository_admin
           ) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end
end
