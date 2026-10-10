defmodule ForgeReleases.RepositoryReadsTest do
  use ExUnit.Case, async: false

  import ForgeReleases.Fixtures

  alias ForgeReleases.{Archives, Notes}
  alias GitCore.RepositoryReadLimiter

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    reset_database!()
    previous_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, root)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous_root) end)

    owner = user_fixture("release-reader-#{System.unique_integer([:positive])}")
    repository = repository_fixture(owner)
    put_tag(repository, "v1")
    %{owner: owner, repository: repository}
  end

  test "notes hold the read permit and release it on success and Git errors", %{repository: repo} do
    assert {:ok, %{body: body}} =
             assert_cleanup_waits(repo, fn -> Notes.generate(repo, "v1") end)

    assert body =~ "release v1"

    assert {:error, :not_found} =
             assert_cleanup_waits(repo, fn -> Notes.generate(repo, "v1", "missing") end)
  end

  test "archives hold the read permit and release it on success and Git errors", context do
    %{owner: owner, repository: repo} = context

    assert {:ok, release} =
             ForgeReleases.create(owner, owner.username, repo.slug, %{"tag_name" => "v1"}, %{})

    assert {:ok, archive} =
             assert_cleanup_waits(repo, fn ->
               Archives.prepare(owner, owner.username, repo.slug, release.id, "tar")
             end)

    assert archive.size > 0
    Archives.cleanup(archive)
    delete_tag(repo, "v1")

    assert {:error, :not_found} =
             assert_cleanup_waits(repo, fn ->
               Archives.prepare(owner, owner.username, repo.slug, release.id, "tar")
             end)
  end

  test "creation generates notes under its existing writer fence", context do
    %{owner: owner, repository: repo} = context

    assert {:ok, release} =
             ForgeRepos.with_test_read_phase_hook(
               fn -> flunk("a writer must not wait for a nested read permit") end,
               fn ->
                 ForgeReleases.create(
                   owner,
                   owner.username,
                   repo.slug,
                   %{"tag_name" => "v1", "generate_release_notes" => true},
                   %{}
                 )
               end
             )

    assert release.body =~ "release v1"
  end

  defp assert_cleanup_waits(repository, operation) do
    parent = self()
    marker = make_ref()

    result =
      ForgeRepos.with_test_read_phase_hook(
        fn ->
          spawn_link(fn ->
            assert {:ok, lease} = RepositoryReadLimiter.acquire_cleanup(repository.id, deadline())
            send(parent, {:cleanup_acquired, marker, self()})

            receive do
              {:release, ^marker} -> RepositoryReadLimiter.release(lease)
            after
              5_000 -> flunk("cleanup lease was not released")
            end

            send(parent, {:cleanup_released, marker})
          end)

          refute_receive {:cleanup_acquired, ^marker, _}, 30
        end,
        operation
      )

    assert_receive {:cleanup_acquired, ^marker, cleanup}, 1_000
    send(cleanup, {:release, marker})
    assert_receive {:cleanup_released, ^marker}, 1_000
    result
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
