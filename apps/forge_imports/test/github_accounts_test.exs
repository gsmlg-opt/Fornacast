defmodule ForgeImports.GitHubAccountsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}
  alias ForgeImports.GitHub.Error
  alias ForgeImports.GitHub.User, as: GitHubUser
  alias ForgeImports.{ImportRun, RepositoryItem}
  alias Fornacast.{AuditEvent, OperationLease, Repo}

  @first_pat "github_pat_first_secret"
  @second_pat "github_pat_second_secret"
  @now ~U[2026-08-26 06:00:00Z]

  defmodule StubClient do
    def authenticated_user(_pat, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:authenticated_user, Keyword.fetch!(opts, :gate_key)}
      )

      Keyword.fetch!(opts, :response)
    end
  end

  defmodule LeakyClient do
    def authenticated_user(pat, _opts), do: raise("credential leaked: " <> pat)
  end

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    %{actor: user_fixture("alice")}
  end

  test "first link verifies with an actor-scoped non-secret gate before saving", %{actor: actor} do
    github_user = github_user(9_000_000_001, "octocat")

    assert {:ok, view} =
             ForgeImports.link_github_account(actor, @first_pat, request_metadata(),
               client: StubClient,
               test_pid: self(),
               response: {:ok, github_user}
             )

    assert view.github_user_id == github_user.id
    assert view.login == "octocat"
    assert view.display_name == "Github:octocat"
    assert view.credential_present
    assert_receive {:authenticated_user, {:account_setup, actor_id}}
    assert actor_id == actor.id

    assert [%{identity_id: identity_id, login: "octocat"}] =
             account_list!(actor)

    assert_saved_pat(actor, identity_id, @first_pat)
    refute inspect(view) =~ @first_pat

    audit = Repo.get_by!(AuditEvent, action: "github.account.linked")
    refute inspect(audit) =~ @first_pat
  end

  test "a local user links multiple accounts while collisions remain masked", %{actor: actor} do
    other = user_fixture("bob")

    assert {:ok, first} = link(actor, github_user(9_000_000_001, "zeta"), @first_pat)
    assert {:ok, second} = link(actor, github_user(9_000_000_002, "alpha"), @second_pat)
    assert first.identity_id != second.identity_id

    assert [%{login: "alpha"}, %{login: "zeta"}] = account_list!(actor)

    assert {:error, :already_linked} =
             link(other, github_user(9_000_000_001, "private-owner"), "github_pat_other")

    refute inspect({:error, :already_linked}) =~ actor.username
    assert account_list!(other) == []
  end

  test "replacement uses the selected credential ID as its gate and requires an exact GitHub ID",
       %{
         actor: actor
       } do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

    assert {:error, :identity_mismatch} =
             ForgeImports.replace_github_credential(
               actor,
               view.identity_id,
               @second_pat,
               request_metadata(),
               client: StubClient,
               test_pid: self(),
               response: {:ok, github_user(9_000_000_002, "other")}
             )

    assert_receive {:authenticated_user, {:saved_credential, credential_id}}
    assert credential_id == credential.id
    assert_saved_pat(actor, view.identity_id, @first_pat)

    assert {:error, :invalid_credential} =
             ForgeImports.replace_github_credential(
               actor,
               view.identity_id,
               @second_pat,
               request_metadata("replace-rejected-token"),
               client: StubClient,
               test_pid: self(),
               response: {:error, Error.new(:invalid_credential)}
             )

    assert_receive {:authenticated_user, {:saved_credential, ^credential_id}}
    assert Repo.get!(GitHubCredential, credential.id).status == :valid
    assert_saved_pat(actor, view.identity_id, @first_pat)

    assert {:ok, replaced} =
             ForgeImports.replace_github_credential(
               actor,
               view.identity_id,
               @second_pat,
               request_metadata("replace-credential"),
               client: StubClient,
               test_pid: self(),
               response: {:ok, github_user(9_000_000_001, "octocat-renamed")}
             )

    assert replaced.identity_id == view.identity_id
    assert replaced.login == "octocat-renamed"
    assert_receive {:authenticated_user, {:saved_credential, ^credential_id}}
    assert_saved_pat(actor, view.identity_id, @second_pat)
  end

  test "link and replacement reject another account's stored PAT before provider access",
       %{actor: actor} do
    other_pat = "totally-secret-secondary-credential"
    new_pat = "totally-secret-new-token"
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)

    other =
      saved_account!(actor, github_user(9_000_000_002, "other-account"), other_pat)

    before = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    before_other = Repo.get_by!(GitHubCredential, github_identity_id: other.identity_id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    calls = [
      fn metadata ->
        ForgeImports.link_github_account(actor, new_pat, metadata,
          client: StubClient,
          test_pid: self(),
          response: {:ok, github_user(9_000_000_001, "must-not-link")}
        )
      end,
      fn metadata ->
        ForgeImports.replace_github_credential(actor, view.identity_id, new_pat, metadata,
          client: StubClient,
          test_pid: self(),
          response: {:ok, github_user(9_000_000_001, "must-not-replace")}
        )
      end
    ]

    for call <- calls, field <- [:request_id, :operation_id, :user_agent] do
      log =
        capture_log(fn ->
          assert {:error, :invalid_request_metadata} = call.(%{field => other_pat})
        end)

      refute_received {:authenticated_user, _gate_key}
      refute log =~ other_pat
      assert Repo.get!(GitHubCredential, before.id) == before
      assert Repo.get!(GitHubCredential, before_other.id) == before_other
      assert Repo.get!(GitHubIdentity, view.identity_id).login == "octocat"
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "link replacement and reverification reject another account PAT in provider profiles",
       %{actor: actor} do
    other_pat = "totally-secret-other-provider-profile-token"
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)

    other =
      saved_account!(actor, github_user(9_000_000_002, "other-account"), other_pat)

    before_identity = Repo.get!(GitHubIdentity, view.identity_id)
    before_credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    before_other = Repo.get_by!(GitHubCredential, github_identity_id: other.identity_id)
    identity_count = Repo.aggregate(GitHubIdentity, :count, :id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    unsafe_avatar =
      github_user(view.github_user_id, "safe-avatar-login")
      |> Map.put(
        :avatar_url,
        "https://avatars.githubusercontent.com/u/#{view.github_user_id}/#{other_pat}"
      )

    unsafe_profile_url =
      github_user(view.github_user_id, "safe-profile-login")
      |> Map.put(:html_url, "https://github.com/safe-profile-login/#{other_pat}")

    unsafe_name =
      github_user(view.github_user_id, "safe-name-login")
      |> Map.put(:name, other_pat)

    calls = [
      fn ->
        ForgeImports.link_github_account(actor, @second_pat, request_metadata("unsafe-link"),
          client: StubClient,
          test_pid: self(),
          response: {:ok, github_user(9_000_000_003, other_pat)}
        )
      end,
      fn ->
        ForgeImports.replace_github_credential(
          actor,
          view.identity_id,
          @second_pat,
          request_metadata("unsafe-replace"),
          client: StubClient,
          test_pid: self(),
          response: {:ok, unsafe_avatar}
        )
      end,
      fn ->
        ForgeImports.reverify_github_account(
          actor,
          view.identity_id,
          request_metadata("unsafe-reverify-url"),
          client: StubClient,
          test_pid: self(),
          response: {:ok, unsafe_profile_url}
        )
      end,
      fn ->
        ForgeImports.reverify_github_account(
          actor,
          view.identity_id,
          request_metadata("unsafe-reverify-name"),
          client: StubClient,
          test_pid: self(),
          response: {:ok, unsafe_name}
        )
      end
    ]

    for call <- calls do
      log =
        capture_log(fn ->
          assert {:error, :invalid_response} = call.()
        end)

      refute log =~ other_pat
      assert Repo.get!(GitHubIdentity, view.identity_id) == before_identity
      assert Repo.get!(GitHubCredential, before_credential.id) == before_credential
      assert Repo.get!(GitHubCredential, before_other.id) == before_other
      assert Repo.aggregate(GitHubIdentity, :count, :id) == identity_count
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "coordinator profile mutations reject substantial substrings of another account PAT",
       %{actor: actor} do
    other_pat = "totally-secret-token"
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    other = saved_account!(actor, github_user(9_000_000_002, "secondary-account"), other_pat)

    before_identity = Repo.get!(GitHubIdentity, view.identity_id)
    before_credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    before_other = Repo.get_by!(GitHubCredential, github_identity_id: other.identity_id)
    identity_count = Repo.aggregate(GitHubIdentity, :count, :id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    unsafe_name =
      github_user(view.github_user_id, "safe-name-login")
      |> Map.put(:name, "secret-token")

    unsafe_profile_url =
      github_user(view.github_user_id, "safe-profile-login")
      |> Map.put(:html_url, "https://github.com/safe-profile-login/secret-token")

    calls = [
      fn ->
        ForgeImports.link_github_account(
          actor,
          @second_pat,
          request_metadata("unsafe-substring-link"),
          client: StubClient,
          test_pid: self(),
          response: {:ok, github_user(9_000_000_003, "secret-token")}
        )
      end,
      fn ->
        ForgeImports.replace_github_credential(
          actor,
          view.identity_id,
          @second_pat,
          request_metadata("unsafe-substring-replace"),
          client: StubClient,
          test_pid: self(),
          response: {:ok, unsafe_name}
        )
      end,
      fn ->
        ForgeImports.reverify_github_account(
          actor,
          view.identity_id,
          request_metadata("unsafe-substring-reverify"),
          client: StubClient,
          test_pid: self(),
          response: {:ok, unsafe_profile_url}
        )
      end
    ]

    for call <- calls do
      log =
        capture_log(fn ->
          assert {:error, :invalid_response} = call.()
        end)

      refute log =~ other_pat
      assert Repo.get!(GitHubIdentity, view.identity_id) == before_identity
      assert Repo.get!(GitHubCredential, before_credential.id) == before_credential
      assert Repo.get!(GitHubCredential, before_other.id) == before_other
      assert Repo.aggregate(GitHubIdentity, :count, :id) == identity_count
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "a corrupt credential on another account suppresses every coordinator mutation", %{
    actor: actor
  } do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)

    other =
      saved_account!(
        actor,
        github_user(9_000_000_002, "other-account"),
        "totally-secret-corrupt-credential"
      )

    before = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    other_credential = Repo.get_by!(GitHubCredential, github_identity_id: other.identity_id)

    other_credential
    |> Ecto.Changeset.change(key_id: "missing-old-key")
    |> Repo.update!()

    corrupt_other = Repo.get!(GitHubCredential, other_credential.id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    provider_opts = [
      client: StubClient,
      test_pid: self(),
      response: {:ok, github_user(view.github_user_id, "must-not-mutate")}
    ]

    calls = [
      fn -> ForgeImports.link_github_account(actor, @second_pat, %{}, provider_opts) end,
      fn ->
        ForgeImports.replace_github_credential(
          actor,
          view.identity_id,
          @second_pat,
          %{},
          provider_opts
        )
      end,
      fn ->
        ForgeImports.reverify_github_account(actor, view.identity_id, %{}, provider_opts)
      end,
      fn -> ForgeImports.delete_github_credential(actor, view.identity_id, %{}) end,
      fn -> ForgeImports.unlink_github_account(actor, view.identity_id, %{}) end
    ]

    for call <- calls do
      assert {:error, :credential_service_unavailable} = call.()
      refute_received {:authenticated_user, _gate_key}
      assert Repo.get!(GitHubCredential, before.id) == before
      assert Repo.get!(GitHubCredential, other_credential.id) == corrupt_other
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end

    assert {:ok, [_first, _second]} = ForgeImports.list_github_accounts(actor)
  end

  test "an unlinked actor-owned credential suppresses provider access", %{actor: actor} do
    orphan_pat = "totally-secret-orphaned-credential-token"

    view =
      saved_account!(actor, github_user(9_000_000_001, "octocat"), orphan_pat)

    identity = Repo.get!(GitHubIdentity, view.identity_id)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    assert {:ok, _unlinked} = ForgeAccounts.unlink_github_identity(actor, identity)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    log =
      capture_log(fn ->
        assert {:error, :credential_service_unavailable} =
                 ForgeImports.link_github_account(
                   actor,
                   @second_pat,
                   %{operation_id: orphan_pat},
                   client: StubClient,
                   test_pid: self(),
                   response: {:ok, github_user(9_000_000_002, "must-not-link")}
                 )
      end)

    refute_received {:authenticated_user, _gate_key}
    refute log =~ orphan_pat
    assert Repo.get!(GitHubCredential, credential.id) == credential
    refute Repo.get_by(GitHubIdentity, github_user_id: 9_000_000_002)
    assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    assert {:ok, []} = ForgeImports.list_github_accounts(actor)
  end

  test "reverification checks out the PAT only to the client and preserves its envelope", %{
    actor: actor
  } do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    before = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

    assert {:ok, refreshed} =
             ForgeImports.reverify_github_account(
               actor,
               view.identity_id,
               request_metadata("reverify-account"),
               client: StubClient,
               test_pid: self(),
               response: {:ok, github_user(9_000_000_001, "octocat-current")}
             )

    assert refreshed.login == "octocat-current"
    assert_receive {:authenticated_user, {:saved_credential, credential_id}}
    assert credential_id == before.id

    after_refresh = Repo.get!(GitHubCredential, before.id)
    assert after_refresh.status == :valid
    assert after_refresh.ciphertext == before.ciphertext
    assert after_refresh.nonce == before.nonce
    assert after_refresh.tag == before.tag
    assert after_refresh.key_id == before.key_id
  end

  test "an invalid saved token is CAS-invalidated and audited without rewriting import plans", %{
    actor: actor
  } do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    {:ok, run} = saved_run(actor, view, credential)
    {:ok, item} = ForgeImports.create_repository_item(actor, run, item_attrs())

    assert {:error, :invalid_credential} =
             ForgeImports.reverify_github_account(
               actor,
               view.identity_id,
               request_metadata("invalidate-account"),
               client: StubClient,
               test_pid: self(),
               response: {:error, Error.new(:invalid_credential)}
             )

    assert_receive {:authenticated_user, {:saved_credential, credential_id}}
    assert credential_id == credential.id
    assert Repo.get!(GitHubCredential, credential.id).status == :invalid

    assert %ImportRun{
             state: :discovering,
             resume_state: nil,
             wait_reason: nil,
             github_credential_id: ^credential_id,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(ImportRun, run.id)

    assert %RepositoryItem{
             state: :queued,
             resume_state: nil,
             wait_reason: nil,
             lease_owner: nil,
             lease_expires_at: nil
           } = Repo.get!(RepositoryItem, item.id)

    assert %AuditEvent{metadata: metadata} =
             Repo.get_by!(AuditEvent, action: "github.credential.invalidated")

    refute inspect(metadata) =~ @first_pat
  end

  test "typed GitHub failures map to stable atoms without persistence", %{actor: actor} do
    kinds = [
      :invalid_request,
      :invalid_credential,
      :forbidden,
      :not_found,
      :primary_rate_limit,
      :secondary_rate_limit,
      :upstream_unavailable,
      :unexpected_status,
      :transport,
      :timeout,
      :host_unavailable,
      :unsafe_host,
      :response_too_large,
      :invalid_json,
      :invalid_response,
      :invalid_pagination,
      :pagination_limit,
      :request_gate_busy
    ]

    for {kind, index} <- Enum.with_index(kinds, 1) do
      assert {:error, ^kind} =
               ForgeImports.link_github_account(
                 actor,
                 "github_pat_#{index}",
                 request_metadata("typed-error-#{index}"),
                 client: StubClient,
                 test_pid: self(),
                 response: {:error, Error.new(kind)}
               )

      assert_receive {:authenticated_user, {:account_setup, actor_id}}
      assert actor_id == actor.id
    end

    assert Repo.aggregate(GitHubCredential, :count, :id) == 0
    assert Repo.aggregate(GitHubIdentity, :count, :id) == 0
  end

  test "malformed and credential-bearing client results collapse to invalid response", %{
    actor: actor
  } do
    malicious_user = github_user(9_000_000_001, @first_pat)

    results = [
      @first_pat,
      {:ok, @first_pat},
      {:ok, malicious_user},
      {:error,
       %Error{
         kind: :unknown_kind,
         retry_at: nil,
         detail: "Bearer " <> @first_pat
       }}
    ]

    for {result, index} <- Enum.with_index(results, 1) do
      assert {:error, :invalid_response} =
               ForgeImports.link_github_account(
                 actor,
                 @first_pat,
                 request_metadata("malicious-client-#{index}"),
                 client: StubClient,
                 test_pid: self(),
                 response: result
               )

      assert_receive {:authenticated_user, {:account_setup, actor_id}}
      assert actor_id == actor.id
    end

    assert Repo.aggregate(GitHubCredential, :count, :id) == 0
    assert Repo.aggregate(GitHubIdentity, :count, :id) == 0
  end

  test "sensitive request metadata is rejected before provider access or persistence", %{
    actor: actor
  } do
    values = [
      {:request_id, "github_pat_metadata_secret"},
      {:operation_id, "ghp_metadata_secret"},
      {:user_agent, "Bearer metadata-secret"},
      {:request_id, "request\0id"},
      {:user_agent, "/absolute/private/path"}
    ]

    for {field, value} <- values do
      metadata = request_metadata() |> Map.put(field, value)

      assert {:error, :invalid_request_metadata} =
               ForgeImports.link_github_account(actor, @first_pat, metadata,
                 client: StubClient,
                 test_pid: self(),
                 response: {:ok, github_user(9_000_000_001, "octocat")}
               )

      refute_received {:authenticated_user, _gate_key}
    end

    assert Repo.aggregate(GitHubCredential, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "an exact submitted PAT in metadata is rejected before any query or provider call", %{
    actor: actor
  } do
    pat = "totally-secret-token"
    telemetry_id = attach_query_probe()

    log =
      capture_log(fn ->
        assert {:error, :invalid_request_metadata} =
                 ForgeImports.link_github_account(
                   actor,
                   pat,
                   %{request_id: pat},
                   client: StubClient,
                   test_pid: self(),
                   response: {:ok, github_user(9_000_000_001, "octocat")}
                 )
      end)

    :telemetry.detach(telemetry_id)
    refute_received :github_account_query
    refute_received {:authenticated_user, _gate_key}
    refute log =~ pat
    assert Repo.aggregate(GitHubCredential, :count, :id) == 0
    assert Repo.aggregate(GitHubIdentity, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "reverification compares metadata with the checked-out PAT before provider access", %{
    actor: actor
  } do
    pat = "totally-secret-token"
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), pat)
    before = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    log =
      capture_log(fn ->
        assert {:error, :invalid_request_metadata} =
                 ForgeImports.reverify_github_account(
                   actor,
                   view.identity_id,
                   %{request_id: pat},
                   client: StubClient,
                   test_pid: self(),
                   response: {:ok, github_user(9_000_000_001, "must-not-persist")}
                 )
      end)

    refute_received {:authenticated_user, _gate_key}
    refute log =~ pat
    assert Repo.get!(GitHubCredential, before.id) == before
    assert Repo.get!(GitHubIdentity, view.identity_id).login == "octocat"
    assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
  end

  test "ambiguous and structured accepted metadata fields fail closed", %{actor: actor} do
    for metadata <- [
          %{"request_id" => "safe-two", request_id: "safe-one"},
          %{request_id: %{nested: "safe"}},
          %{ip_address: {127, 0, 0, 1}}
        ] do
      assert {:error, :invalid_request_metadata} =
               ForgeImports.link_github_account(actor, @first_pat, metadata,
                 client: StubClient,
                 test_pid: self(),
                 response: {:ok, github_user(9_000_000_001, "octocat")}
               )

      refute_received {:authenticated_user, _gate_key}
    end
  end

  test "credential deletion is blocked while an active import still references it", %{
    actor: actor
  } do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    {:ok, run} = saved_run(actor, view, credential)
    {:ok, item} = ForgeImports.create_repository_item(actor, run, item_attrs())

    assert {:error, :credential_in_use} =
             ForgeImports.delete_github_credential(
               actor,
               view.identity_id,
               request_metadata("delete-active-credential")
             )

    assert Repo.get!(GitHubCredential, credential.id)
    assert Repo.get!(ImportRun, run.id).state == :discovering
    assert Repo.get!(RepositoryItem, item.id).state == :queued
    assert Repo.get!(GitHubIdentity, view.identity_id).local_user_id == actor.id
    refute Repo.get_by(AuditEvent, operation_id: "delete-active-credential")

    assert {:error, :credential_in_use} =
             ForgeImports.unlink_github_account(
               actor,
               view.identity_id,
               request_metadata("unlink-active-credential")
             )

    assert Repo.get!(GitHubCredential, credential.id)
    assert Repo.get!(GitHubIdentity, view.identity_id).local_user_id == actor.id
    refute Repo.get_by(AuditEvent, operation_id: "unlink-active-credential")
  end

  test "out-of-band account deletion normalizes an active import constraint", %{actor: actor} do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    {:ok, run} = saved_run(actor, view, credential)

    assert {:error, :credential_in_use} =
             ForgeAccounts.delete_github_credential(
               actor,
               view.identity_id,
               request_metadata("out-of-band-delete")
             )

    assert Repo.get!(GitHubCredential, credential.id)
    assert Repo.get!(ImportRun, run.id).github_credential_id == credential.id
    assert Repo.get!(GitHubIdentity, view.identity_id).local_user_id == actor.id
    refute Repo.get_by(AuditEvent, operation_id: "out-of-band-delete")
  end

  test "credential deletion nilifies terminal and already-waiting history", %{actor: actor} do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

    {:ok, waiting} =
      with {:ok, created} <- saved_run(actor, view, credential),
           {:ok, review} <- ForgeImports.transition_run(actor, created, :awaiting_resolution),
           do:
             ForgeImports.transition_run(actor, review, :awaiting_credential, %{
               wait_reason: "credential_invalid"
             })

    {:ok, terminal} =
      with {:ok, created} <- saved_run(actor, view, credential, 9_000_000_099),
           do: ForgeImports.transition_run(actor, created, :failed, %{terminal_at: @now})

    assert {:ok, deleted} =
             ForgeImports.delete_github_credential(
               actor,
               view.identity_id,
               request_metadata("delete-credential")
             )

    refute deleted.credential_present
    assert Repo.get!(GitHubIdentity, view.identity_id).local_user_id == actor.id
    refute Repo.get(GitHubCredential, credential.id)

    assert %ImportRun{
             state: :awaiting_credential,
             resume_state: :awaiting_resolution,
             wait_reason: "credential_invalid",
             github_credential_id: nil
           } = Repo.get!(ImportRun, waiting.id)

    assert %ImportRun{state: :failed, github_credential_id: nil} =
             Repo.get!(ImportRun, terminal.id)
  end

  test "unlink nilifies already-waiting work and clears only the local identity link", %{
    actor: actor
  } do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

    {:ok, waiting} =
      with {:ok, created} <- saved_run(actor, view, credential),
           {:ok, review} <- ForgeImports.transition_run(actor, created, :awaiting_resolution),
           do: ForgeImports.transition_run(actor, review, :awaiting_credential)

    assert {:ok, unlinked} =
             ForgeImports.unlink_github_account(
               actor,
               view.identity_id,
               request_metadata("unlink-account")
             )

    refute unlinked.credential_present
    assert Repo.get!(GitHubIdentity, view.identity_id).local_user_id == nil
    refute Repo.get(GitHubCredential, credential.id)

    assert %ImportRun{
             state: :awaiting_credential,
             resume_state: :awaiting_resolution,
             github_credential_id: nil
           } = Repo.get!(ImportRun, waiting.id)
  end

  test "active run or item leases make credential deletion busy and roll back", %{actor: actor} do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    {:ok, run} = saved_run(actor, view, credential)
    {:ok, item} = ForgeImports.create_repository_item(actor, run, item_attrs())

    now = DateTime.utc_now(:second)
    assert {:ok, claimed_run} = OperationLease.claim(ImportRun, run.id, "run-worker", now, 60)

    assert {:error, :busy} =
             ForgeImports.delete_github_credential(actor, view.identity_id, request_metadata())

    assert Repo.get!(ImportRun, run.id).state == :discovering
    assert Repo.get!(GitHubCredential, credential.id)
    assert :ok = OperationLease.release(ImportRun, claimed_run)

    current_run = Repo.reload!(run)
    {:ok, review} = ForgeImports.transition_run(actor, current_run, :awaiting_resolution)

    {:ok, _waiting} = ForgeImports.transition_run(actor, review, :awaiting_credential)

    current_item = Repo.get!(RepositoryItem, item.id)

    assert {:ok, claimed_item} =
             OperationLease.claim(RepositoryItem, current_item.id, "item-worker", now, 60)

    assert {:error, :busy} =
             ForgeImports.delete_github_credential(actor, view.identity_id, request_metadata())

    assert Repo.get!(ImportRun, run.id).state == :awaiting_credential
    assert Repo.get!(RepositoryItem, item.id).state == :queued
    assert Repo.get!(GitHubCredential, credential.id)
    assert :ok = OperationLease.release(RepositoryItem, claimed_item)
  end

  test "expired leases do not prevent deletion of already-waiting work", %{actor: actor} do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    {:ok, run} = saved_run(actor, view, credential)
    {:ok, item} = ForgeImports.create_repository_item(actor, run, item_attrs())
    {:ok, review} = ForgeImports.transition_run(actor, run, :awaiting_resolution)
    {:ok, waiting} = ForgeImports.transition_run(actor, review, :awaiting_credential)
    old = DateTime.add(DateTime.utc_now(:second), -120, :second)

    assert {:ok, _claimed_run} = OperationLease.claim(ImportRun, waiting.id, "old-run", old, 30)

    assert {:ok, _claimed_item} =
             OperationLease.claim(RepositoryItem, item.id, "old-item", old, 30)

    assert {:ok, _deleted} =
             ForgeImports.delete_github_credential(actor, view.identity_id, request_metadata())

    assert Repo.get!(ImportRun, run.id).state == :awaiting_credential
    assert Repo.get!(ImportRun, run.id).github_credential_id == nil
    assert Repo.get!(RepositoryItem, item.id).state == :queued
  end

  test "account mutation failure rolls every wait transition back", %{actor: actor} do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    {:ok, run} = saved_run(actor, view, credential)
    {:ok, item} = ForgeImports.create_repository_item(actor, run, item_attrs())
    {:ok, review} = ForgeImports.transition_run(actor, run, :awaiting_resolution)
    {:ok, waiting} = ForgeImports.transition_run(actor, review, :awaiting_credential)

    metadata = %{operation_id: String.duplicate("x", 256)}

    assert {:error, :invalid_request_metadata} =
             ForgeImports.delete_github_credential(actor, view.identity_id, metadata)

    assert Repo.get!(ImportRun, waiting.id).state == :awaiting_credential
    assert Repo.get!(RepositoryItem, item.id).state == :queued
    assert Repo.get!(GitHubCredential, credential.id)
  end

  test "unlink works without a saved credential and delete remains not found", %{actor: actor} do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)

    assert {:ok, _} = ForgeAccounts.delete_github_credential(actor, view.identity_id, %{})

    assert {:error, :not_found} =
             ForgeImports.delete_github_credential(actor, view.identity_id, request_metadata())

    assert {:ok, unlinked} =
             ForgeImports.unlink_github_account(actor, view.identity_id, request_metadata())

    refute unlinked.credential_present
    assert Repo.get!(GitHubIdentity, view.identity_id).local_user_id == nil
  end

  test "delete and unlink reject exact stored-PAT request metadata without leakage", %{
    actor: actor
  } do
    pat = "totally-secret-token"
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), pat)
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    calls = [
      fn metadata ->
        ForgeImports.delete_github_credential(actor, view.identity_id, metadata)
      end,
      fn metadata -> ForgeImports.unlink_github_account(actor, view.identity_id, metadata) end
    ]

    for call <- calls, field <- [:request_id, :operation_id, :user_agent] do
      log =
        capture_log(fn ->
          assert {:error, :invalid_request_metadata} = call.(%{field => pat})
        end)

      refute log =~ pat
      assert Repo.get!(GitHubCredential, credential.id) == credential
      assert Repo.get!(GitHubIdentity, view.identity_id).local_user_id == actor.id
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "a disabled local actor is rejected before the GitHub client sees the PAT", %{actor: actor} do
    assert {:ok, _disabled} =
             actor
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :forbidden} =
             ForgeImports.link_github_account(actor, @first_pat, request_metadata(),
               client: StubClient,
               test_pid: self(),
               response: {:ok, github_user(9_000_000_001, "octocat")}
             )

    refute_received {:authenticated_user, _gate_key}
    assert Repo.aggregate(GitHubCredential, :count, :id) == 0
  end

  test "credential-bearing client exceptions are sanitized in messages, inspect, and logs", %{
    actor: actor
  } do
    {error, stacktrace} =
      try do
        ForgeImports.link_github_account(actor, @first_pat, request_metadata(),
          client: LeakyClient
        )

        flunk("leaky client did not raise")
      rescue
        error -> {error, __STACKTRACE__}
      end

    assert error.__struct__ == ForgeImports.GitHubAccounts.CredentialVerificationError
    formatted = Exception.format(:error, error, stacktrace)
    logged = capture_log(fn -> Logger.error(formatted) end)

    for rendered <- [Exception.message(error), inspect(error), formatted, logged] do
      refute rendered =~ @first_pat
    end

    assert Repo.aggregate(GitHubCredential, :count, :id) == 0
  end

  test "coordinator mutations fail closed before provider access when the vault is missing or unavailable",
       %{actor: actor} do
    view = saved_account!(actor, github_user(9_000_000_001, "octocat"), @first_pat)

    credentialless =
      saved_account!(actor, github_user(9_000_000_002, "credentialless"), @second_pat)

    assert {:ok, _without_credential} =
             ForgeAccounts.delete_github_credential(actor, credentialless.identity_id, %{})

    before = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)
    original = Application.fetch_env(:fornacast, :github_credential_keyring)
    on_exit(fn -> restore_keyring(original) end)

    provider_opts = [
      client: StubClient,
      test_pid: self(),
      response: {:ok, github_user(9_000_000_001, "blocked")}
    ]

    calls = [
      fn -> ForgeImports.link_github_account(actor, @second_pat, %{}, provider_opts) end,
      fn ->
        ForgeImports.replace_github_credential(
          actor,
          view.identity_id,
          @second_pat,
          %{},
          provider_opts
        )
      end,
      fn -> ForgeImports.reverify_github_account(actor, view.identity_id, %{}, provider_opts) end,
      fn -> ForgeImports.delete_github_credential(actor, view.identity_id, %{}) end,
      fn -> ForgeImports.unlink_github_account(actor, view.identity_id, %{}) end,
      fn -> ForgeImports.unlink_github_account(actor, credentialless.identity_id, %{}) end
    ]

    for configured <- [:unavailable, :missing] do
      configure_keyring(configured)

      for call <- calls do
        assert {:error, :credential_service_unavailable} = call.()
        refute_received {:authenticated_user, _gate_key}
        assert Repo.get!(GitHubCredential, before.id) == before
        assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
      end

      assert {:ok, [_first, _second]} = ForgeImports.list_github_accounts(actor)

      empty_actor = user_fixture("empty-#{configured}")

      assert {:error, :credential_service_unavailable} =
               ForgeImports.link_github_account(empty_actor, @second_pat, %{}, provider_opts)

      refute_received {:authenticated_user, _gate_key}
    end
  end

  defp link(actor, github_user, pat) do
    ForgeImports.link_github_account(actor, pat, request_metadata(),
      client: StubClient,
      test_pid: self(),
      response: {:ok, github_user}
    )
  end

  defp saved_account!(actor, %GitHubUser{} = github_user, pat) do
    {:ok, view} =
      ForgeAccounts.save_github_account(actor, verified_profile(github_user), pat, %{})

    view
  end

  defp saved_run(actor, view, credential, owner_id \\ 9_100_000_001) do
    ForgeImports.create_run(actor, %{
      source_kind: :organization,
      github_identity_id: view.identity_id,
      credential_source: :saved,
      github_credential_id: credential.id,
      source_owner_github_id: owner_id,
      source_owner_login: "source-owner",
      request_metadata: %{}
    })
  end

  defp item_attrs do
    %{
      github_repository_id: System.unique_integer([:positive]) + 9_200_000_000,
      source_full_name: "source-owner/repository",
      source_name: "repository",
      source_metadata: %{},
      source_observed_at: @now
    }
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

  defp verified_profile(%GitHubUser{} = user) do
    %{
      github_user_id: user.id,
      login: user.login,
      avatar_url: user.avatar_url,
      profile_url: user.html_url
    }
  end

  defp request_metadata(operation_id \\ nil) do
    metadata = %{request_id: "github-account-request", user_agent: "ExUnit"}
    if operation_id, do: Map.put(metadata, :operation_id, operation_id), else: metadata
  end

  defp configure_keyring(:unavailable) do
    Application.put_env(:fornacast, :github_credential_keyring, :unavailable)
  end

  defp configure_keyring(:missing) do
    Application.delete_env(:fornacast, :github_credential_keyring)
  end

  defp restore_keyring({:ok, keyring}) do
    Application.put_env(:fornacast, :github_credential_keyring, keyring)
  end

  defp restore_keyring(:error) do
    Application.delete_env(:fornacast, :github_credential_keyring)
  end

  defp account_list!(actor) do
    {:ok, accounts} = ForgeImports.list_github_accounts(actor)
    accounts
  end

  defp assert_saved_pat(actor, identity_id, expected) do
    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential(actor, identity_id, fn actual ->
               assert actual == expected
               :ok
             end)
  end

  defp attach_query_probe do
    telemetry_id = {__MODULE__, make_ref()}
    owner = self()
    prefix = Keyword.get(Repo.config(), :telemetry_prefix, [:fornacast, :repo])

    :ok =
      :telemetry.attach(
        telemetry_id,
        prefix ++ [:query],
        fn _event, _measurements, _metadata, _config -> send(owner, :github_account_query) end,
        nil
      )

    telemetry_id
  end

  defp user_fixture(username) do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "#{username}-#{suffix}",
        email: "#{username}-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
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
          "api_keys",
          "ssh_keys",
          "users"
        ] do
      Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
    end
  end

  defp postgres? do
    Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]
  end
end
