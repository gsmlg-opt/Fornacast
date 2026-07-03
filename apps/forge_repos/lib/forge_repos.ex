defmodule ForgeRepos do
  @moduledoc """
  Repository lifecycle, storage-path resolution, and repository lookup.
  """

  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

  alias Ecto.Multi
  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias Fornacast.{Repo, Storage}

  def list_owner_repositories(%User{id: owner_user_id}) do
    Repository
    |> where([repo], repo.owner_user_id == ^owner_user_id and is_nil(repo.deleted_at))
    |> order_by([repo], asc: repo.slug)
    |> Repo.all()
  end

  def create_repository(%User{} = owner, attrs) when is_map(attrs) do
    attrs = normalize_create_attrs(attrs)
    storage_path = generate_storage_path(owner.id, attrs.slug)

    changeset =
      %Repository{owner_user_id: owner.id, storage_path: storage_path}
      |> Repository.create_changeset(attrs)

    Multi.new()
    |> Multi.insert(:repository, changeset)
    |> Multi.run(:storage, fn _repo, %{repository: repository} ->
      init_repository_storage(repository)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{repository: repository}} -> {:ok, repository}
      {:error, :storage, reason, %{repository: repository}} -> cleanup_storage(repository, reason)
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def get_repository(owner_slug, repo_slug) when is_binary(owner_slug) and is_binary(repo_slug) do
    with %User{id: owner_user_id} <- ForgeAccounts.get_user_by_username(owner_slug) do
      Repository
      |> where([repo], repo.owner_user_id == ^owner_user_id)
      |> where([repo], repo.slug == ^Repository.normalize_slug(repo_slug))
      |> where([repo], is_nil(repo.deleted_at))
      |> Repo.one()
    end
  end

  def resolve_git_path(path) when is_binary(path) do
    with {:ok, owner, repo} <- parse_git_path(path),
         %Repository{} = repository <- get_repository(owner, repo) do
      {:ok, repository}
    else
      _ -> {:error, :not_found}
    end
  end

  def storage_path(%Repository{storage_path: storage_path}), do: storage_path

  def absolute_storage_path(%Repository{} = repository) do
    repository.storage_path
    |> Storage.repository_path!()
  end

  def empty?(%Repository{} = repository) do
    repository
    |> absolute_storage_path()
    |> GitCore.empty?()
  end

  def mark_pushed(%Repository{} = repository, pushed_at \\ DateTime.utc_now()) do
    pushed_at = DateTime.truncate(pushed_at, :second)

    repository
    |> change(last_pushed_at: pushed_at)
    |> Repo.update()
  end

  def ssh_clone_url(%Repository{} = repository, %User{} = owner) do
    port = Fornacast.Config.ssh_port()
    host = Fornacast.Config.ssh_host()
    port_segment = if port == 22, do: "", else: ":#{port}"

    "ssh://#{owner.username}@#{host}#{port_segment}/#{owner.username}/#{repository.slug}.git"
  end

  def parse_git_path(path) do
    path = String.trim(path)

    with false <- String.starts_with?(path, "/"),
         false <- String.contains?(path, ["..", "\\", "\0", ";", "&", "|", "`", "$", "(", ")"]),
         true <- String.ends_with?(path, ".git"),
         [owner, repo_with_suffix] <- String.split(path, "/", parts: 2),
         repo <- String.trim_trailing(repo_with_suffix, ".git"),
         true <- valid_git_path_segment?(owner),
         true <- valid_git_path_segment?(repo) do
      {:ok, owner, repo}
    else
      _ -> {:error, :invalid_path}
    end
  end

  def collaborator_role(%User{id: user_id}, %Repository{id: repository_id}) do
    ForgeRepos.Collaborator
    |> where([collaborator], collaborator.repository_id == ^repository_id)
    |> where([collaborator], collaborator.user_id == ^user_id)
    |> select([collaborator], collaborator.role)
    |> Repo.one()
  end

  defp normalize_create_attrs(attrs) do
    slug =
      attrs
      |> get_attr(:slug)
      |> case do
        nil -> get_attr(attrs, :name)
        value -> value
      end
      |> Repository.normalize_slug()

    %{
      name: get_attr(attrs, :name) || slug,
      slug: slug,
      description: get_attr(attrs, :description),
      visibility: get_attr(attrs, :visibility) || :private,
      default_branch: get_attr(attrs, :default_branch) || "main"
    }
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp generate_storage_path(owner_user_id, slug) do
    nonce = :crypto.strong_rand_bytes(24)

    digest =
      :sha256
      |> :crypto.hash("#{owner_user_id}:#{slug}:#{Base.url_encode64(nonce, padding: false)}")
      |> Base.encode16(case: :lower)

    Path.join([
      "@hashed",
      String.slice(digest, 0, 2),
      String.slice(digest, 2, 2),
      digest <> ".git"
    ])
  end

  defp init_repository_storage(%Repository{} = repository) do
    path = absolute_storage_path(repository)
    File.mkdir_p!(Path.dirname(path))

    case GitCore.init_bare(path) do
      {:ok, _path} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_storage(repository, reason) do
    repository
    |> absolute_storage_path()
    |> File.rm_rf()

    {:error, reason}
  end

  defp valid_git_path_segment?(segment) do
    segment == Repository.normalize_slug(segment) and segment != ""
  end
end
