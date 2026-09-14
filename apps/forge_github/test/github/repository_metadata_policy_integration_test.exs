defmodule ForgeGitHub.RepositoryMetadataPolicyIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeGitHub.{Error, InstallationToken, RepositoryMetadataSyncWorker}
  alias ForgeMirrors.{MirrorConflict, MirrorOperation, RepositoryMirror}
  alias ForgeRepos.Repository
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture()
    binding = repository_mirror_fixture(organization)
    repository = Repo.get!(Repository, binding.repository_id)
    now = DateTime.utc_now(:second)

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               binding,
               "metadata-policy:baseline",
               now
             )

    assert {:ok, [{_operation_id, {:ok, %{action: :confirmed}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-policy-baseline",
               now: fn -> now end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _repository_name, _ ->
                 {:ok, remote(binding, repository.slug, false, repository.visibility, now)}
               end
             )

    %{
      actor: organization_owner_fixture(organization),
      organization: organization,
      binding: Repo.get!(RepositoryMirror, binding.id),
      now: now
    }
  end

  test "a rename plus unrepresentable archive advances the GET path without a PATCH and recovers",
       c do
    repository = Repo.get!(Repository, c.binding.repository_id)

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata-policy:archived",
               DateTime.add(c.now, 1)
             )

    archived_remote =
      remote(
        c.binding,
        "archived-renamed",
        true,
        repository.visibility,
        DateTime.add(c.now, 1)
      )

    assert {:ok, [{_operation_id, {:ok, %{action: :conflict, conflict: conflict}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-policy-archive",
               now: fn -> DateTime.add(c.now, 1) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, repository_name, _ ->
                 send(self(), {:fetched_repository, repository_name})
                 {:ok, archived_remote}
               end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_repository_patch)
                 flunk("unrepresentable repository metadata must not be patched")
               end
             )

    assert conflict.conflict_kind == "repository_archived_unrepresentable"
    assert_received {:fetched_repository, initial_name}

    assert initial_name ==
             c.binding.github_full_name |> String.split("/", parts: 2) |> List.last()

    refute_received :administration_token
    refute_received :unexpected_repository_patch

    observed = Repo.get!(RepositoryMirror, c.binding.id)
    assert observed.github_archived == true
    assert String.ends_with?(observed.github_full_name, "/archived-renamed")

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               observed,
               "metadata-policy:unarchived",
               DateTime.add(c.now, 2)
             )

    recovered_remote = %{archived_remote | archived: false, updated_at: DateTime.add(c.now, 2)}

    assert {:ok, [{_operation_id, {:ok, %{action: :confirmed}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-policy-unarchive",
               now: fn -> DateTime.add(c.now, 2) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, repository_name, _ ->
                 send(self(), {:recovery_fetch, repository_name})
                 {:ok, recovered_remote}
               end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_repository_patch)
                 flunk("remote-only recovery must not patch GitHub")
               end
             )

    assert_received {:recovery_fetch, "archived-renamed"}
    refute_received :administration_token
    refute_received :unexpected_repository_patch
    assert Repo.get!(Repository, repository.id).slug == "archived-renamed"
    assert Repo.get!(RepositoryMirror, c.binding.id).github_archived == false
    assert Repo.get!(MirrorConflict, conflict.id).state == :resolved
  end

  test "keep Fornacast recovers a committed PATCH after timeout without a second effect", c do
    repository =
      c.binding.repository_id
      |> then(&Repo.get!(Repository, &1))
      |> Ecto.Changeset.change(description: "local owner choice")
      |> Ecto.Changeset.optimistic_lock(:write_version)
      |> Repo.update!()

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata-resolution-integration:conflict",
               DateTime.add(c.now, 1)
             )

    remote =
      c.binding
      |> remote(repository.slug, false, repository.visibility, DateTime.add(c.now, 1))
      |> Map.put(:description, "remote owner choice")

    assert {:ok, [{_operation_id, {:ok, %{action: :conflict, conflict: conflict}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-conflict",
               now: fn -> DateTime.add(c.now, 1) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end
             )

    assert {:ok, %{operation: requested}} =
             ForgeMirrors.request_repository_metadata_conflict_resolution(
               c.actor,
               c.organization.organization_id,
               conflict,
               "keep_fornacast",
               DateTime.add(c.now, 2),
               request_metadata()
             )

    assert {:ok, [{operation_id, {:ok, %MirrorOperation{state: :effect_pending} = deferred}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-first-worker",
               now: fn -> DateTime.add(c.now, 2) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end,
               repository_update: fn _, _, _, target, _ ->
                 send(self(), {:committed_patch, target})
                 {:error, Error.new(:timeout)}
               end
             )

    assert operation_id == requested.id
    assert deferred.external_effect_marker["target"]["description"] == "local owner choice"
    assert deferred.external_effect_marker["attempt_state"] == "attempted"
    assert_received {:committed_patch, target}
    assert_received :administration_token

    recovered_remote =
      c.binding
      |> remote(repository.slug, false, repository.visibility, DateTime.add(c.now, 62))
      |> Map.put(:description, target["description"])

    assert {:ok, [{^operation_id, {:ok, %{action: :confirmed, operation: completed}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-restarted-worker",
               now: fn -> DateTime.add(c.now, 62) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, recovered_remote} end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_second_patch)
                 flunk("canonical recovery must not repeat the committed PATCH")
               end
             )

    assert completed.state == :completed
    refute_received :unexpected_second_patch
    refute_received :administration_token

    assert %MirrorConflict{
             state: :resolved,
             resolution: %{"action" => "keep_fornacast", "v" => 1},
             resolved_by_user_id: actor_id
           } = Repo.get!(MirrorConflict, conflict.id)

    assert actor_id == c.actor.id
  end

  test "a revoked owner cannot turn a queued keep request into a GitHub PATCH", c do
    repository =
      c.binding.repository_id
      |> then(&Repo.get!(Repository, &1))
      |> Ecto.Changeset.change(description: "local choice before revocation")
      |> Ecto.Changeset.optimistic_lock(:write_version)
      |> Repo.update!()

    assert {:ok, _operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "metadata-resolution-integration:revoked-owner",
               DateTime.add(c.now, 1)
             )

    remote =
      c.binding
      |> remote(repository.slug, false, repository.visibility, DateTime.add(c.now, 1))
      |> Map.put(:description, "remote choice")

    assert {:ok, [{_operation_id, {:ok, %{action: :conflict, conflict: conflict}}}]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-revoked-conflict",
               now: fn -> DateTime.add(c.now, 1) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end
             )

    assert {:ok, %{operation: requested}} =
             ForgeMirrors.request_repository_metadata_conflict_resolution(
               c.actor,
               c.organization.organization_id,
               conflict,
               "keep_fornacast",
               DateTime.add(c.now, 2),
               request_metadata()
             )

    assert {:ok,
            [
              {operation_id,
               {:ok,
                %{
                  action: :conflict,
                  operation: %MirrorOperation{state: :failed} = failed,
                  conflict: rejected
                }}}
            ]} =
             RepositoryMetadataSyncWorker.run_once("metadata-resolution-revoked-worker",
               now: fn -> DateTime.add(c.now, 2) end,
               token_fetch: token_fetch(self()),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end,
               authorize_effect: fn operation, now ->
                 assert operation.external_effect_marker["attempt_state"] == "prepared"

                 Repo.delete_all(
                   from(member in ForgeAccounts.OrganizationMember,
                     where:
                       member.organization_id == ^c.organization.organization_id and
                         member.user_id == ^c.actor.id
                   )
                 )

                 ForgeMirrors.authorize_repository_metadata_effect(operation, now)
               end,
               repository_update: fn _, _, _, _, _ ->
                 send(self(), :unexpected_repository_patch)
                 flunk("revoked owner request must not patch GitHub")
               end
             )

    assert operation_id == requested.id
    assert failed.failure_class == "permission_missing"
    assert rejected.id == conflict.id
    assert rejected.conflict_kind == "repository_metadata_resolution_unauthorized"
    refute_received :administration_token
    refute_received :unexpected_repository_patch
  end

  defp token_fetch(test_pid) do
    fn
      _installation_id, %{permissions: %{"metadata" => "read"}} ->
        %InstallationToken{
          token: "metadata-policy-token",
          expires_at: ~U[2026-09-15 00:00:00Z],
          permissions: %{"metadata" => "read"}
        }

      _installation_id, %{permissions: %{"administration" => "write"}} ->
        send(test_pid, :administration_token)

        %InstallationToken{
          token: "metadata-policy-token",
          expires_at: ~U[2026-09-15 00:00:00Z],
          permissions: %{"administration" => "write"}
        }
    end
  end

  defp remote(binding, name, archived, visibility, updated_at) do
    repository = Repo.get!(Repository, binding.repository_id)

    %{
      id: binding.github_repository_id,
      node_id: binding.github_node_id,
      name: name,
      description: repository.description,
      visibility: visibility,
      default_branch: repository.default_branch,
      archived: archived,
      updated_at: updated_at
    }
  end

  defp request_metadata do
    %{
      request_id: Ecto.UUID.generate(),
      ip_address: "127.0.0.1",
      user_agent: "repository-metadata-policy-integration-test"
    }
  end
end
