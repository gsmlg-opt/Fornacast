defmodule ForgeGitHub.RepositoryCreationIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.{DomainOutboxEvent, Repo}
  alias ForgeGitHub.{Error, InstallationToken, RepositoryCreationWorker}

  alias ForgeMirrors.{
    GitHubAppInstallation,
    MirrorOperation,
    MirrorResourceState,
    RepositoryMirror
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        policy: %{"auto_create_remote_repositories" => true},
        capabilities: %{"git" => "enabled"}
      })

    installation =
      Repo.get_by!(GitHubAppInstallation,
        github_installation_id: organization.github_installation_id
      )

    {:ok, _installation} =
      ForgeMirrors.observe_github_app_installation(%{
        github_installation_id: organization.github_installation_id,
        github_account_id: organization.github_account_id,
        github_account_login: organization.github_account_login,
        account_type: :organization,
        repository_selection: :all,
        permissions: %{"metadata" => "read", "administration" => "write"},
        state: :active,
        last_verified_at: DateTime.add(installation.last_verified_at, 1, :second)
      })

    repository_id = repository_fixture(organization.organization_id)
    now = DateTime.utc_now(:second)

    event = %DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(repository_id),
      event_type: "repository.created",
      origin: :fornacast,
      payload: %{
        "repository_id" => repository_id,
        "owner_id" => organization.organization_id
      },
      available_at: now
    }

    assert {:ok, {:materialized, [%MirrorOperation{id: operation_id}]}} =
             ForgeMirrors.materialize_outbox_event(event)

    %{
      organization: organization,
      repository_id: repository_id,
      operation_id: operation_id,
      now: now
    }
  end

  test "the leased worker creates, binds, and baselines a local repository", c do
    remote = remote(c)

    assert {:ok, [{operation_id, {:ok, result}}]} =
             RepositoryCreationWorker.run_once("repository-create-integration",
               now: fn -> c.now end,
               token_fetch: token_fetch(),
               repository_fetch: fn _, _, _, _ -> {:error, Error.new(:not_found)} end,
               repository_create: fn _, owner, attrs, _ ->
                 assert owner == c.organization.github_account_login
                 assert attrs["name"] == remote.name
                 {:ok, remote}
               end
             )

    assert operation_id == c.operation_id
    assert result.operation.state == :completed
    assert result.git_reconciliation.kind == "reconcile.repository.git"
    assert result.git_reconciliation.state == :pending

    binding = Repo.get_by!(RepositoryMirror, repository_id: c.repository_id)
    assert binding.state == :discovered
    assert binding.github_repository_id == remote.id
    assert binding.github_node_id == remote.node_id

    remote_id = remote.id
    remote_node_id = remote.node_id

    assert %MirrorResourceState{
             state: :confirmed,
             github_object_id: ^remote_id,
             github_node_id: ^remote_node_id
           } =
             Repo.one!(
               from state in MirrorResourceState,
                 where:
                   state.repository_mirror_id == ^binding.id and
                     state.resource_kind == :repository
             )
  end

  test "a lost create response is recovered by GET without a second POST", c do
    assert {:ok, [{operation_id, {:ok, %MirrorOperation{state: :effect_pending} = deferred}}]} =
             RepositoryCreationWorker.run_once("repository-create-timeout",
               now: fn -> c.now end,
               token_fetch: token_fetch(),
               repository_fetch: fn _, _, _, _ -> {:error, Error.new(:not_found)} end,
               repository_create: fn _, _, _, _ -> {:error, Error.new(:timeout)} end
             )

    assert operation_id == c.operation_id
    assert is_map(deferred.external_effect_marker)
    assert deferred.lease_owner == nil

    recovered_at = DateTime.add(c.now, 60)
    remote = remote(c, updated_at: recovered_at)

    assert {:ok, [{^operation_id, {:ok, result}}]} =
             RepositoryCreationWorker.run_once("repository-create-recovery",
               now: fn -> recovered_at end,
               token_fetch: token_fetch(),
               repository_fetch: fn _, _, _, _ -> {:ok, remote} end,
               repository_create: fn _, _, _, _ -> flunk("must not repeat the create POST") end
             )

    assert result.operation.state == :completed

    assert Repo.get_by!(RepositoryMirror, repository_id: c.repository_id).github_repository_id ==
             41
  end

  defp token_fetch do
    fn _installation_id, _requirements ->
      %InstallationToken{
        token: "installation-token",
        expires_at: DateTime.add(DateTime.utc_now(:second), 3_600),
        permissions: %{"metadata" => "read", "administration" => "write"}
      }
    end
  end

  defp remote(c, overrides \\ []) do
    repository = Repo.get!(ForgeRepos.Repository, c.repository_id)

    %{
      id: 41,
      node_id: "R_41",
      owner_id: c.organization.github_account_id,
      owner_login: c.organization.github_account_login,
      full_name: "#{c.organization.github_account_login}/#{repository.slug}",
      name: repository.slug,
      description: repository.description,
      visibility: repository.visibility,
      default_branch: repository.default_branch,
      archived: false,
      updated_at: Keyword.get(overrides, :updated_at, c.now)
    }
  end
end
