defmodule ForgeRepos.RepositoryWriteFenceTest.First do
  def reconcile_repository_locked(_repository, _path, deadline) do
    send(self(), {:first, deadline})
    :ok
  end
end

defmodule ForgeRepos.RepositoryWriteFenceTest.Second do
  def reconcile_repository_locked(_repository, _path, deadline) do
    send(self(), {:second, deadline})
    :ok
  end
end

defmodule ForgeRepos.RepositoryWriteFenceTest.Unavailable do
  def reconcile_repository_locked(_repository, _path, _deadline),
    do: {:error, :unavailable}
end

defmodule ForgeRepos.RepositoryWriteFenceTest do
  use ExUnit.Case, async: false

  alias ForgeRepos.{Repository, RepositoryWriteReconcilers}
  alias GitCore.RepositoryWriteLimiter

  setup do
    original = Application.get_env(:forge_repos, :repository_write_reconcilers)

    on_exit(fn ->
      Application.put_env(:forge_repos, :repository_write_reconcilers, original)
    end)

    :ok
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

  @tag :tmp_dir
  test "fence passes a decreasing budget and releases after callback raises", %{tmp_dir: tmp_dir} do
    original_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    Application.put_env(:forge_repos, :repository_write_reconcilers, [])
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    repository = %Repository{id: 92, storage_path: "@test/92/demo.git"}
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
end
