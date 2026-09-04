defmodule ForgeMirrors.ConcurrentClaimTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorOperation, OrganizationMirror, RepositoryMirror}

  @moduletag :persistence
  @moduletag independent_connections: true

  test "concurrent claimers cannot take two operations for one repository" do
    now = DateTime.utc_now(:second)

    {organization_id, first, second} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        organization = active_organization_mirror_fixture()
        repository = repository_mirror_fixture(organization)

        first =
          operation_fixture(organization, %{
            repository_mirror_id: repository.id,
            dedupe_key: "concurrent-same-first-#{organization.id}",
            next_attempt_at: now
          })

        second =
          operation_fixture(organization, %{
            repository_mirror_id: repository.id,
            dedupe_key: "concurrent-same-second-#{organization.id}",
            next_attempt_at: now
          })

        {organization.organization_id, first, second}
      end)

    on_exit(fn -> cleanup_organization(organization_id) end)

    claims = concurrent_claims(now)
    assert Enum.sort(Enum.map(claims, &length/1)) == [0, 1]
    assert [[%MirrorOperation{id: claimed_id}]] = Enum.reject(claims, &(&1 == []))
    assert claimed_id == first.id

    second_state =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.get!(MirrorOperation, second.id).state
      end)

    assert second_state == :pending
  end

  test "concurrent claimers may take work for independent repositories" do
    now = DateTime.utc_now(:second)

    {organization_id, operation_ids} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        organization = active_organization_mirror_fixture()

        repositories = [
          repository_mirror_fixture(organization),
          repository_mirror_fixture(organization)
        ]

        operations =
          Enum.map(repositories, fn repository ->
            operation_fixture(organization, %{
              repository_mirror_id: repository.id,
              dedupe_key: "concurrent-independent-#{repository.id}",
              next_attempt_at: now
            })
          end)

        {organization.organization_id, Enum.map(operations, & &1.id)}
      end)

    on_exit(fn -> cleanup_organization(organization_id) end)

    claimed_ids =
      now
      |> concurrent_claims()
      |> List.flatten()
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert claimed_ids == Enum.sort(operation_ids)
  end

  defp concurrent_claims(now) do
    ["concurrent-worker-a", "concurrent-worker-b"]
    |> Task.async_stream(
      fn owner ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          {:ok, operations} = ForgeMirrors.claim_operations(owner, now, 30, 1)
          operations
        end)
      end,
      max_concurrency: 2,
      ordered: false,
      timeout: 5_000
    )
    |> Enum.map(fn {:ok, operations} -> operations end)
  end

  defp cleanup_organization(organization_id) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      mirror_ids =
        OrganizationMirror
        |> where([mirror], mirror.organization_id == ^organization_id)
        |> select([mirror], mirror.id)
        |> Repo.all()

      Repo.delete_all(
        from(operation in MirrorOperation, where: operation.organization_mirror_id in ^mirror_ids)
      )

      Repo.delete_all(
        from(repository in RepositoryMirror,
          where: repository.organization_mirror_id in ^mirror_ids
        )
      )

      Repo.delete_all(from(mirror in OrganizationMirror, where: mirror.id in ^mirror_ids))

      Repo.delete_all(
        from(repository in "repositories", where: repository.owner_user_id == ^organization_id)
      )

      Repo.delete_all(from(user in "users", where: user.id == ^organization_id))
    end)
  end
end
