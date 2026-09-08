defmodule ForgeImports.CredentialProviderTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity}
  alias ForgeGitHub.{InstallationToken, InstallationTokenBroker, RequestGate}

  alias ForgeImports.{
    CredentialProvider,
    DiscoveryWorker,
    ImportAttempt,
    ImportRun,
    Persistence,
    RepositoryItem,
    RepositoryWorker,
    Worker
  }

  alias Fornacast.{OperationLease, Repo}

  @secret "saved-credential-provider-secret"
  @one_time_secret "one-time-credential-provider-secret"
  @app_secret "installation-credential-provider-secret"
  @metadata_secret "installation-metadata-provider-secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<7>>, 32)}}
  @app_scope %{
    permissions: %{
      "contents" => "read",
      "issues" => "read",
      "pull_requests" => "read"
    }
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    actor = user_fixture()
    account = saved_account_fixture(actor)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: account.identity_id)
    run = claimed_saved_run_fixture(actor, account.identity_id, credential.id)

    %{actor: actor, account: account, credential: credential, run: run}
  end

  test "saved PAT checkout exposes only public provider metadata", context do
    assert {:ok, :acknowledged} =
             CredentialProvider.checkout(
               %{actor: context.actor, run: context.run, capability: context.run},
               fn credential, metadata ->
                 send(self(), {:checked_out, credential, metadata})
                 :ok
               end
             )

    assert_receive {:checked_out, @secret,
                    %{
                      git_login: login,
                      gate_key: {:saved_credential, credential_id}
                    }}

    assert login == context.account.login
    assert credential_id == context.credential.id
  end

  test "one-time PAT checkout uses the same callback contract", context do
    identity = Repo.get!(GitHubIdentity, context.account.identity_id)
    run = claimed_one_time_run_fixture(context.actor, identity)

    assert {:ok, :acknowledged} =
             CredentialProvider.checkout(
               %{actor: context.actor, run: run, capability: run},
               fn credential, metadata ->
                 send(self(), {:checked_out, credential, metadata})
                 :ok
               end,
               keyring: @keyring
             )

    assert_receive {:checked_out, @one_time_secret,
                    %{
                      git_login: login,
                      gate_key: {:one_time_run, run_id}
                    }}

    assert login == identity.login
    assert run_id == run.id
  end

  test "recovery authorization rechecks App state and destination management inside a transaction",
       context do
    %{
      run: run,
      organization: organization,
      organization_mirror: mirror,
      installation_id: installation_id
    } = github_app_run_fixture(context.actor)

    item = %RepositoryItem{destination_owner_id: organization.id}

    check = fn ->
      Repo.transaction(fn -> CredentialProvider.authorize_recovery_locked(run, item) end)
    end

    assert {:error, :invalid_context} = CredentialProvider.authorize_recovery_locked(run, item)
    assert {:ok, :ok} = check.()

    Repo.update_all(from(m in ForgeMirrors.OrganizationMirror, where: m.id == ^mirror.id),
      set: [state: :paused]
    )

    assert {:ok, {:error, _}} = check.()

    Repo.update_all(from(m in ForgeMirrors.OrganizationMirror, where: m.id == ^mirror.id),
      set: [state: :bootstrapping]
    )

    Repo.update_all(
      from(i in ForgeMirrors.GitHubAppInstallation,
        where: i.github_installation_id == ^installation_id
      ), set: [state: :revoked])

    assert {:ok, {:error, _}} = check.()

    Repo.update_all(
      from(i in ForgeMirrors.GitHubAppInstallation,
        where: i.github_installation_id == ^installation_id
      ), set: [state: :active])

    Repo.update_all(
      from(m in ForgeAccounts.OrganizationMember,
        where: m.organization_id == ^organization.id and m.user_id == ^context.actor.id
      ), set: [role: :member])

    assert {:ok, {:error, :forbidden}} = check.()
  end

  test "GitHub App checkout derives the installation and never persists its token", context do
    %{run: run, installation_id: installation_id} = github_app_run_fixture(context.actor)
    parent = self()

    broker =
      start_broker(fn fetched_installation_id, scope ->
        send(parent, {:installation_token_fetch, fetched_installation_id, scope})

        %InstallationToken{
          token: @app_secret,
          expires_at: DateTime.add(DateTime.utc_now(:second), 3_600, :second),
          permissions: @app_scope.permissions
        }
      end)

    log =
      capture_log(fn ->
        assert {:ok, :acknowledged} =
                 CredentialProvider.checkout(
                   %{actor: context.actor, run: run, capability: run},
                   fn credential, metadata ->
                     send(self(), {:checked_out, credential, metadata})
                     :ok
                   end,
                   token_broker: broker,
                   scope: @app_scope
                 )
      end)

    assert_receive {:installation_token_fetch, ^installation_id, @app_scope}

    assert_receive {:checked_out, @app_secret,
                    %{
                      git_login: "x-access-token",
                      gate_key: {:github_installation, ^installation_id}
                    } = metadata}

    assert Map.keys(metadata) |> Enum.sort() == [:gate_key, :git_login]

    persisted = Repo.get!(ImportRun, run.id)
    assert persisted.credential_source == :github_app
    assert persisted.github_identity_id == nil
    assert persisted.github_credential_id == nil
    assert persisted.credential_ciphertext == nil
    assert persisted.credential_nonce == nil
    assert persisted.credential_tag == nil
    assert persisted.credential_key_id == nil
    refute inspect(persisted) =~ @app_secret
    refute log =~ @app_secret
  end

  test "transient GitHub App broker failure remains retryable", context do
    %{run: run} = github_app_run_fixture(context.actor)
    broker = start_broker(fn _installation_id, _scope -> {:error, :unavailable} end)

    assert {:error, {:retryable, :unavailable}} =
             CredentialProvider.checkout(
               %{actor: context.actor, run: run, capability: run},
               fn _credential, _metadata -> flunk("callback must not run without a token") end,
               token_broker: broker,
               scope: @app_scope
             )

    assert %ImportRun{state: :discovering, resume_state: nil, wait_reason: nil} =
             Repo.get!(ImportRun, run.id)
  end

  test "paused App bootstrap retains work without minting another token", context do
    %{run: run, organization_mirror: mirror} = github_app_run_fixture(context.actor)
    parent = self()

    broker =
      start_broker(fn _installation_id, _scope ->
        send(parent, :unexpected_token_fetch)
        installation_token(@app_secret)
      end)

    assert {:ok, _paused} = ForgeMirrors.pause(context.actor, mirror)

    assert {:error, {:retryable, :busy}} =
             CredentialProvider.checkout(
               %{actor: context.actor, run: run, capability: run},
               fn _credential, _metadata -> flunk("paused bootstrap must not use a token") end,
               token_broker: broker,
               scope: @app_scope
             )

    refute_receive :unexpected_token_fetch
  end

  test "GitHub App discovery broker failure releases for retry without human credentials",
       context do
    %{run: claimed} = github_app_run_fixture(context.actor)
    :ok = OperationLease.release(ImportRun, claimed)
    broker = start_broker(fn _installation_id, _scope -> {:error, :unavailable} end)

    assert {:error, :credential_service_unavailable} =
             DiscoveryWorker.perform(claimed.id,
               owner: "github-app-discovery-broker-failure",
               lease_seconds: 60,
               client: __MODULE__.AppDiscoveryClient,
               client_options: [test_pid: self()],
               token_broker: broker,
               token_scope: @app_scope
             )

    assert %ImportRun{
             state: :discovering,
             resume_state: nil,
             wait_reason: nil,
             lease_owner: nil,
             lease_expires_at: nil,
             terminal_at: nil,
             next_attempt_at: %DateTime{}
           } = Repo.get!(ImportRun, claimed.id)

    refute_receive :authenticated_user
  end

  test "GitHub App discovery uses an installation token without a user lookup", context do
    %{run: claimed, installation_id: installation_id, github_account_id: github_account_id} =
      github_app_run_fixture(context.actor)

    :ok = OperationLease.release(ImportRun, claimed)

    broker =
      start_broker(fn _fetched_installation_id, _scope ->
        %InstallationToken{
          token: @app_secret,
          expires_at: DateTime.add(DateTime.utc_now(:second), 3_600, :second),
          permissions: @app_scope.permissions
        }
      end)

    assert {:ok, :awaiting_resolution} =
             DiscoveryWorker.perform(claimed.id,
               owner: "github-app-discovery-test",
               lease_seconds: 60,
               client: __MODULE__.AppDiscoveryClient,
               client_options: [test_pid: self(), github_account_id: github_account_id],
               token_broker: broker,
               token_scope: @app_scope
             )

    assert_receive {:organization, @app_secret, {:github_installation, ^installation_id}}

    assert_receive {:organization_repositories, @app_secret,
                    {:github_installation, ^installation_id}}

    refute_receive :authenticated_user
  end

  test "GitHub App discovery applies the bound selected repository policy", context do
    %{
      run: claimed,
      installation_id: installation_id,
      github_account_id: github_account_id,
      organization_mirror: mirror
    } = github_app_run_fixture(context.actor)

    included_id = 9_700_000_001
    excluded_id = 9_700_000_002

    assert {:ok, _updated_mirror} =
             ForgeMirrors.update_organization_mirror(context.actor, mirror, %{
               policy: %{
                 "repository_selection" => "selected",
                 "selected_repository_ids" => [included_id],
                 "auto_import_new_repositories" => false
               }
             })

    :ok = OperationLease.release(ImportRun, claimed)

    broker = start_broker(fn _installation_id, _scope -> installation_token(@app_secret) end)

    assert {:ok, :awaiting_resolution} =
             DiscoveryWorker.perform(claimed.id,
               owner: "github-app-selected-policy-test",
               lease_seconds: 60,
               client: __MODULE__.AppDiscoveryClient,
               client_options: [
                 test_pid: self(),
                 github_account_id: github_account_id,
                 repositories: [
                   app_repository(
                     included_id,
                     github_account_id,
                     claimed.source_owner_login,
                     "one"
                   ),
                   app_repository(
                     excluded_id,
                     github_account_id,
                     claimed.source_owner_login,
                     "two"
                   )
                 ]
               ],
               token_broker: broker,
               token_scope: @app_scope
             )

    assert %ImportRun{selected_count: 1} = Repo.get!(ImportRun, claimed.id)

    assert [%RepositoryItem{github_repository_id: ^included_id}] =
             Repo.all(from item in RepositoryItem, where: item.import_run_id == ^claimed.id)

    assert_receive {:organization_repositories, @app_secret,
                    {:github_installation, ^installation_id}}
  end

  test "GitHub App worker advances a conflict-free bootstrap into running", context do
    %{run: claimed, github_account_id: github_account_id} =
      github_app_run_fixture(context.actor)

    :ok = OperationLease.release(ImportRun, claimed)
    broker = start_broker(fn _installation_id, _scope -> installation_token(@app_secret) end)

    assert {:ok, :running} =
             Worker.run_discovery(claimed.id, "github-app-bootstrap-worker",
               lease_seconds: 60,
               client: __MODULE__.AppDiscoveryClient,
               client_options: [
                 test_pid: self(),
                 github_account_id: github_account_id,
                 repositories: [
                   app_repository(
                     9_800_000_001,
                     github_account_id,
                     claimed.source_owner_login,
                     "clean"
                   )
                 ]
               ],
               token_broker: broker,
               token_scope: @app_scope
             )

    assert %ImportRun{state: :running, selected_count: 1} = Repo.get!(ImportRun, claimed.id)

    assert [%RepositoryItem{state: :queued, wait_reason: nil}] =
             Repo.all(from item in RepositoryItem, where: item.import_run_id == ^claimed.id)
  end

  @tag :tmp_dir
  test "GitHub App worker leaves an item conflict awaiting resolution", context do
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, context.tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    %{run: claimed, github_account_id: github_account_id, organization: organization} =
      github_app_run_fixture(context.actor)

    assert {:ok, _repository} =
             ForgeRepos.create_repository(organization, %{
               slug: "conflict",
               name: "Existing conflict",
               visibility: :private
             })

    :ok = OperationLease.release(ImportRun, claimed)
    broker = start_broker(fn _installation_id, _scope -> installation_token(@app_secret) end)

    assert {:ok, :awaiting_resolution} =
             Worker.run_discovery(claimed.id, "github-app-conflict-worker",
               lease_seconds: 60,
               client: __MODULE__.AppDiscoveryClient,
               client_options: [
                 test_pid: self(),
                 github_account_id: github_account_id,
                 repositories: [
                   app_repository(
                     9_800_000_002,
                     github_account_id,
                     claimed.source_owner_login,
                     "conflict"
                   )
                 ]
               ],
               token_broker: broker,
               token_scope: @app_scope
             )

    assert %ImportRun{state: :awaiting_resolution, selected_count: 1} =
             Repo.get!(ImportRun, claimed.id)

    assert [%RepositoryItem{state: :awaiting_resolution, wait_reason: "repository_conflict"}] =
             Repo.all(from item in RepositoryItem, where: item.import_run_id == ^claimed.id)
  end

  @tag :tmp_dir
  test "GitHub App repository staging checks out an item-scoped installation token", context do
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, context.tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    %{item: item, installation_id: installation_id} =
      github_app_item_fixture(context.actor)

    parent = self()

    broker =
      start_broker(fn fetched_installation_id, scope ->
        send(parent, {:installation_token_fetch, fetched_installation_id, scope})

        %InstallationToken{
          token: @app_secret,
          expires_at: DateTime.add(DateTime.utc_now(:second), 3_600, :second),
          permissions: @app_scope.permissions
        }
      end)

    assert {:ok, %RepositoryItem{state: :git_staged}} =
             RepositoryWorker.stage(item.id,
               owner: "github-app-repository-test",
               lease_seconds: 60,
               remote: __MODULE__.AppRemote,
               remote_options: [test_pid: self()],
               token_broker: broker,
               token_scope: @app_scope
             )

    assert_receive {:mirror, @app_secret,
                    %GitCore.Remote.Request{credential_login: "x-access-token"}}

    assert_receive {:installation_token_fetch, ^installation_id, @app_scope}

    persisted = Repo.get!(ImportRun, item.import_run_id)
    assert persisted.credential_source == :github_app
    assert persisted.github_identity_id == nil
    assert persisted.github_credential_id == nil
    refute inspect(persisted) =~ @app_secret
  end

  @tag :tmp_dir
  test "GitHub App metadata recovery reacquires a broker token and uses its gate", context do
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, context.tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    %{item: item, installation_id: installation_id} =
      github_app_item_fixture(context.actor)

    first_broker =
      start_broker(fn _installation_id, _scope ->
        installation_token(@app_secret)
      end)

    assert {:ok, %RepositoryItem{state: :git_staged}} =
             RepositoryWorker.stage(item.id,
               owner: "github-app-git-stage",
               lease_seconds: 60,
               remote: __MODULE__.AppRemote,
               remote_options: [test_pid: self()],
               token_broker: first_broker,
               token_scope: @app_scope
             )

    parent = self()
    blocked_gate = {:one_time_run, item.import_run_id}

    gate_holder =
      Task.async(fn ->
        RequestGate.run(blocked_gate, fn ->
          send(parent, :legacy_gate_held)

          receive do
            :release_legacy_gate -> :ok
          end
        end)
      end)

    assert_receive :legacy_gate_held

    metadata_broker =
      start_broker(fn fetched_installation_id, scope ->
        send(parent, {:metadata_token_fetch, fetched_installation_id, scope})
        installation_token(@metadata_secret)
      end)

    try do
      assert {:ok, %RepositoryItem{state: :ready_to_publish}} =
               RepositoryWorker.stage(item.id,
                 owner: "github-app-metadata-recovery",
                 lease_seconds: 60,
                 remote: __MODULE__.AppRemote,
                 remote_options: [test_pid: self()],
                 client_options: empty_metadata_client_options(self()),
                 token_broker: metadata_broker,
                 token_scope: @app_scope
               )
    after
      send(gate_holder.pid, :release_legacy_gate)
      assert :ok = Task.await(gate_holder)
    end

    assert_receive {:metadata_token_fetch, ^installation_id, @app_scope}
    assert_receive {:metadata_request, "/repos/", "Bearer " <> @metadata_secret}

    persisted = Repo.get!(ImportRun, item.import_run_id)
    refute inspect(persisted) =~ @metadata_secret
  end

  @tag :tmp_dir
  test "GitHub App metadata broker failure retries without awaiting human credentials", context do
    original_root = Application.fetch_env!(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, context.tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, original_root) end)

    %{item: item} = github_app_item_fixture(context.actor)

    first_broker =
      start_broker(fn _installation_id, _scope -> installation_token(@app_secret) end)

    assert {:ok, %RepositoryItem{state: :git_staged}} =
             RepositoryWorker.stage(item.id,
               owner: "github-app-metadata-broker-setup",
               lease_seconds: 60,
               remote: __MODULE__.AppRemote,
               remote_options: [test_pid: self()],
               token_broker: first_broker,
               token_scope: @app_scope
             )

    unavailable_broker =
      start_broker(fn _installation_id, _scope -> {:error, :unavailable} end)

    assert {:error, :staging_unavailable} =
             RepositoryWorker.stage(item.id,
               owner: "github-app-metadata-broker-failure",
               lease_seconds: 60,
               remote: __MODULE__.AppRemote,
               remote_options: [test_pid: self()],
               client_options: empty_metadata_client_options(self()),
               token_broker: unavailable_broker,
               token_scope: @app_scope
             )

    assert %RepositoryItem{
             state: :staging_metadata,
             resume_state: nil,
             wait_reason: nil,
             lease_owner: nil,
             lease_expires_at: nil,
             next_attempt_at: %DateTime{}
           } = Repo.get!(RepositoryItem, item.id)

    assert %ImportRun{state: :running, resume_state: nil, wait_reason: nil} =
             Repo.get!(ImportRun, item.import_run_id)

    refute_receive {:metadata_request, _, _}
  end

  defmodule AppDiscoveryClient do
    def authenticated_user(_credential, opts) do
      send(Keyword.fetch!(opts, :test_pid), :authenticated_user)
      raise "GitHub App discovery must not fetch /user"
    end

    def organization(credential, login, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:organization, credential, Keyword.fetch!(opts, :gate_key)}
      )

      {:ok,
       %ForgeGitHub.Organization{
         id: Keyword.fetch!(opts, :github_account_id),
         login: login,
         name: "GitHub App Organization",
         description: nil,
         avatar_url: nil,
         html_url: "https://github.com/#{login}"
       }}
    end

    def organization_repositories(credential, _login, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:organization_repositories, credential, Keyword.fetch!(opts, :gate_key)}
      )

      {:ok, Keyword.get(opts, :repositories, [])}
    end
  end

  defmodule AppRemote do
    def mirror(request, credential, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:mirror, credential, request})

      {:ok,
       %GitCore.Remote.Result{
         path: request.destination,
         empty?: true,
         default_branch: request.default_branch,
         refs: 0,
         bytes: 0
       }}
    end

    def refresh(_request, _credential, _opts), do: raise("unexpected refresh")
    def cleanup_evidence(_destination), do: {:error, :cleanup_not_found}
  end

  defp claimed_saved_run_fixture(actor, identity_id, credential_id) do
    {:ok, run} =
      Persistence.insert_run(%{
        actor_user_id: actor.id,
        source_kind: :organization,
        github_identity_id: identity_id,
        credential_source: :saved,
        github_credential_id: credential_id,
        source_owner_github_id: 9_500_000_001,
        source_owner_login: "acme",
        state: :discovering,
        request_metadata: request_metadata()
      })

    {:ok, claimed} =
      OperationLease.claim(
        ImportRun,
        run.id,
        "credential-provider-test",
        DateTime.utc_now(:second),
        60
      )

    claimed
  end

  defp claimed_one_time_run_fixture(actor, identity) do
    {:ok, run} =
      Persistence.insert_run(%{
        actor_user_id: actor.id,
        source_kind: :organization,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 9_500_000_002,
        source_owner_login: "acme",
        state: :discovering,
        request_metadata: request_metadata()
      })

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        actor.id,
        identity.github_user_id,
        @one_time_secret,
        @keyring
      )

    {:ok, attached} = ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring)

    {:ok, claimed} =
      OperationLease.claim(
        ImportRun,
        attached.id,
        "one-time-credential-provider-test",
        DateTime.utc_now(:second),
        60
      )

    claimed
  end

  defp github_app_run_fixture(actor) do
    suffix = System.unique_integer([:positive])
    installation_id = 9_300_000_000 + suffix
    github_account_id = 9_400_000_000 + suffix

    {:ok, organization} =
      ForgeAccounts.create_organization(actor, %{
        username: "app-provider-org-#{suffix}",
        display_name: "App Provider Org #{suffix}"
      })

    {:ok, _installation} =
      ForgeMirrors.observe_github_app_installation(%{
        github_installation_id: installation_id,
        github_account_id: github_account_id,
        github_account_login: "github-app-org-#{suffix}",
        account_type: :organization,
        repository_selection: :selected,
        permissions: @app_scope.permissions,
        state: :active,
        last_verified_at: DateTime.utc_now(:microsecond)
      })

    {:ok, run} =
      Persistence.insert_run(%{
        actor_user_id: actor.id,
        source_kind: :organization,
        github_identity_id: nil,
        credential_source: :github_app,
        github_credential_id: nil,
        source_owner_github_id: github_account_id,
        source_owner_login: "github-app-org-#{suffix}",
        destination_organization_action: :existing,
        destination_organization_slug: organization.username,
        destination_organization_id: organization.id,
        destination_organization_status: :clean,
        state: :discovering,
        request_metadata: request_metadata()
      })

    {:ok, mirror} =
      ForgeMirrors.create_organization_mirror(actor, %{
        organization_id: organization.id,
        provider: "github",
        github_installation_id: installation_id,
        github_account_id: github_account_id,
        github_account_login: "github-app-org-#{suffix}",
        bootstrap_import_run_id: run.id
      })

    {:ok, ready} =
      ForgeMirrors.transition_organization_mirror(actor, mirror, :ready_to_bootstrap)

    {:ok, bootstrapping} =
      ForgeMirrors.transition_organization_mirror(actor, ready, :bootstrapping)

    {:ok, claimed} =
      OperationLease.claim(
        ImportRun,
        run.id,
        "github-app-credential-provider-test",
        DateTime.utc_now(:second),
        60
      )

    %{
      run: claimed,
      installation_id: installation_id,
      github_account_id: github_account_id,
      organization: organization,
      organization_mirror: bootstrapping
    }
  end

  defp app_repository(id, owner_id, owner_login, name) do
    %ForgeGitHub.Repository{
      id: id,
      owner_id: owner_id,
      owner_login: owner_login,
      name: name,
      full_name: "#{owner_login}/#{name}",
      description: nil,
      visibility: :private,
      default_branch: "main",
      has_issues: true,
      allow_merge_commit: true,
      fork: false,
      archived: false,
      html_url: "https://github.com/#{owner_login}/#{name}",
      updated_at: nil,
      pushed_at: nil
    }
  end

  defp github_app_item_fixture(actor) do
    %{run: claimed, organization: organization} = binding = github_app_run_fixture(actor)
    :ok = OperationLease.release(ImportRun, claimed)
    now = DateTime.utc_now(:second)

    assert {1, _rows} =
             Repo.update_all(
               from(run in ImportRun, where: run.id == ^claimed.id),
               set: [
                 state: :running,
                 selected_count: 1,
                 source_metadata: %{"observed_at" => DateTime.to_iso8601(now)},
                 updated_at: now
               ]
             )

    run = Repo.get!(ImportRun, claimed.id)

    {:ok, item} =
      Persistence.insert_repository_item(%{
        import_run_id: run.id,
        github_repository_id: 9_600_000_000 + System.unique_integer([:positive]),
        source_full_name: "#{run.source_owner_login}/demo",
        source_name: "demo",
        source_metadata: %{
          "default_branch" => "main",
          "visibility" => "private",
          "description" => nil,
          "has_issues" => true,
          "allow_merge_commit" => true,
          "fork" => false,
          "archived" => false
        },
        source_observed_at: now,
        selected: true,
        destination_owner_id: organization.id,
        destination_slug: "demo",
        destination_visibility: :private,
        state: :queued,
        attempt_count: 1
      })

    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{"action" => "create", "slug" => item.destination_slug},
      started_at: now
    })
    |> Repo.insert!()

    Map.merge(binding, %{run: run, item: item})
  end

  defp start_broker(fetcher) do
    suffix = System.unique_integer([:positive])

    supervisor =
      start_supervised!({Task.Supervisor, name: Module.concat(__MODULE__, "Task#{suffix}")})

    broker_name = Module.concat(__MODULE__, "Broker#{suffix}")

    start_supervised!(%{
      id: broker_name,
      start:
        {InstallationTokenBroker, :start_link,
         [[name: broker_name, task_supervisor: supervisor, fetcher: fetcher]]}
    })
  end

  defp installation_token(token) do
    %InstallationToken{
      token: token,
      expires_at: DateTime.add(DateTime.utc_now(:second), 3_600, :second),
      permissions: @app_scope.permissions
    }
  end

  defp empty_metadata_client_options(parent) do
    stub = {__MODULE__, :metadata, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      authorization = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
      send(parent, {:metadata_request, "/repos/", authorization})

      if String.ends_with?(conn.request_path, "/labels") or
           String.ends_with?(conn.request_path, "/issues") do
        Req.Test.json(conn, [])
      else
        Plug.Conn.send_resp(conn, 404, "{}")
      end
    end)

    [
      plug: {Req.Test, stub},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
  end

  defp saved_account_fixture(actor) do
    suffix = System.unique_integer([:positive])

    {:ok, account} =
      ForgeAccounts.save_github_account(
        actor,
        %{
          github_user_id: 9_100_000_000 + suffix,
          login: "saved-provider-#{suffix}",
          avatar_url: nil,
          profile_url: "https://github.com/saved-provider-#{suffix}"
        },
        @secret,
        request_metadata()
      )

    account
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "credential-provider-#{suffix}",
        email: "credential-provider-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    actor
  end

  defp request_metadata do
    suffix = System.unique_integer([:positive])

    %{
      "request_id" => "credential-provider-request-#{suffix}",
      "operation_id" => "credential-provider-operation-#{suffix}",
      "ip_address" => "203.0.113.19",
      "user_agent" => "Fornacast credential provider test"
    }
  end
end
