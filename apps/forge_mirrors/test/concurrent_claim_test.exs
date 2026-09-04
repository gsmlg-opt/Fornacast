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

  test "an external effect marker that wins the organization lock serializes a later pause" do
    now = DateTime.utc_now(:second)
    parent = self()

    {organization_id, organization_mirror, claimed} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        organization_mirror = active_organization_mirror_fixture()
        repository_mirror = repository_mirror_fixture(organization_mirror)

        operation_fixture(organization_mirror, %{
          repository_mirror_id: repository_mirror.id,
          next_attempt_at: now
        })

        {:ok, [claimed]} = ForgeMirrors.claim_operations("marker-wins", now, 60, 1)
        {organization_mirror.organization_id, organization_mirror, claimed}
      end)

    on_exit(fn -> cleanup_organization(organization_id) end)

    marker_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            result =
              ForgeMirrors.mark_external_effect(claimed, now, %{"request_id" => "marker-wins"})

            send(parent, {:marker_written, self(), result})

            receive do
              :commit_marker -> result
            after
              10_000 -> Repo.rollback(:release_timeout)
            end
          end)
        end)
      end)

    assert_receive {:marker_written, marker_writer, {:ok, marked}}, 2_000

    pause_task =
      observed_task(parent, :pause_started, fn ->
        ForgeMirrors.pause(organization_owner_fixture(organization_mirror), organization_mirror)
      end)

    assert_receive {:pause_started, pause_backend_pid}, 2_000
    assert :blocked = await_blocked_or_finished(pause_task, pause_backend_pid)

    send(marker_writer, :commit_marker)
    assert {:ok, {:ok, ^marked}} = Task.await(marker_task, 5_000)
    assert {:ok, paused} = Task.await(pause_task, 5_000)
    assert paused.state == :paused

    assert {:ok, completed} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               ForgeMirrors.complete_operation(marked, DateTime.add(now, 1))
             end)

    assert completed.state == :completed
  end

  test "a pause that wins the organization lock blocks and rejects a later effect marker" do
    now = DateTime.utc_now(:second)
    parent = self()

    {organization_id, organization_mirror, claimed} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        organization_mirror = active_organization_mirror_fixture()
        repository_mirror = repository_mirror_fixture(organization_mirror)

        operation_fixture(organization_mirror, %{
          repository_mirror_id: repository_mirror.id,
          next_attempt_at: now
        })

        {:ok, [claimed]} = ForgeMirrors.claim_operations("pause-wins", now, 60, 1)
        {organization_mirror.organization_id, organization_mirror, claimed}
      end)

    on_exit(fn -> cleanup_organization(organization_id) end)

    pause_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            result =
              ForgeMirrors.pause(
                organization_owner_fixture(organization_mirror),
                organization_mirror
              )

            send(parent, {:pause_written, self(), result})

            receive do
              :commit_pause -> result
            after
              10_000 -> Repo.rollback(:release_timeout)
            end
          end)
        end)
      end)

    assert_receive {:pause_written, pause_writer, {:ok, paused}}, 2_000

    marker_task =
      observed_task(parent, :marker_started, fn ->
        ForgeMirrors.mark_external_effect(claimed, now, %{"request_id" => "pause-wins"})
      end)

    assert_receive {:marker_started, marker_backend_pid}, 2_000
    assert :blocked = await_blocked_or_finished(marker_task, marker_backend_pid)

    send(pause_writer, :commit_pause)
    assert {:ok, {:ok, ^paused}} = Task.await(pause_task, 5_000)
    assert {:error, :paused} = Task.await(marker_task, 5_000)
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

  defp observed_task(parent, started_message, function) do
    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend_pid]]} =
          Ecto.Adapters.SQL.query!(Repo, "select pg_backend_pid()", [])

        send(parent, {started_message, backend_pid})
        function.()
      end)
    end)
  end

  defp await_blocked_or_finished(task, backend_pid, attempts \\ 200)
  defp await_blocked_or_finished(_task, _backend_pid, 0), do: :not_observed

  defp await_blocked_or_finished(task, backend_pid, attempts) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        {:finished, result}

      nil ->
        blocked? =
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[blocking_pids]]} =
              Ecto.Adapters.SQL.query!(Repo, "select pg_blocking_pids($1)", [backend_pid])

            blocking_pids != []
          end)

        if blocked? do
          :blocked
        else
          Process.sleep(5)
          await_blocked_or_finished(task, backend_pid, attempts - 1)
        end
    end
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
