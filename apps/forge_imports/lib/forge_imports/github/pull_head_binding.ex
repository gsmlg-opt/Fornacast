defmodule ForgeImports.GitHub.PullHeadBinding do
  @moduledoc false
  import Ecto.Query
  alias Fornacast.Repo
  alias ForgeImports.{ImportRun, RepositoryItem}
  alias ForgeMirrors.{OrganizationMirror, RepositoryMirror, MirrorRefState, GitHubAppInstallation}
  alias ForgeRepos.Repository

  def observe(%RepositoryItem{} = item, mapped), do: snapshot(item, mapped, false)

  def with_binding(item, mapped, callback) do
    with {:ok, proof} <- observe(item, mapped) do
      with_observation(item, mapped, proof, callback)
    end
  end

  def with_observation(item, mapped, %{kind: :represented} = proof, callback) do
    case Repo.get(Repository, proof.head_repository_id) do
      %Repository{} = head ->
        ForgeRepos.with_write_fence(head, :ref, fn path, remaining ->
          deadline = System.monotonic_time(:millisecond) + remaining

          with {:ok, oid} <- GitCore.exact_ref(path, mapped.head_ref, deadline_ms: remaining),
               true <- oid == mapped.head_sha,
               {:ok, true} <-
                 GitCore.is_ancestor(path, oid, oid,
                   deadline_ms: max(deadline - System.monotonic_time(:millisecond), 0)
                 ) do
            commit(item, mapped, proof, callback)
          else
            _ -> {:error, :pull_head_not_ready}
          end
        end)

      _ ->
        {:error, :pull_head_not_ready}
    end
  end

  def with_observation(item, mapped, proof, callback), do: commit(item, mapped, proof, callback)

  defp commit(item, mapped, proof, callback) do
    Repo.transaction(fn ->
      run = one(from(r in ImportRun, where: r.id == ^item.import_run_id), true)
      current = one(from(i in RepositoryItem, where: i.id == ^item.id), true)

      unless run && run.state == :running && current &&
               current.lock_version == item.lock_version &&
               current.lease_owner == item.lease_owner &&
               current.hidden_repository_id == item.hidden_repository_id &&
               current.destination_owner_id == item.destination_owner_id &&
               current.github_repository_id == item.github_repository_id &&
               current.state in [:git_staged, :staging_metadata] &&
               ((is_nil(current.lease_owner) && is_nil(current.lease_expires_at)) ||
                  (is_binary(current.lease_owner) && current.lease_owner != "" &&
                     is_struct(current.lease_expires_at, DateTime) &&
                     DateTime.compare(current.lease_expires_at, DateTime.utc_now()) == :gt)),
             do: Repo.rollback(:pull_head_not_ready)

      base = one(from(r in Repository, where: r.id == ^item.hidden_repository_id), true)

      unless base && base.lifecycle == :importing && is_nil(base.deleted_at) &&
               base.owner_user_id == current.destination_owner_id,
             do: Repo.rollback(:pull_head_not_ready)

      with :ok <- ForgeImports.CredentialProvider.authorize_recovery_locked(run, current),
           {:ok, ^proof} <- snapshot(current, mapped, true) do
        case callback.(proof.head_repository_id) do
          {:error, reason} -> Repo.rollback(reason)
          result -> result
        end
      else
        _ -> Repo.rollback(:pull_head_not_ready)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot(item, %{head_github_repository_id: id}, _lock?)
       when id == item.github_repository_id,
       do: {:ok, %{kind: :same, head_repository_id: item.hidden_repository_id}}

  defp snapshot(item, mapped, lock?) do
    run = Repo.get(ImportRun, item.import_run_id)

    org =
      one(
        from(o in OrganizationMirror, where: o.bootstrap_import_run_id == ^item.import_run_id),
        lock?
      )

    cond do
      is_nil(run) ->
        {:error, :pull_head_not_ready}

      (is_nil(org) and run) && run.credential_source != :github_app ->
        {:ok, %{kind: :external, head_repository_id: nil, organization_id: nil}}

      is_nil(org) ->
        {:error, :pull_head_not_ready}

      org.provider != "github" or org.organization_id != item.destination_owner_id or
        org.github_account_id != run.source_owner_github_id or
          org.state not in [:bootstrapping, :catching_up, :active] ->
        {:error, :pull_head_not_ready}

      true ->
        installation =
          one(
            from(i in GitHubAppInstallation,
              where: i.github_installation_id == ^org.github_installation_id
            ),
            lock?
          )

        if installation && installation.state == :active &&
             installation.github_account_id == org.github_account_id do
          binding =
            one(
              from(b in RepositoryMirror,
                where:
                  b.organization_mirror_id == ^org.id and
                    b.github_repository_id == ^mapped.head_github_repository_id
              ),
              lock?
            )

          binding_snapshot(item, mapped, org, installation, binding, lock?)
        else
          {:error, :pull_head_not_ready}
        end
    end
  end

  defp binding_snapshot(_item, _mapped, org, _installation, nil, _lock?),
    do:
      {:ok,
       %{
         kind: :external,
         head_repository_id: nil,
         organization_id: org.id,
         organization_version: org.lock_version
       }}

  defp binding_snapshot(_item, mapped, org, installation, binding, lock?) do
    repository =
      if binding.repository_id,
        do: one(from(r in Repository, where: r.id == ^binding.repository_id), lock?)

    ref =
      one(
        from(r in MirrorRefState,
          where:
            r.repository_mirror_id == ^binding.id and
              r.ref_name == ^mapped.head_ref
        ),
        lock?
      )

    if binding.state == :active && binding.inventory_included &&
         is_binary(mapped.head_github_node_id) && mapped.head_github_node_id != "" &&
         binding.github_node_id == mapped.head_github_node_id &&
         org.capabilities["git"] == "enabled" && org.capabilities["pulls"] == "enabled" &&
         repository && repository.lifecycle == :ready && is_nil(repository.deleted_at) &&
         repository.owner_user_id == org.organization_id && repository.generation > 0 &&
         ref && ref.state == :confirmed && ref.ref_kind == :branch &&
         not is_nil(ref.last_confirmed_at) &&
         ref.confirmed_oid == mapped.head_sha && ref.last_local_oid == mapped.head_sha &&
         ref.last_remote_oid == mapped.head_sha do
      {:ok,
       %{
         kind: :represented,
         head_repository_id: repository.id,
         organization_id: org.id,
         organization_version: org.lock_version,
         installation_id: installation.github_installation_id,
         binding_id: binding.id,
         binding_version: binding.lock_version,
         generation: repository.generation,
         ref_version: ref.lock_version,
         oid: mapped.head_sha
       }}
    else
      {:error, :pull_head_not_ready}
    end
  end

  defp one(query, true), do: query |> lock("FOR UPDATE") |> Repo.one()
  defp one(query, false), do: Repo.one(query)
end
