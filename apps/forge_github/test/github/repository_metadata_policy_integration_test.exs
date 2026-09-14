defmodule ForgeGitHub.RepositoryMetadataPolicyIntegrationTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures

  alias ForgeGitHub.{InstallationToken, RepositoryMetadataSyncWorker}
  alias ForgeMirrors.{MirrorConflict, RepositoryMirror}
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

    %{binding: Repo.get!(RepositoryMirror, binding.id), now: now}
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
end
