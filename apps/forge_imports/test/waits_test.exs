defmodule ForgeImports.WaitsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}
  alias ForgeImports.GitHub.Error
  alias ForgeImports.GitHub.User, as: GitHubUser
  alias ForgeImports.{ImportAttempt, ImportRun, Persistence, Recovery, Scheduler, Waits}
  alias ForgeImports.RepositoryItem
  alias ForgeRepos.Repository
  alias Fornacast.{OperationLease, Repo}

  @now ~U[2026-08-25 10:00:00Z]
  @retry_at ~U[2026-08-25 11:00:00Z]
  @pat "github_pat_waits_test_secret"
  @second_pat "github_pat_waits_second_secret"
  @keyring %{active: "test-v1", keys: %{"test-v1" => :binary.copy(<<9>>, 32)}}

  defmodule StubClient do
    def authenticated_user(_pat, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:authenticated_user, Keyword.fetch!(opts, :gate_key)}
      )

      Keyword.fetch!(opts, :response)
    end
  end

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      ForgeImports.RecoveryTestHelper.mark_sandbox_owner!()
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture()
    identity = identity_fixture(actor, 9_000_000_101, "waits-octocat")
    view = saved_account!(actor, identity, @pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    run = saved_running_run!(actor, view, credential)
    item = staging_git_item!(run, actor)
    attempt_fixture(item)

    %{
      actor: actor,
      identity: identity,
      view: view,
      credential: credential,
      run: run,
      item: item
    }
  end

  test "primary and secondary rate limits persist a durable wait without changing phase", %{
    run: run,
    actor: actor
  } do
    for {classification, index} <- Enum.with_index([:primary, :secondary], 1) do
      item = staging_git_item!(run, actor, 9_200_000_050 + index)
      attempt_fixture(item)

      assert {:ok, waiting} = Waits.rate_limited(item, @retry_at, classification)
      assert waiting.state == :staging_git
      assert waiting.wait_reason == "rate_limit"
      assert waiting.next_attempt_at == @retry_at
      assert is_nil(waiting.resume_state)

      refute Scheduler.claimable?(waiting, DateTime.add(@retry_at, -1, :second))
      assert Scheduler.claimable?(waiting, @retry_at)
    end
  end

  test "rate-limited items are not busy-retried before the exact retry boundary", %{item: item} do
    assert {:ok, waiting} = Waits.rate_limited(item, @retry_at, :secondary)

    refute waiting.id in Scheduler.claimable_item_ids(@now, 100)
    refute waiting.id in Scheduler.claimable_item_ids(DateTime.add(@retry_at, -1, :second), 100)
    assert waiting.id in Scheduler.claimable_item_ids(@retry_at, 100)
  end

  test "restart during a rate wait preserves the persisted retry window", %{item: item} do
    assert {:ok, waiting} = Waits.rate_limited(item, @retry_at, :primary)
    reloaded = Repo.get!(RepositoryItem, waiting.id)

    refute Scheduler.claimable?(reloaded, @now)
    assert Scheduler.claimable?(Repo.get!(RepositoryItem, item.id), @retry_at)
  end

  test "awaiting credential preserves the exact pre-wait item phase", %{run: run, item: item} do
    assert {:ok, {waiting_run, waiting_item}} =
             Waits.awaiting_credential(run, item, :staging_git, wait_reason: "credential_invalid")

    assert waiting_run.state == :awaiting_credential
    assert waiting_run.resume_state == :running
    assert waiting_run.wait_reason == "credential_invalid"
    assert is_nil(waiting_run.next_attempt_at)

    assert waiting_item.state == :awaiting_credential
    assert waiting_item.resume_state == :staging_git
    assert waiting_item.wait_reason == "credential_invalid"
    assert is_nil(waiting_item.next_attempt_at)
    refute Scheduler.claimable?(waiting_item, @now)
  end

  test "resume_with_credential restores saved credentials to the exact persisted phase", %{
    actor: actor,
    view: view,
    credential: credential,
    run: run,
    item: item
  } do
    assert {:ok, {_run, _item}} =
             Waits.awaiting_credential(run, item, :staging_git, wait_reason: "credential_invalid")

    waiting_run = Repo.get!(ImportRun, run.id)

    assert {:ok, resumed_run} =
             Waits.resume_with_credential(
               actor,
               waiting_run,
               %{
                 credential_source: :saved,
                 github_identity_id: view.identity_id,
                 github_credential_id: credential.id
               },
               request_metadata("resume-saved")
             )

    assert resumed_run.state == :running
    assert resumed_run.github_credential_id == credential.id
    assert is_nil(resumed_run.resume_state)
    assert is_nil(resumed_run.wait_reason)
    assert is_nil(resumed_run.next_attempt_at)

    resumed_item = Repo.get!(RepositoryItem, item.id)
    assert resumed_item.state == :staging_git
    assert is_nil(resumed_item.resume_state)
    assert is_nil(resumed_item.wait_reason)
    assert is_nil(resumed_item.next_attempt_at)
    assert Scheduler.claimable?(resumed_item, @now)
  end

  test "one-time replacement verifies the same GitHub identity before resuming", %{
    actor: actor,
    identity: identity,
    run: run,
    item: item
  } do
    one_time_run = one_time_running_run!(actor, identity)
    one_time_item = staging_git_item!(one_time_run, actor)
    attempt_fixture(one_time_item)

    assert {:ok, {_run, _item}} =
             Waits.awaiting_credential(one_time_run, one_time_item, :staging_git,
               wait_reason: "credential_unavailable"
             )

    assert {:ok, resumed} =
             Waits.resume_with_credential(
               actor,
               Repo.get!(ImportRun, one_time_run.id),
               %{credential_source: :one_time, pat: @second_pat},
               request_metadata("resume-one-time"),
               client: StubClient,
               test_pid: self(),
               response: {:ok, github_user(identity.github_user_id, "waits-octocat")}
             )

    assert resumed.credential_source == :one_time
    assert resumed.state == :running
    assert is_binary(resumed.credential_ciphertext)
    assert Repo.get!(RepositoryItem, one_time_item.id).state == :staging_git
    assert_receive {:authenticated_user, {:one_time_run, run_id}} when run_id == resumed.id
  end

  test "resume_with_credential rejects a mismatched GitHub identity", %{
    actor: actor,
    identity: identity
  } do
    one_time_run = one_time_running_run!(actor, identity)
    one_time_item = staging_git_item!(one_time_run, actor)
    attempt_fixture(one_time_item)

    assert {:ok, {_run, _item}} =
             Waits.awaiting_credential(one_time_run, one_time_item, :staging_git,
               wait_reason: "credential_invalid"
             )

    assert {:error, :identity_mismatch} =
             Waits.resume_with_credential(
               actor,
               Repo.get!(ImportRun, one_time_run.id),
               %{credential_source: :one_time, pat: @second_pat},
               request_metadata("resume-mismatch"),
               client: StubClient,
               test_pid: self(),
               response: {:ok, github_user(9_000_000_999, "someone-else")}
             )

    assert Repo.get!(ImportRun, one_time_run.id).state == :awaiting_credential
    assert Repo.get!(RepositoryItem, one_time_item.id).state == :awaiting_credential
  end

  test "foreign-run resume attempts are masked as not found", %{
    view: view,
    credential: credential,
    run: run,
    item: item
  } do
    other = user_fixture()

    assert {:ok, {_run, _item}} =
             Waits.awaiting_credential(run, item, :staging_git, wait_reason: "credential_invalid")

    assert {:error, :not_found} =
             Waits.resume_with_credential(
               other,
               Repo.get!(ImportRun, run.id),
               %{
                 credential_source: :saved,
                 github_identity_id: view.identity_id,
                 github_credential_id: credential.id
               },
               request_metadata("foreign-resume")
             )

    assert {:error, :not_found} = ForgeImports.get_run(other, run.id)
  end

  test "replace_run_credential delegates to resume_with_credential", %{
    actor: actor,
    view: view,
    credential: credential,
    run: run,
    item: item
  } do
    assert {:ok, {_run, _item}} =
             Waits.awaiting_credential(run, item, :staging_git, wait_reason: "credential_invalid")

    assert {:ok, resumed} =
             ForgeImports.replace_run_credential(
               actor,
               run.id,
               %{
                 credential_source: :saved,
                 github_identity_id: view.identity_id,
                 github_credential_id: credential.id
               },
               request_metadata("replace-run-credential")
             )

    assert resumed.state == :running
    assert Repo.get!(RepositoryItem, item.id).state == :staging_git
  end

  test "recovery moves saved runs with a missing credential into awaiting_credential", %{
    credential: credential,
    run: run,
    item: item
  } do
    assert {1, _} =
             Repo.update_all(
               from(candidate in GitHubCredential, where: candidate.id == ^credential.id),
               set: [status: :invalid]
             )

    assert {:ok, reconciled} = Recovery.reconcile(Repo.get!(RepositoryItem, item.id), now: @now)

    assert reconciled.state == :awaiting_credential
    assert reconciled.resume_state == :staging_git
    assert reconciled.wait_reason == "credential_unavailable"

    paused_run = Repo.get!(ImportRun, run.id)
    assert paused_run.state == :awaiting_credential
    assert paused_run.resume_state == :running
    assert paused_run.github_credential_id == credential.id
  end

  test "insufficient saved credential checkout pauses through awaiting_credential", %{
    credential: credential,
    run: run,
    item: item
  } do
    assert {1, _} =
             Repo.update_all(
               from(candidate in GitHubCredential, where: candidate.id == ^credential.id),
               set: [status: :invalid]
             )

    assert {:ok, {paused_run, paused_item}} =
             Waits.pause_for_missing_saved_credential(Repo.get!(ImportRun, run.id), item,
               wait_reason: "credential_invalid"
             )

    assert paused_run.state == :awaiting_credential
    assert paused_item.state == :awaiting_credential
    assert paused_item.resume_state == :staging_git
    refute Scheduler.claimable?(paused_item, @now)
  end

  defp staging_git_item!(run, actor, github_repository_id \\ 9_200_000_040) do
    shadow = importing_shadow_fixture!(actor)

    Persistence.insert_repository_item(%{
      import_run_id: run.id,
      github_repository_id: github_repository_id,
      source_full_name: "acme/demo",
      source_name: "demo",
      source_metadata: %{"default_branch" => "main", "visibility" => "private"},
      source_observed_at: @now,
      selected: true,
      destination_owner_id: actor.id,
      destination_owner_kind: :user,
      destination_slug: "demo-waits",
      destination_visibility: :private,
      state: :staging_git,
      hidden_repository_id: shadow.id,
      staged_storage_path: ForgeRepos.absolute_storage_path(shadow),
      attempt_count: 1
    })
    |> unwrap!()
  end

  defp saved_running_run!(actor, view, credential) do
    %{
      actor_user_id: actor.id,
      source_kind: :repository,
      github_identity_id: view.identity_id,
      credential_source: :saved,
      github_credential_id: credential.id,
      source_owner_github_id: 9_000_000_101,
      source_owner_login: "acme",
      source_repository_github_id: 9_200_000_040,
      source_repository_full_name: "acme/demo",
      destination_organization_action: :existing,
      destination_organization_slug: actor.username,
      destination_organization_status: :clean,
      state: :running,
      selected_count: 1,
      request_metadata: request_metadata()
    }
    |> Persistence.insert_run()
    |> unwrap!()
  end

  defp one_time_running_run!(actor, identity) do
    run =
      %{
        actor_user_id: actor.id,
        source_kind: :repository,
        github_identity_id: identity.id,
        credential_source: :one_time,
        source_owner_github_id: 9_000_000_101,
        source_owner_login: "acme",
        source_repository_github_id: 9_200_000_041,
        source_repository_full_name: "acme/one-time",
        destination_organization_action: :existing,
        destination_organization_slug: actor.username,
        destination_organization_status: :clean,
        state: :running,
        selected_count: 1,
        request_metadata: request_metadata()
      }
      |> Persistence.insert_run()
      |> unwrap!()

    {:ok, envelope} =
      ForgeAccounts.GitHubCredentialVault.encrypt_one_time(
        run.id,
        actor.id,
        identity.github_user_id,
        @pat,
        @keyring
      )

    ForgeImports.attach_one_time_credential(actor, run, envelope, @keyring) |> unwrap!()
  end

  defp importing_shadow_fixture!(actor) do
    %Repository{}
    |> Repository.import_changeset(%{
      owner_user_id: actor.id,
      slug: "shadow-waits-#{System.unique_integer([:positive])}",
      name: "Shadow Waits",
      visibility: :private,
      storage_path: "@test/shadow-waits-#{System.unique_integer([:positive])}.git",
      lifecycle: :importing,
      generation: 1
    })
    |> Repo.insert!()
  end

  defp attempt_fixture(item) do
    %ImportAttempt{}
    |> ImportAttempt.create_changeset(%{
      repository_item_id: item.id,
      attempt_number: 1,
      state: :running,
      decision: %{"action" => "create", "slug" => item.destination_slug},
      started_at: @now
    })
    |> Repo.insert!()
  end

  defp saved_account!(actor, identity, pat) do
    {:ok, view} =
      ForgeImports.link_github_account(
        actor,
        pat,
        request_metadata("link-waits-account"),
        client: StubClient,
        test_pid: self(),
        response: {:ok, github_user(identity.github_user_id, identity.login)}
      )

    assert_receive {:authenticated_user, {:account_setup, actor_id}}
    assert actor_id == actor.id
    view
  end

  defp identity_fixture(actor, github_user_id, login) do
    {:ok, identity} =
      ForgeAccounts.observe_github_identity(
        %{
          github_user_id: github_user_id,
          login: login,
          avatar_url: nil,
          profile_url: "https://github.com/#{login}"
        },
        @now
      )

    {:ok, linked} = ForgeAccounts.link_github_identity(actor, identity)
    linked
  end

  defp github_user(id, login) do
    %GitHubUser{
      id: id,
      login: login,
      name: "GitHub User",
      avatar_url: "https://avatars.githubusercontent.com/u/#{id}",
      html_url: "https://github.com/#{login}"
    }
  end

  defp request_metadata(operation_id \\ nil) do
    metadata = %{
      "request_id" => "waits-test-#{System.unique_integer([:positive])}",
      "operation_id" => operation_id || "waits-operation-#{System.unique_integer([:positive])}",
      "user_agent" => "ExUnit"
    }

    metadata
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      username: "waits-#{suffix}",
      email: "waits-#{suffix}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, %Ecto.Changeset{} = changeset}) do
    raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
  end

  defp verification_reference(%GitHubCredential{} = credential) do
    identity = Repo.get!(GitHubIdentity, credential.github_identity_id)

    %ForgeAccounts.GitHubCredentialVerification{
      credential_id: credential.id,
      identity_id: identity.id,
      local_user_id: credential.local_user_id,
      verification_version: credential.verification_version,
      generation_digest: generation_digest(credential)
    }
  end

  defp generation_digest(%GitHubCredential{} = credential) do
    payload = [
      <<byte_size("fornacast.github-credential-generation.v1")::unsigned-16,
        "fornacast.github-credential-generation.v1">>,
      <<credential.id::unsigned-64, credential.local_user_id::unsigned-64,
        credential.github_identity_id::unsigned-64,
        credential.verification_version::unsigned-64>>,
      length_prefixed(credential.ciphertext || <<>>),
      length_prefixed(credential.nonce || <<>>),
      length_prefixed(credential.tag || <<>>),
      length_prefixed(credential.key_id || <<>>)
    ]

    :crypto.hash(:sha256, IO.iodata_to_binary(payload))
  end

  defp length_prefixed(value) when is_binary(value) do
    <<byte_size(value)::unsigned-16, value::binary>>
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "github_credentials",
          "github_identities",
          "audit_events",
          "repository_collaborators",
          "repositories",
          "organization_members",
          "organizations",
          "users"
        ] do
      Repo.query!("DELETE FROM #{table}")
    end
  end
end
