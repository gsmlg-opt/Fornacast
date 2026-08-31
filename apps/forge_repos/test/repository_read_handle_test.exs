defmodule ForgeRepos.RepositoryReadHandleTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias Fornacast.Repo
  alias GitCore.RepositoryReadLimiter

  setup do
    reset_database!()
  end

  test "handle module exposes no constructor, accessor, or close functions" do
    refute function_exported?(ForgeRepos.RepositoryReadHandle, :new, 3)
    refute function_exported?(ForgeRepos.RepositoryReadHandle, :repository, 1)
    refute function_exported?(ForgeRepos.RepositoryReadHandle, :path, 1)
    refute function_exported?(ForgeRepos.RepositoryReadHandle, :close, 1)
  end

  @tag :tmp_dir
  test "open returns an opaque exact-generation handle and close releases cleanup", %{
    tmp_dir: root
  } do
    use_storage_root(root)
    repository = repository_fixture("opaque")

    assert {:ok, handle} = ForgeRepos.open_repository_read(repository, deadline())
    assert %Repository{id: id, generation: 1} = ForgeRepos.repository_read_repository(handle)
    assert id == repository.id
    assert ForgeRepos.repository_read_path(handle) == ForgeRepos.absolute_storage_path(repository)
    refute inspect(handle) =~ "lease"

    cleanup = start_cleanup(repository.id)
    refute_receive {:cleanup_acquired, ^cleanup, _lease}, 30

    assert :ok = ForgeRepos.close_repository_read(handle)
    assert :ok = ForgeRepos.close_repository_read(handle)
    assert_receive {:cleanup_acquired, ^cleanup, cleanup_lease}, 500
    send(cleanup, {:release, cleanup_lease})
    assert_receive {:cleanup_released, ^cleanup}
  end

  @tag :tmp_dir
  test "with_repository_read releases after returns and raises", %{tmp_dir: root} do
    use_storage_root(root)
    repository = repository_fixture("after")

    assert :value =
             ForgeRepos.with_repository_read(repository, deadline(), fn handle ->
               assert ForgeRepos.repository_read_repository(handle).id == repository.id
               :value
             end)

    assert_raise RuntimeError, "boom", fn ->
      ForgeRepos.with_repository_read(repository, deadline(), fn _handle -> raise "boom" end)
    end

    assert {:ok, cleanup} = RepositoryReadLimiter.acquire_cleanup(repository.id, deadline())
    assert :ok = RepositoryReadLimiter.release(cleanup)
  end

  @tag :tmp_dir
  test "post-acquire reload rejects tombstoned, reclaimed, and replaced generations", %{
    tmp_dir: root
  } do
    use_storage_root(root)

    for {slug, updates} <- [
          {"tombstoned", [lifecycle: :tombstoned, deleted_at: DateTime.utc_now()]},
          {"reclaimed", [storage_reclaimed_at: DateTime.utc_now()]},
          {"replaced", [generation: 2]}
        ] do
      repository = repository_fixture(slug)
      assert {:ok, cleanup} = RepositoryReadLimiter.acquire_cleanup(repository.id, deadline())

      task = Task.async(fn -> ForgeRepos.open_repository_read(repository, deadline()) end)
      wait_for_waiters(1)

      {1, nil} = Repository |> where(id: ^repository.id) |> Repo.update_all(set: updates)
      assert :ok = RepositoryReadLimiter.release(cleanup)
      assert {:error, :not_found} = Task.await(task)

      assert {:ok, next_cleanup} =
               RepositoryReadLimiter.acquire_cleanup(repository.id, deadline())

      assert :ok = RepositoryReadLimiter.release(next_cleanup)
    end
  end

  @tag :tmp_dir
  test "path resolution errors release the acquired read lease", %{tmp_dir: root} do
    use_storage_root(root)
    repository = repository_fixture("bad-path")
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, nil)

    try do
      assert {:error, :unavailable} =
               ForgeRepos.open_repository_read(repository, deadline())
    after
      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end

    assert {:ok, cleanup} = RepositoryReadLimiter.acquire_cleanup(repository.id, deadline())
    assert :ok = RepositoryReadLimiter.release(cleanup)
  end

  test "invalid repository identity is rejected before limiter admission" do
    for repository <- [
          %Repository{id: nil, generation: 1},
          %Repository{id: 0, generation: 1},
          %Repository{id: 1, generation: 0}
        ] do
      assert {:error, :not_found} = ForgeRepos.open_repository_read(repository, deadline())
    end
  end

  @tag :tmp_dir
  test "limiter absence maps to unavailable", %{tmp_dir: root} do
    use_storage_root(root)
    repository = repository_fixture("limiter-unavailable")
    on_exit(&restart_git_core/0)
    limiter = Process.whereis(RepositoryReadLimiter)
    monitor = Process.monitor(limiter)
    Process.exit(limiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^limiter, :killed}

    assert {:error, :unavailable} = ForgeRepos.open_repository_read(repository, deadline())
  end

  @tag :tmp_dir
  test "old handle survives replacement while old cleanup waits and new lookup opens", %{
    tmp_dir: root
  } do
    use_storage_root(root)
    old = repository_fixture("replacement")
    old_path = ForgeRepos.absolute_storage_path(old)
    File.write!(Path.join(old_path, "old-inode-marker"), "old")
    old_inode = File.stat!(Path.join(old_path, "old-inode-marker")).inode
    assert {:ok, old_handle} = ForgeRepos.open_repository_read(old, deadline())

    old =
      old
      |> Ecto.Changeset.change(
        slug: "replacement-old",
        lifecycle: :tombstoned,
        deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update!()

    replacement =
      %Repository{
        owner_user_id: old.owner_user_id,
        slug: "replacement",
        name: "replacement",
        visibility: :private,
        storage_path: "@test/#{old.owner_user_id}/replacement-new.git",
        default_branch: "main",
        lifecycle: :ready,
        generation: 2
      }
      |> Repo.insert!()

    File.mkdir_p!(ForgeRepos.absolute_storage_path(replacement))
    cleanup = start_cleanup(old.id)
    refute_receive {:cleanup_acquired, ^cleanup, _lease}, 30

    owner = ForgeRepos.repository_owner(replacement)

    assert %Repository{id: replacement_id} =
             ForgeRepos.get_repository(owner.username, "replacement")

    assert replacement_id == replacement.id
    assert {:ok, new_handle} = ForgeRepos.open_repository_read(replacement, deadline())

    assert File.read!(Path.join(ForgeRepos.repository_read_path(old_handle), "old-inode-marker")) ==
             "old"

    assert File.stat!(Path.join(ForgeRepos.repository_read_path(old_handle), "old-inode-marker")).inode ==
             old_inode

    assert :ok = ForgeRepos.close_repository_read(new_handle)
    assert :ok = ForgeRepos.close_repository_read(old_handle)
    assert_receive {:cleanup_acquired, ^cleanup, cleanup_lease}, 500
    send(cleanup, {:release, cleanup_lease})
    assert_receive {:cleanup_released, ^cleanup}
  end

  defp repository_fixture(slug) do
    owner =
      %User{
        username: "read-handle-#{slug}",
        email: "#{slug}@example.com",
        password_hash: "unused",
        kind: :user,
        role: :user,
        state: :active
      }
      |> Repo.insert!()

    assert {:ok, repository} =
             ForgeRepos.create_repository(owner, %{name: slug, slug: slug})

    repository
  end

  defp start_cleanup(repository_id) do
    parent = self()

    spawn(fn ->
      {:ok, lease} = RepositoryReadLimiter.acquire_cleanup(repository_id, deadline())
      send(parent, {:cleanup_acquired, self(), lease})

      receive do
        {:release, ^lease} ->
          :ok = RepositoryReadLimiter.release(lease)
          send(parent, {:cleanup_released, self()})
      end
    end)
  end

  defp use_storage_root(root) do
    original = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original) end)
  end

  defp wait_for_waiters(expected, attempts \\ 100)

  defp wait_for_waiters(expected, attempts) when attempts > 0 do
    if map_size(:sys.get_state(RepositoryReadLimiter).waiters) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_waiters(expected, attempts - 1)
    end
  end

  defp wait_for_waiters(_expected, 0), do: flunk("read waiter count did not converge")

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      adapter when adapter in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      adapter when adapter in ["libsql", "turso"] ->
        for table <-
              ~w(audit_events repository_collaborators repositories organization_members api_keys ssh_keys users) do
          Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
        end

        :ok
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 2_000

  defp restart_git_core do
    if Process.whereis(RepositoryReadLimiter) == nil do
      Application.stop(:git_core)
      {:ok, _started} = Application.ensure_all_started(:git_core)
    end
  end
end
