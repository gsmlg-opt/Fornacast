defmodule ForgeRepos.RepositoryWriteFenceTest.First do
  def cleanup_safety_locked(_repository, _now), do: :safe

  def reconcile_repository_locked(_repository, _path, deadline) do
    send(self(), {:first, deadline})
    :ok
  end
end

defmodule ForgeRepos.RepositoryWriteFenceTest.Second do
  def cleanup_safety_locked(_repository, _now), do: :safe

  def reconcile_repository_locked(_repository, _path, deadline) do
    send(self(), {:second, deadline})
    :ok
  end
end

defmodule ForgeRepos.RepositoryWriteFenceTest.ReloadObserver do
  def cleanup_safety_locked(_repository, _now), do: :safe

  def reconcile_repository_locked(repository, path, _deadline) do
    send(self(), {:reloaded_repository, repository, path})
    :ok
  end
end

defmodule ForgeRepos.RepositoryWriteFenceTest.Unavailable do
  def cleanup_safety_locked(_repository, _now), do: :safe

  def reconcile_repository_locked(_repository, _path, _deadline),
    do: {:error, :unavailable}
end

defmodule ForgeRepos.RepositoryWriteFenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeRepos.{Repository, RepositoryWriteReconcilers}
  alias GitCore.RepositoryWriteLimiter
  alias Fornacast.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    if Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    else
      for table <- ~w(git_write_operations audit_events repositories users) do
        Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
      end
    end

    original = {
      Application.fetch_env(:forge_repos, :repository_write_reconcilers),
      Application.fetch_env(:forge_repos, :repository_write_limiter)
    }

    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    on_exit(fn ->
      {original_reconcilers, original_limiter} = original

      for {key, value} <- [
            repository_write_reconcilers: original_reconcilers,
            repository_write_limiter: original_limiter
          ] do
        case value do
          {:ok, value} -> Application.put_env(:forge_repos, key, value)
          :error -> Application.delete_env(:forge_repos, key)
        end
      end

      Application.put_env(:fornacast, :repo_storage_root, original_root)
    end)

    username = "fence-#{System.unique_integer([:positive])}"

    {:ok, owner} =
      ForgeAccounts.create_user(%{
        username: username,
        email: "#{username}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{name: "Fence", slug: "fence"})

    {:ok, repository: repository}
  end

  test "dispatcher validates, sorts, preserves caller and deadline, and short-circuits" do
    deadline = System.monotonic_time(:millisecond) + 10_000
    repository = %Repository{id: 91}

    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {20, :second, __MODULE__.Second},
      {10, :first, __MODULE__.First}
    ])

    assert :ok = RepositoryWriteReconcilers.reconcile_locked(repository, "/repo.git", deadline)
    assert_receive {:first, ^deadline}
    assert_receive {:second, ^deadline}

    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {10, :stop, __MODULE__.Unavailable},
      {20, :second, __MODULE__.Second}
    ])

    assert {:error, :unavailable} =
             RepositoryWriteReconcilers.reconcile_locked(repository, "/repo.git", deadline)

    refute_receive {:second, _deadline}

    for invalid <- [
          [{10, :duplicate, __MODULE__.First}, {20, :duplicate, __MODULE__.Second}],
          [{10, :first, __MODULE__.First}, {20, :second, __MODULE__.First}],
          [{"10", :first, __MODULE__.First}],
          [{10, :missing, String}]
        ] do
      Application.put_env(:forge_repos, :repository_write_reconcilers, invalid)

      assert_raise ArgumentError,
                   "invalid :forge_repos repository_write_reconcilers configuration",
                   &RepositoryWriteReconcilers.entries/0
    end
  end

  test "fence passes a decreasing budget and releases after callback raises", %{
    repository: repository
  } do
    Application.put_env(:forge_repos, :repository_write_reconcilers, [])
    expected_path = ForgeRepos.absolute_storage_path(repository)

    assert :callback_result =
             ForgeRepos.with_write_fence(repository, :ref, fn path, remaining ->
               assert path == expected_path
               assert remaining in 1..GitCore.Limits.get(:ref_deadline_ms)
               :callback_result
             end)

    assert_raise RuntimeError, "callback failed", fn ->
      ForgeRepos.with_write_fence(repository, :ref, fn _path, _remaining ->
        raise "callback failed"
      end)
    end

    assert {:ok, lease} =
             RepositoryWriteLimiter.acquire(
               repository.id,
               System.monotonic_time(:millisecond) + 1_000
             )

    assert :ok = RepositoryWriteLimiter.release(lease)
  end

  test "fence ignores a hostile observed path and uses the exact reloaded repository", %{
    repository: repository
  } do
    Application.put_env(:forge_repos, :repository_write_reconcilers, [
      {10, :reload_observer, __MODULE__.ReloadObserver}
    ])

    expected_path = ForgeRepos.absolute_storage_path(repository)
    hostile = %{repository | storage_path: "../hostile.git"}

    assert :callback_result =
             ForgeRepos.with_write_fence(hostile, :ref, fn path, _remaining ->
               assert path == expected_path
               :callback_result
             end)

    assert_receive {:reloaded_repository, reloaded, ^expected_path}
    assert reloaded.id == repository.id
    assert reloaded.generation == repository.generation
    assert reloaded.storage_path == repository.storage_path
  end

  test "queued writers reject generation, lifecycle, and deletion drift before storage", %{
    repository: repository
  } do
    Application.put_env(:forge_repos, :repository_write_reconcilers, [])

    for updates <- [
          [generation: repository.generation + 1],
          [lifecycle: :tombstoned],
          [deleted_at: ~U[2026-08-26 00:00:00Z]]
        ] do
      reset_repository(repository)
      deadline = System.monotonic_time(:millisecond) + 5_000
      assert {:ok, lease} = RepositoryWriteLimiter.acquire(repository.id, deadline)
      test_pid = self()

      writer =
        Task.async(fn ->
          ForgeRepos.with_write_fence(repository, :receive_pack, fn path, _remaining ->
            send(test_pid, {:stale_writer_reached_storage, path})
            :stale_write
          end)
        end)

      wait_for_waiters(1)

      assert {1, nil} =
               Repo.update_all(
                 from(candidate in Repository, where: candidate.id == ^repository.id),
                 set: updates
               )

      assert :ok = RepositoryWriteLimiter.release(lease)

      assert {:error, {:unavailable, :stale_repository}} = Task.await(writer)
      refute_receive {:stale_writer_reached_storage, _path}
    end
  end

  test "publication fence maps exact target drift without invoking its callback", %{
    repository: repository
  } do
    Application.put_env(:forge_repos, :repository_write_reconcilers, [])
    stale = %{repository | generation: repository.generation + 1}

    assert {:error, :destination_changed} =
             ForgeRepos.with_import_publication_fence(stale, :ref, fn _path, _remaining ->
               flunk("drifted publication reached callback")
             end)
  end

  defp reset_repository(repository) do
    assert {1, nil} =
             Repo.update_all(
               from(candidate in Repository, where: candidate.id == ^repository.id),
               set: [generation: repository.generation, lifecycle: :ready, deleted_at: nil]
             )
  end

  defp wait_for_waiters(expected, attempts \\ 100)

  defp wait_for_waiters(expected, attempts) when attempts > 0 do
    if map_size(:sys.get_state(RepositoryWriteLimiter).waiters) == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_waiters(expected, attempts - 1)
    end
  end

  defp wait_for_waiters(expected, 0),
    do: flunk("expected #{expected} repository write waiter(s)")
end
