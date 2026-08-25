defmodule ForgeAccounts.GitHubAccountCoordinationTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{GitHubCredential, GitHubCredentialVault, GitHubIdentity}
  alias Fornacast.{AuditEvent, Repo}

  @pat "github_pat_coordination_secret"

  setup do
    if postgres?() do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    else
      reset_database!()
      on_exit(&reset_database!/0)
    end

    actor = user_fixture("alice")

    {:ok, account} =
      ForgeAccounts.save_github_account(
        actor,
        profile(9_000_000_001, "octocat"),
        @pat,
        %{}
      )

    credential = Repo.get_by!(GitHubCredential, github_identity_id: account.identity_id)
    %{actor: actor, account: account, credential: credential}
  end

  test "the safe account reference contains the exact credential ID and no envelope", context do
    assert {:ok, reference} =
             ForgeAccounts.github_account_reference(context.actor, context.account.identity_id)

    assert reference.identity_id == context.account.identity_id
    assert reference.github_user_id == context.account.github_user_id
    assert reference.credential.credential_id == context.credential.id
    assert reference.credential.identity_id == context.account.identity_id
    assert reference.credential.verification_version == context.credential.verification_version
    assert byte_size(reference.credential.generation_digest) == 32

    refute inspect(reference) =~ @pat
    refute Map.has_key?(reference, :ciphertext)

    for field <- [:ciphertext, :nonce, :tag, :key_id] do
      refute Map.has_key?(reference.credential, field)
    end

    refute inspect(reference.credential) =~ Base.encode16(reference.credential.generation_digest)

    other = user_fixture("bob")

    assert {:error, :not_found} =
             ForgeAccounts.github_account_reference(other, context.account.identity_id)
  end

  test "direct lifecycle APIs reject sensitive request metadata without mutation", context do
    before = Repo.get!(GitHubCredential, context.credential.id)

    values = [
      %{request_id: "github_pat_direct_secret"},
      %{operation_id: "ghp_direct_secret"},
      %{user_agent: "Bearer direct-secret"},
      %{request_id: "request\0id"},
      %{user_agent: "/absolute/private/path"}
    ]

    for metadata <- values do
      assert {:error, :invalid_request_metadata} =
               ForgeAccounts.replace_github_credential(
                 context.actor,
                 context.account.identity_id,
                 profile(9_000_000_001, "must-not-persist"),
                 "github_pat_replacement",
                 metadata
               )
    end

    assert Repo.get!(GitHubCredential, context.credential.id) == before
    refute Repo.get_by(AuditEvent, action: "github.credential.replaced")
  end

  test "direct save and replacement reject an exact PAT before database access", context do
    pat = "totally-secret-token"
    before = Repo.get!(GitHubCredential, context.credential.id)
    identity_count = Repo.aggregate(ForgeAccounts.GitHubIdentity, :count, :id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    query_probe = attach_query_probe()

    assert {:error, :invalid_request_metadata} =
             ForgeAccounts.save_github_account(
               context.actor,
               profile(9_000_000_002, "must-not-link"),
               pat,
               %{request_id: pat}
             )

    refute_received :github_account_query

    assert {:error, :invalid_request_metadata} =
             ForgeAccounts.replace_github_credential(
               context.actor,
               context.account.identity_id,
               profile(9_000_000_001, "must-not-replace"),
               pat,
               %{request_id: pat}
             )

    refute_received :github_account_query
    :telemetry.detach(query_probe)

    assert Repo.get!(GitHubCredential, context.credential.id) == before
    assert Repo.aggregate(ForgeAccounts.GitHubIdentity, :count, :id) == identity_count
    assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
  end

  test "direct save and replacement reject metadata matching the old stored PAT", context do
    old_pat = "totally-secret-old-token"
    new_pat = "totally-secret-new-token"

    assert {:ok, _updated} =
             ForgeAccounts.replace_github_credential(
               context.actor,
               context.account.identity_id,
               profile(context.account.github_user_id, "octocat"),
               old_pat,
               %{operation_id: "seed-old-stored-token"}
             )

    reference = verification_reference(context.actor, context.account.identity_id)
    before = Repo.get!(GitHubCredential, context.credential.id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    calls = [
      fn metadata ->
        ForgeAccounts.save_github_account(
          context.actor,
          profile(context.account.github_user_id, "must-not-save"),
          new_pat,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.replace_github_credential(
          context.actor,
          context.account.identity_id,
          profile(context.account.github_user_id, "must-not-replace"),
          new_pat,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.replace_github_credential_if_current(
          context.actor,
          context.account.identity_id,
          reference,
          profile(context.account.github_user_id, "must-not-replace"),
          new_pat,
          metadata
        )
      end
    ]

    for call <- calls, field <- [:request_id, :operation_id, :user_agent] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_request_metadata} = call.(%{field => old_pat})
        end)

      refute log =~ old_pat
      assert Repo.get!(GitHubCredential, context.credential.id) == before
      assert Repo.get!(GitHubIdentity, context.account.identity_id).login == "octocat"
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "every direct mutation rejects another linked account's stored PAT", context do
    other_pat = "totally-secret-secondary-credential"
    replacement_pat = "totally-secret-replacement-token"

    assert {:ok, other_account} =
             ForgeAccounts.save_github_account(
               context.actor,
               profile(9_000_000_002, "other-account"),
               other_pat,
               %{operation_id: "seed-other-account-token"}
             )

    reference = verification_reference(context.actor, context.account.identity_id)
    before_credential = Repo.get!(GitHubCredential, context.credential.id)
    before_other = Repo.get_by!(GitHubCredential, github_identity_id: other_account.identity_id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    for call <-
          direct_mutation_calls(
            context.actor,
            context.account,
            reference,
            replacement_pat
          ),
        field <- [:request_id, :operation_id, :user_agent] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_request_metadata} = call.(%{field => other_pat})
        end)

      refute log =~ other_pat
      assert Repo.get!(GitHubCredential, context.credential.id) == before_credential
      assert Repo.get!(GitHubCredential, before_other.id) == before_other
      assert Repo.get!(GitHubIdentity, context.account.identity_id).login == "octocat"
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "every direct profile mutation rejects all actor-owned and submitted PATs", context do
    other_pat = "totally-secret-other-profile-token"
    submitted_pat = "totally-secret-submitted-profile-token"

    assert {:ok, other_account} =
             ForgeAccounts.save_github_account(
               context.actor,
               profile(9_000_000_002, "other-profile-account"),
               other_pat,
               %{operation_id: "seed-other-profile-token"}
             )

    reference = verification_reference(context.actor, context.account.identity_id)
    before_identity = Repo.get!(GitHubIdentity, context.account.identity_id)
    before_credential = Repo.get!(GitHubCredential, context.credential.id)
    before_other = Repo.get_by!(GitHubCredential, github_identity_id: other_account.identity_id)
    identity_count = Repo.aggregate(GitHubIdentity, :count, :id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    calls = [
      fn ->
        ForgeAccounts.save_github_account(
          context.actor,
          unsafe_profile(9_000_000_003, :login, other_pat),
          submitted_pat,
          %{}
        )
      end,
      fn ->
        ForgeAccounts.save_github_account_if_absent(
          context.actor,
          unsafe_profile(9_000_000_004, :avatar_url, other_pat),
          submitted_pat,
          %{}
        )
      end,
      fn ->
        ForgeAccounts.save_github_credential_if_absent(
          context.actor,
          context.account.identity_id,
          unsafe_profile(context.account.github_user_id, :profile_url, other_pat),
          submitted_pat,
          %{}
        )
      end,
      fn ->
        ForgeAccounts.replace_github_credential(
          context.actor,
          context.account.identity_id,
          unsafe_profile(context.account.github_user_id, :login, other_pat),
          submitted_pat,
          %{}
        )
      end,
      fn ->
        ForgeAccounts.replace_github_credential_if_current(
          context.actor,
          context.account.identity_id,
          reference,
          unsafe_profile(context.account.github_user_id, :avatar_url, other_pat),
          submitted_pat,
          %{}
        )
      end,
      fn ->
        ForgeAccounts.refresh_github_account(
          context.actor,
          context.account.identity_id,
          unsafe_profile(context.account.github_user_id, :profile_url, other_pat),
          %{}
        )
      end,
      fn ->
        ForgeAccounts.refresh_github_account_if_current(
          context.actor,
          context.account.identity_id,
          reference,
          Map.put(profile(context.account.github_user_id, "safe-name"), :name, other_pat),
          %{}
        )
      end,
      fn ->
        ForgeAccounts.save_github_account(
          context.actor,
          unsafe_profile(9_000_000_005, :login, submitted_pat),
          submitted_pat,
          %{}
        )
      end,
      fn ->
        ForgeAccounts.replace_github_credential(
          context.actor,
          context.account.identity_id,
          unsafe_profile(context.account.github_user_id, :profile_url, submitted_pat),
          submitted_pat,
          %{}
        )
      end
    ]

    for call <- calls do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_response} = call.()
        end)

      refute log =~ other_pat
      refute log =~ submitted_pat
      assert Repo.get!(GitHubIdentity, context.account.identity_id) == before_identity
      assert Repo.get!(GitHubCredential, context.credential.id) == before_credential
      assert Repo.get!(GitHubCredential, before_other.id) == before_other
      assert Repo.aggregate(GitHubIdentity, :count, :id) == identity_count
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "direct profile mutations reject substantial substrings of another account PAT", context do
    other_pat = "totally-secret-token"
    replacement_pat = "independent-replacement-credential"

    assert {:ok, other_account} =
             ForgeAccounts.save_github_account(
               context.actor,
               profile(9_000_000_002, "secondary-account"),
               other_pat,
               %{operation_id: "seed-substring-profile-token"}
             )

    reference = verification_reference(context.actor, context.account.identity_id)
    before_identity = Repo.get!(GitHubIdentity, context.account.identity_id)
    before_credential = Repo.get!(GitHubCredential, context.credential.id)
    before_other = Repo.get_by!(GitHubCredential, github_identity_id: other_account.identity_id)
    identity_count = Repo.aggregate(GitHubIdentity, :count, :id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    calls = [
      fn ->
        ForgeAccounts.save_github_account(
          context.actor,
          profile(9_000_000_003, "secret-token"),
          replacement_pat,
          %{}
        )
      end,
      fn ->
        ForgeAccounts.replace_github_credential_if_current(
          context.actor,
          context.account.identity_id,
          reference,
          Map.put(profile(context.account.github_user_id, "safe-login"), :name, "secret-token"),
          replacement_pat,
          %{}
        )
      end,
      fn ->
        ForgeAccounts.refresh_github_account(
          context.actor,
          context.account.identity_id,
          profile(context.account.github_user_id, "safe-login")
          |> Map.put(:profile_url, "https://github.com/safe-login/secret-token"),
          %{}
        )
      end
    ]

    for call <- calls do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_response} = call.()
        end)

      refute log =~ other_pat
      assert Repo.get!(GitHubIdentity, context.account.identity_id) == before_identity
      assert Repo.get!(GitHubCredential, context.credential.id) == before_credential
      assert Repo.get!(GitHubCredential, before_other.id) == before_other
      assert Repo.aggregate(GitHubIdentity, :count, :id) == identity_count
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "a corrupt credential on another account fails every mutation closed", context do
    assert {:ok, other_account} =
             ForgeAccounts.save_github_account(
               context.actor,
               profile(9_000_000_002, "other-account"),
               "totally-secret-corrupt-credential",
               %{operation_id: "seed-corrupt-other-account"}
             )

    reference = verification_reference(context.actor, context.account.identity_id)

    other_credential =
      Repo.get_by!(GitHubCredential, github_identity_id: other_account.identity_id)

    other_credential
    |> Ecto.Changeset.change(key_id: "missing-old-key")
    |> Repo.update!()

    before_credential = Repo.get!(GitHubCredential, context.credential.id)
    corrupt_other = Repo.get!(GitHubCredential, other_credential.id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    for call <-
          direct_mutation_calls(
            context.actor,
            context.account,
            reference,
            "replacement-token"
          ) do
      assert {:error, :credential_service_unavailable} = call.(%{})
      assert Repo.get!(GitHubCredential, context.credential.id) == before_credential
      assert Repo.get!(GitHubCredential, other_credential.id) == corrupt_other
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end

    assert {:ok, [_first, _second]} = ForgeAccounts.list_github_accounts(context.actor)
  end

  test "an actor-owned credential is validated after its identity is unlinked", context do
    orphan_pat = "totally-secret-orphaned-credential-token"

    assert {:ok, _updated} =
             ForgeAccounts.replace_github_credential(
               context.actor,
               context.account.identity_id,
               profile(context.account.github_user_id, "octocat"),
               orphan_pat,
               %{operation_id: "seed-orphaned-credential"}
             )

    identity = Repo.get!(GitHubIdentity, context.account.identity_id)
    assert {:ok, _unlinked} = ForgeAccounts.unlink_github_identity(context.actor, identity)

    orphan_identity = Repo.get!(GitHubIdentity, context.account.identity_id)
    before = Repo.get!(GitHubCredential, context.credential.id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    assert {:error, :invalid_response} =
             GitHubCredentialVault.validate_actor_owned_profile(
               before,
               orphan_identity,
               context.actor.id,
               unsafe_profile(9_000_000_002, :profile_url, orphan_pat)
             )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :credential_service_unavailable} =
                 ForgeAccounts.save_github_account(
                   context.actor,
                   profile(9_000_000_002, "must-not-link"),
                   "new-account-token",
                   %{operation_id: orphan_pat}
                 )
      end)

    refute log =~ orphan_pat
    assert Repo.get!(GitHubCredential, context.credential.id) == before
    refute Repo.get_by(GitHubIdentity, github_user_id: 9_000_000_002)
    assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    assert {:ok, []} = ForgeAccounts.list_github_accounts(context.actor)
  end

  test "a legacy orphan credential is still checked against provider profile strings", context do
    orphan_pat = "totally-secret-token"

    assert {:ok, _updated} =
             ForgeAccounts.replace_github_credential(
               context.actor,
               context.account.identity_id,
               profile(context.account.github_user_id, "octocat"),
               orphan_pat,
               %{operation_id: "seed-legacy-orphan-profile-token"}
             )

    identity = Repo.get!(GitHubIdentity, context.account.identity_id)
    assert {:ok, _unlinked} = ForgeAccounts.unlink_github_identity(context.actor, identity)

    before = Repo.get!(GitHubCredential, context.credential.id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_response} =
                 ForgeAccounts.save_github_account(
                   context.actor,
                   unsafe_profile(9_000_000_002, :profile_url, "secret-token"),
                   "new-account-token",
                   %{operation_id: "reject-legacy-orphan-profile"}
                 )
      end)

    refute log =~ orphan_pat
    assert Repo.get!(GitHubCredential, context.credential.id) == before
    refute Repo.get_by(GitHubIdentity, github_user_id: 9_000_000_002)
    refute Repo.get_by(AuditEvent, operation_id: "reject-legacy-orphan-profile")
    assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    assert {:ok, []} = ForgeAccounts.list_github_accounts(context.actor)
  end

  test "direct delete and unlink reject exact stored-PAT metadata without leakage", context do
    pat = "totally-secret-token"

    assert {:ok, _updated} =
             ForgeAccounts.replace_github_credential(
               context.actor,
               context.account.identity_id,
               profile(context.account.github_user_id, "octocat"),
               pat,
               %{operation_id: "seed-unprefixed-delete-token"}
             )

    before = Repo.get!(GitHubCredential, context.credential.id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    calls = [
      fn metadata ->
        ForgeAccounts.delete_github_credential(
          context.actor,
          context.account.identity_id,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.unlink_github_account(
          context.actor,
          context.account.identity_id,
          metadata
        )
      end
    ]

    for call <- calls, field <- [:request_id, :operation_id, :user_agent] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_request_metadata} = call.(%{field => pat})
        end)

      refute log =~ pat
      assert Repo.get!(GitHubCredential, context.credential.id) == before
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "direct refresh and invalidation reject exact stored-PAT metadata", context do
    pat = "totally-secret-token"

    assert {:ok, _updated} =
             ForgeAccounts.replace_github_credential(
               context.actor,
               context.account.identity_id,
               profile(context.account.github_user_id, "octocat"),
               pat,
               %{operation_id: "seed-unprefixed-refresh-token"}
             )

    reference = verification_reference(context.actor, context.account.identity_id)
    before_credential = Repo.get!(GitHubCredential, context.credential.id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)

    calls = [
      fn metadata ->
        ForgeAccounts.refresh_github_account(
          context.actor,
          context.account.identity_id,
          profile(context.account.github_user_id, "must-not-refresh"),
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.refresh_github_account_if_current(
          context.actor,
          context.account.identity_id,
          reference,
          profile(context.account.github_user_id, "must-not-refresh"),
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.mark_github_credential_invalid(
          context.actor,
          context.account.identity_id,
          reference,
          metadata
        )
      end
    ]

    for call <- calls, field <- [:request_id, :operation_id, :user_agent] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_request_metadata} = call.(%{field => pat})
        end)

      refute log =~ pat
      assert Repo.get!(GitHubCredential, context.credential.id) == before_credential
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
    end
  end

  test "metadata validation uses static key pairs without atom interning" do
    unique_key = "not_preinterned_#{System.unique_integer([:positive])}"
    credential = "totally-secret-token"

    assert {:ok, %{}} = ForgeAccounts.validate_github_request_metadata(%{unique_key => "ignored"})

    assert {:ok, %{"request_id" => "safe-request"}} =
             ForgeAccounts.validate_github_request_metadata(%{
               request_id: "safe-request",
               user_agent: nil
             })

    assert {:error, :invalid_request_metadata} =
             ForgeAccounts.validate_github_request_metadata(%{
               "request_id" => "safe-two",
               request_id: "safe-one"
             })

    assert {:error, :invalid_request_metadata} =
             ForgeAccounts.validate_github_request_metadata(
               %{request_id: "prefix-totally-secret-token-suffix"},
               credential
             )

    assert {:error, :invalid_request_metadata} =
             ForgeAccounts.validate_github_request_metadata(
               %{request_id: "secret-token"},
               credential
             )

    source =
      File.read!(Path.expand("../lib/forge_accounts/github_request_metadata.ex", __DIR__))

    refute source =~ "to_existing_atom"
    refute source =~ "to_atom"
  end

  test "all direct GitHub mutations fail closed when the vault keyring is missing or unavailable",
       context do
    assert {:ok, credentialless} =
             ForgeAccounts.save_github_account(
               context.actor,
               profile(9_000_000_002, "credentialless"),
               "totally-secret-vault-credential",
               %{operation_id: "seed-credentialless-account"}
             )

    assert {:ok, _without_credential} =
             ForgeAccounts.delete_github_credential(
               context.actor,
               credentialless.identity_id,
               %{operation_id: "remove-credential-before-keyring-test"}
             )

    reference = verification_reference(context.actor, context.account.identity_id)
    before = Repo.get!(GitHubCredential, context.credential.id)
    audit_count = Repo.aggregate(AuditEvent, :count, :id)
    original = Application.fetch_env(:fornacast, :github_credential_keyring)
    on_exit(fn -> restore_keyring(original) end)

    calls =
      Enum.map(
        direct_mutation_calls(context.actor, context.account, reference, "new-token"),
        fn call -> fn -> call.(%{}) end end
      ) ++
        [
          fn ->
            ForgeAccounts.unlink_github_account(
              context.actor,
              credentialless.identity_id,
              %{}
            )
          end
        ]

    for configured <- [:unavailable, :missing] do
      configure_keyring(configured)

      for call <- calls do
        assert {:error, :credential_service_unavailable} = call.()
        assert Repo.get!(GitHubCredential, context.credential.id) == before
        assert Repo.aggregate(AuditEvent, :count, :id) == audit_count
      end
    end

    assert {:ok, [_first, _second]} = ForgeAccounts.list_github_accounts(context.actor)
  end

  test "verification checkout passes an opaque exact credential generation", context do
    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential_for_verification(
               context.actor,
               context.account.identity_id,
               fn pat, reference ->
                 assert pat == @pat
                 assert reference.credential_id == context.credential.id
                 assert reference.identity_id == context.account.identity_id
                 assert reference.verification_version == context.credential.verification_version
                 refute inspect(reference) =~ @pat
                 :ok
               end
             )
  end

  test "credential invalidation is an audited domain mutation that retains the link", context do
    parent = self()

    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential_for_verification(
               context.actor,
               context.account.identity_id,
               fn _pat, reference ->
                 send(parent, {:verification_reference, reference})
                 :ok
               end
             )

    assert_receive {:verification_reference, reference}

    assert {:ok, invalidated} =
             ForgeAccounts.mark_github_credential_invalid(
               context.actor,
               context.account.identity_id,
               reference,
               %{operation_id: "invalidate-saved-github-account"}
             )

    assert invalidated.identity_id == context.account.identity_id
    assert invalidated.credential_present
    assert invalidated.credential_status == :invalid
    assert Repo.get!(GitHubCredential, context.credential.id).status == :invalid

    assert %AuditEvent{metadata: metadata} =
             Repo.get_by!(AuditEvent, action: "github.credential.invalidated")

    assert metadata["status"] == "invalid"
    refute inspect(metadata) =~ @pat

    assert {:error, :credential_invalid} =
             ForgeAccounts.with_github_credential(
               context.actor,
               context.account.identity_id,
               fn _pat -> flunk("invalid credential checked out") end
             )

    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential_for_verification(
               context.actor,
               context.account.identity_id,
               fn pat, current_reference ->
                 assert pat == @pat
                 assert current_reference.verification_version > reference.verification_version
                 :ok
               end
             )
  end

  defp profile(id, login) do
    %{
      github_user_id: id,
      login: login,
      avatar_url: "https://avatars.githubusercontent.com/u/#{id}",
      profile_url: "https://github.com/#{login}"
    }
  end

  defp unsafe_profile(id, :login, pat), do: profile(id, pat)

  defp unsafe_profile(id, :avatar_url, pat) do
    profile(id, "safe-login")
    |> Map.put(:avatar_url, "https://github.com/avatar/#{pat}/image.png")
  end

  defp unsafe_profile(id, :profile_url, pat) do
    profile(id, "safe-login")
    |> Map.put(:profile_url, "https://github.com/safe-login/#{pat}")
  end

  defp direct_mutation_calls(actor, account, reference, pat) do
    profile = profile(account.github_user_id, "must-not-mutate")

    [
      fn metadata -> ForgeAccounts.save_github_account(actor, profile, pat, metadata) end,
      fn metadata ->
        ForgeAccounts.save_github_account_if_absent(
          actor,
          profile(9_000_000_003, "must-not-link"),
          pat,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.save_github_credential_if_absent(
          actor,
          account.identity_id,
          profile,
          pat,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.replace_github_credential(
          actor,
          account.identity_id,
          profile,
          pat,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.replace_github_credential_if_current(
          actor,
          account.identity_id,
          reference,
          profile,
          pat,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.refresh_github_account(actor, account.identity_id, profile, metadata)
      end,
      fn metadata ->
        ForgeAccounts.refresh_github_account_if_current(
          actor,
          account.identity_id,
          reference,
          profile,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.mark_github_credential_invalid(
          actor,
          account.identity_id,
          reference,
          metadata
        )
      end,
      fn metadata ->
        ForgeAccounts.delete_github_credential(actor, account.identity_id, metadata)
      end,
      fn metadata -> ForgeAccounts.unlink_github_account(actor, account.identity_id, metadata) end
    ]
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

  defp verification_reference(actor, identity_id) do
    owner = self()

    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential_for_verification(
               actor,
               identity_id,
               fn _pat, reference ->
                 send(owner, {:verification_reference, reference})
                 :ok
               end
             )

    assert_receive {:verification_reference, reference}
    reference
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
