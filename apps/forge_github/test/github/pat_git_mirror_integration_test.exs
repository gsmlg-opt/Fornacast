defmodule ForgeGitHub.PatGitMirrorIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo
  alias ForgeGitHub.{GitRefWorker, LFSSync}
  alias ForgeMirrors.{MirrorOperation, MirrorRefState, PatConfiguration, RepositoryMirror}
  alias GitCore.Remote.{ObservedRef, RefUpdate}

  @moduletag :tmp_dir
  @pat "github_pat_offline_mirror_integration_only"
  @kinds ["reconcile.repository.git", "sync.git_ref", "finalize.repository.git"]

  setup %{tmp_dir: tmp_root} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    previous_app = Application.get_env(:forge_github, :app_configuration, :disabled)
    Application.put_env(:fornacast, :repo_storage_root, Path.join(tmp_root, "repositories"))
    Application.put_env(:forge_github, :app_configuration, :disabled)

    on_exit(fn ->
      Application.put_env(:fornacast, :repo_storage_root, previous_root)
      Application.put_env(:forge_github, :app_configuration, previous_app)
    end)

    organization_id = organization_fixture()
    owner = organization_owner_fixture(organization_id)
    github_user_id = System.unique_integer([:positive])

    assert {:ok, account} =
             ForgeAccounts.save_github_account_if_absent(
               owner,
               %{
                 github_user_id: github_user_id,
                 login: "offline-pat-owner",
                 avatar_url: "https://avatars.githubusercontent.com/u/#{github_user_id}",
                 profile_url: "https://github.com/offline-pat-owner"
               },
               @pat,
               %{}
             )

    credential =
      Repo.get_by!(ForgeAccounts.GitHubCredential, github_identity_id: account.identity_id)

    refute credential.ciphertext == @pat

    config =
      Repo.insert!(%PatConfiguration{
        organization_id: organization_id,
        owner_user_id: owner.id,
        github_identity_id: account.identity_id,
        github_organization: "duskmoon-dev",
        enabled: true
      })

    repository_id = repository_fixture(organization_id)
    repository = Repo.get!(ForgeRepos.Repository, repository_id)

    repository =
      repository
      |> Ecto.Changeset.change(storage_path: "offline-pat/#{Ecto.UUID.generate()}.git")
      |> Repo.update!()

    local_path = ForgeRepos.absolute_storage_path(repository)
    seed_path = Path.join(tmp_root, "seed")
    remote_path = Path.join(tmp_root, "github.git")
    File.mkdir_p!(seed_path)
    File.mkdir_p!(Path.dirname(local_path))
    git!(seed_path, ["init", "--initial-branch=main"])
    initial = commit!(seed_path, "initial")
    git!(seed_path, ["clone", "--bare", seed_path, remote_path])
    git!(seed_path, ["clone", "--bare", seed_path, local_path])

    github_id = System.unique_integer([:positive])
    account_id = System.unique_integer([:positive])
    now = DateTime.utc_now(:second)

    run =
      Repo.insert!(
        struct(ForgeImports.ImportRun, %{
          actor_user_id: owner.id,
          source_kind: :organization,
          credential_source: :saved,
          github_identity_id: account.identity_id,
          github_credential_id: credential.id,
          source_owner_github_id: account_id,
          source_owner_login: "duskmoon-dev",
          destination_organization_action: :existing,
          destination_organization_id: organization_id,
          destination_organization_slug: Repo.get!(ForgeAccounts.User, organization_id).username,
          destination_organization_status: :clean,
          state: :completed,
          terminal_at: now
        })
      )

    Repo.insert!(
      struct(ForgeImports.RepositoryItem, %{
        import_run_id: run.id,
        github_repository_id: github_id,
        source_full_name: "duskmoon-dev/offline-pat",
        source_name: "offline-pat",
        source_observed_at: now,
        destination_owner_id: organization_id,
        destination_slug: repository.slug,
        destination_visibility: :private,
        hidden_repository_id: repository_id,
        state: :completed,
        publication_evidence: %{
          "state" => "committed",
          "repository_id" => repository_id,
          "owner_user_id" => organization_id,
          "generation" => repository.generation,
          "run_id" => run.id
        }
      })
    )

    %{
      owner: owner,
      config: config,
      organization_id: organization_id,
      repository: repository,
      local_path: local_path,
      remote_path: remote_path,
      seed_path: seed_path,
      initial: initial,
      github_id: github_id,
      account_id: account_id
    }
  end

  test "encrypted PAT drives durable initial, inbound and outbound Git/LFS reconciliation without an App",
       c do
    refute Repo.exists?(
             from i in ForgeMirrors.GitHubAppInstallation,
               where: i.github_account_id == ^c.account_id
           )

    assert {:ok, %{repository_mirrors: [binding], operations: [initial_operation]}} =
             ForgeMirrors.enroll_pat_git_repositories(
               c.owner,
               c.organization_id,
               c.config.lock_version,
               [c.repository.id],
               %{}
             )

    assert Repo.get!(ForgeMirrors.OrganizationMirror, binding.organization_mirror_id).github_installation_id ==
             nil

    c = Map.put(c, :binding, binding)
    refute Repo.exists?(from r in MirrorRefState, where: r.repository_mirror_id == ^binding.id)
    assert_complete(c, initial_operation, c.initial)

    inbound = commit!(c.seed_path, "inbound")
    git!(c.seed_path, ["push", c.remote_path, "main:main"])
    assert {:ok, inbound_operation} = schedule(c, "inbound")
    assert_complete(c, inbound_operation, inbound)
    assert git!(c.local_path, ["show", "main:inbound.txt"]) == "inbound"

    work_path = Path.join(Path.dirname(c.seed_path), "local-work")
    git!(c.seed_path, ["clone", c.local_path, work_path])
    outbound = commit!(work_path, "outbound")
    git!(work_path, ["push", c.local_path, "main:main"])
    assert {:ok, outbound_operation} = schedule(c, "outbound")
    assert_complete(c, outbound_operation, outbound)
    assert git!(c.remote_path, ["show", "main:outbound.txt"]) == "outbound"
    assert_received {:lfs_ready, :outbound, ^outbound}
    assert_received {:pushed, ^outbound}

    refute Repo.exists?(
             from o in MirrorOperation,
               where:
                 o.repository_mirror_id == ^binding.id and
                   o.kind == "reconcile.repository.metadata"
           )

    refute Repo.exists?(
             from i in ForgeMirrors.GitHubAppInstallation,
               where: i.github_account_id == ^c.account_id
           )
  end

  defp schedule(c, key) do
    ForgeMirrors.schedule_pat_git_repository(c.owner, c.config.id, c.repository.id, key)
  end

  defp assert_complete(c, parent, expected_oid) do
    drain(c, parent, DateTime.utc_now(:second), 0)
    assert {:ok, :complete} = status(c, parent)
    assert git!(c.local_path, ["rev-parse", "refs/heads/main"]) == expected_oid
    assert git!(c.remote_path, ["rev-parse", "refs/heads/main"]) == expected_oid

    baseline =
      Repo.get_by!(MirrorRefState,
        repository_mirror_id: c.binding.id,
        ref_name: "refs/heads/main"
      )

    assert baseline.state == :confirmed
    assert baseline.confirmed_oid == expected_oid
    assert baseline.last_local_oid == expected_oid
    assert baseline.last_remote_oid == expected_oid
    assert Repo.get!(RepositoryMirror, c.binding.id).last_synced_at != nil
  end

  defp drain(c, parent, started_at, attempts) when attempts < 100 do
    case status(c, parent) do
      {:ok, :complete} ->
        :ok

      {:ok, :pending} ->
        now = DateTime.add(started_at, attempts)

        assert {:ok, [operation]} =
                 ForgeMirrors.claim_pat_git_operations(
                   "offline-pat-integration",
                   now,
                   1_860,
                   1,
                   @kinds
                 )

        assert operation.repository_mirror_id == c.binding.id
        result = GitRefWorker.process_operation(operation, now, options(c))
        assert result == :ok or match?({:ok, _}, result), inspect(result)
        drain(c, parent, started_at, attempts + 1)

      failure ->
        flunk("durable reconciliation failed: #{inspect(failure)}")
    end
  end

  defp drain(_c, _parent, _started_at, _attempts), do: flunk("reconciliation did not finish")

  defp status(c, parent) do
    ForgeMirrors.pat_git_repository_status(c.owner, c.config.id, c.repository.id, parent.id)
  end

  defp options(c) do
    [
      repository_fetch: fn @pat, "duskmoon-dev", "offline-pat", opts ->
        assert match?({:saved_credential, _}, opts[:gate_key])

        {:ok,
         struct(ForgeGitHub.Repository,
           id: c.github_id,
           owner_id: c.account_id,
           node_id: "R_offline",
           owner_login: "duskmoon-dev",
           name: "offline-pat"
         )}
      end,
      fetch_refs: fn request, @pat, _namespace ->
        git!(request.repository_path, ["fetch", "--no-tags", c.remote_path, "refs/heads/main"])
        oid = git!(c.remote_path, ["rev-parse", "refs/heads/main"])
        {:ok, [%ObservedRef{ref: "refs/heads/main", oid: oid}]}
      end,
      lfs_gate: fn operation, sync, direction, oid, @pat, request ->
        result =
          LFSSync.ensure(operation, sync, direction, oid, @pat, request,
            authorize: fn ->
              case ForgeMirrors.authorize_git_lfs_effect(
                     operation,
                     operation.external_effect_marker
                   ) do
                {:ok, _} -> :ok
                error -> error
              end
            end
          )

        if result == :ok, do: send(self(), {:lfs_ready, direction, oid})
        result
      end,
      push_remote: fn request,
                      @pat,
                      %RefUpdate{ref: ref, expected_oid: expected, proposed_oid: proposed} ->
        assert_received {:lfs_ready, :outbound, ^proposed}
        assert git!(c.remote_path, ["rev-parse", ref]) == expected
        git!(request.repository_path, ["push", c.remote_path, "#{proposed}:#{ref}"])
        send(self(), {:lfs_ready, :outbound, proposed})
        send(self(), {:pushed, proposed})
        :ok
      end
    ]
  end

  defp commit!(path, name) do
    File.write!(Path.join(path, "#{name}.txt"), name)
    git!(path, ["add", "."])
    git!(path, ["commit", "-m", name])
    git!(path, ["rev-parse", "HEAD"])
  end

  defp git!(path, args) do
    {output, status} =
      System.cmd("git", args,
        cd: path,
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "Offline mirror test"},
          {"GIT_AUTHOR_EMAIL", "mirror@example.test"},
          {"GIT_COMMITTER_NAME", "Offline mirror test"},
          {"GIT_COMMITTER_EMAIL", "mirror@example.test"}
        ]
      )

    assert status == 0, output
    String.trim(output)
  end
end
