defmodule ForgeAccounts.GitHubAccountsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  require Logger

  alias Ecto.Adapters.SQL

  alias ForgeAccounts.{
    GitHubAccountView,
    GitHubCredential,
    GitHubIdentity,
    Organization,
    User
  }

  alias Fornacast.{AuditEvent, Repo}

  @first_pat "github_pat_first_secret"
  @second_pat "github_pat_second_secret"
  @request_metadata %{
    request_id: "github-account-request",
    ip_address: "127.0.0.1",
    user_agent: "ExUnit"
  }

  setup do
    reset_database!()
  end

  test "saving a first account links, encrypts, audits, and returns only a safe view" do
    actor = user_fixture("alice")

    assert {:ok,
            %GitHubAccountView{
              identity_id: identity_id,
              github_user_id: 9_000_000_001,
              login: "octocat",
              display_name: "Github:octocat",
              avatar_url: "https://avatars.githubusercontent.com/u/9000000001",
              profile_url: "https://github.com/octocat",
              credential_present: true,
              credential_status: :valid,
              identity_last_verified_at: %DateTime{},
              credential_last_verified_at: %DateTime{}
            } = view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               @request_metadata
             )

    assert %GitHubIdentity{local_user_id: actor_id} = Repo.get!(GitHubIdentity, identity_id)
    assert actor_id == actor.id

    assert %GitHubCredential{
             id: credential_id,
             github_identity_id: ^identity_id,
             local_user_id: actor_id,
             status: :valid
           } = credential = Repo.get_by!(GitHubCredential, github_identity_id: identity_id)

    assert actor_id == actor.id
    assert credential_id > 0
    refute credential.ciphertext == @first_pat

    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential(actor, identity_id, fn checked_out ->
               assert checked_out == @first_pat
               :ok
             end)

    assert %AuditEvent{
             actor_user_id: actor_id,
             action: "github.account.linked",
             target_type: "github_identity",
             target_id: target_id,
             metadata: metadata
           } = Repo.get_by!(AuditEvent, action: "github.account.linked")

    assert actor_id == actor.id
    assert target_id == Integer.to_string(identity_id)
    assert metadata["github_user_id"] == 9_000_000_001
    assert metadata["login"] == "octocat"
    assert metadata["status"] == "valid"
    assert metadata["result"] == "success"
    assert metadata["request_id"] == "github-account-request"
    refute inspect(metadata) =~ @first_pat
    refute inspect(view) =~ @first_pat
    refute Map.has_key?(view, :ciphertext)
    refute Map.has_key?(view, :nonce)
    refute Map.has_key?(view, :tag)
    refute Map.has_key?(view, :key_id)
  end

  test "one user saves multiple accounts and collisions reveal no other-user data" do
    actor = user_fixture("alice")
    other = user_fixture("bob")

    assert {:ok, first} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "zeta"),
               @first_pat,
               %{}
             )

    assert {:ok, second} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_002, "alpha"),
               @second_pat,
               %{}
             )

    assert first.identity_id != second.identity_id

    assert {:error, :already_linked} =
             ForgeAccounts.save_github_account(
               other,
               profile(9_000_000_001, "other-observation"),
               "github_pat_other_secret",
               %{}
             )

    assert %GitHubIdentity{login: "zeta", local_user_id: actor_id} =
             Repo.get!(GitHubIdentity, first.identity_id)

    assert actor_id == actor.id
    refute inspect({:error, :already_linked}) =~ actor.username
  end

  test "saving the same identity rotates the envelope in the same credential row" do
    actor = user_fixture("alice")

    assert {:ok, first_view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    first_credential =
      Repo.get_by!(GitHubCredential, github_identity_id: first_view.identity_id)

    assert {:ok, second_view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat-renamed"),
               @second_pat,
               %{}
             )

    second_credential =
      Repo.get_by!(GitHubCredential, github_identity_id: second_view.identity_id)

    assert first_credential.id == second_credential.id
    assert first_credential.ciphertext != second_credential.ciphertext
    assert first_credential.nonce != second_credential.nonce

    assert_saved_pat(actor, first_view.identity_id, @second_pat)

    assert Repo.aggregate(
             from(event in AuditEvent, where: event.action == "github.credential.replaced"),
             :count,
             :id
           ) == 1
  end

  test "explicit replacement requires ownership and an exact verified numeric identity" do
    actor = user_fixture("alice")
    other = user_fixture("bob")

    assert {:ok, view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    before_identity = Repo.get!(GitHubIdentity, view.identity_id)
    before_credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

    assert {:error, :identity_mismatch} =
             ForgeAccounts.replace_github_credential(
               actor,
               view.identity_id,
               profile(9_000_000_002, "intruder"),
               @second_pat,
               %{}
             )

    assert {:error, :not_found} =
             ForgeAccounts.replace_github_credential(
               other,
               view.identity_id,
               profile(9_000_000_001, "octocat"),
               @second_pat,
               %{}
             )

    assert Repo.get!(GitHubIdentity, view.identity_id) == before_identity

    assert Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id) ==
             before_credential

    assert_saved_pat(actor, view.identity_id, @first_pat)
  end

  test "refresh updates verified observations and status without changing the envelope" do
    actor = user_fixture("alice")

    assert {:ok, view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    credential_before = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

    Repo.update_all(
      from(credential in GitHubCredential, where: credential.id == ^credential_before.id),
      set: [status: :invalid]
    )

    assert {:error, :identity_mismatch} =
             ForgeAccounts.refresh_github_account(
               actor,
               view.identity_id,
               profile(9_000_000_002, "wrong"),
               %{}
             )

    assert {:ok,
            %GitHubAccountView{
              login: "octocat-renamed",
              credential_status: :valid,
              credential_present: true
            }} =
             ForgeAccounts.refresh_github_account(
               actor,
               view.identity_id,
               profile(9_000_000_001, "octocat-renamed"),
               %{}
             )

    credential_after = Repo.get!(GitHubCredential, credential_before.id)
    assert credential_after.id == credential_before.id
    assert credential_after.ciphertext == credential_before.ciphertext
    assert credential_after.nonce == credential_before.nonce
    assert credential_after.tag == credential_before.tag
    assert credential_after.key_id == credential_before.key_id
    assert credential_after.status == :valid
    assert_saved_pat(actor, view.identity_id, @first_pat)
    assert Repo.get_by!(AuditEvent, action: "github.account.reverified")
  end

  test "deleting a credential retains its linked identity while unlink removes both link and credential" do
    actor = user_fixture("alice")

    assert {:ok, first} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    assert {:ok, %GitHubAccountView{credential_present: false, credential_status: nil}} =
             ForgeAccounts.delete_github_credential(actor, first.identity_id, %{})

    assert %GitHubIdentity{local_user_id: actor_id} = Repo.get!(GitHubIdentity, first.identity_id)
    assert actor_id == actor.id
    refute Repo.get_by(GitHubCredential, github_identity_id: first.identity_id)

    assert {:error, :not_found} =
             ForgeAccounts.with_github_credential(actor, first.identity_id, fn _ ->
               flunk("missing credential callback invoked")
             end)

    assert Repo.get_by!(AuditEvent, action: "github.credential.deleted")

    assert {:ok, second} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_002, "hubot"),
               @second_pat,
               %{}
             )

    assert {:ok, %GitHubAccountView{credential_present: false}} =
             ForgeAccounts.unlink_github_account(actor, second.identity_id, %{})

    assert %GitHubIdentity{local_user_id: nil} = Repo.get!(GitHubIdentity, second.identity_id)
    refute Repo.get_by(GitHubCredential, github_identity_id: second.identity_id)
    assert Repo.get_by!(AuditEvent, action: "github.account.unlinked")
  end

  test "checkout authorizes an active owner, rejects typed failures, and propagates callback exceptions" do
    actor = user_fixture("alice")
    other = user_fixture("bob")

    assert {:ok, view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    ref = make_ref()

    assert {:error, :not_found} =
             ForgeAccounts.with_github_credential(other, view.identity_id, fn _ ->
               send(self(), ref)
             end)

    refute_received ^ref

    assert {:error, :not_found} =
             ForgeAccounts.with_github_credential(actor, view.identity_id + 100_000, fn _ ->
               send(self(), ref)
             end)

    refute_received ^ref

    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

    Repo.update_all(
      from(saved in GitHubCredential, where: saved.id == ^credential.id),
      set: [tag: :binary.copy(<<0>>, 16)]
    )

    assert {:error, :credential_service_unavailable} =
             ForgeAccounts.with_github_credential(actor, view.identity_id, fn _ ->
               send(self(), ref)
             end)

    refute_received ^ref

    assert {:ok, _} =
             ForgeAccounts.replace_github_credential(
               actor,
               view.identity_id,
               profile(9_000_000_001, "octocat"),
               @second_pat,
               %{}
             )

    assert_raise RuntimeError, "callback failed", fn ->
      ForgeAccounts.with_github_credential(actor, view.identity_id, fn pat ->
        assert pat == @second_pat
        raise "callback failed"
      end)
    end

    sanitized =
      assert_raise ForgeAccounts.GitHubAccounts.CredentialCallbackError,
                   "credential callback failed",
                   fn ->
                     ForgeAccounts.with_github_credential(actor, view.identity_id, fn pat ->
                       raise pat
                     end)
                   end

    refute Exception.message(sanitized) =~ @second_pat
    refute inspect(sanitized) =~ @second_pat
  end

  test "checkout rejects unsafe, oversized, and deeply nested callback results" do
    actor = user_fixture("alice")

    assert {:ok, view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    for callback <- [
          fn pat -> pat end,
          fn pat -> {:error, %{headers: [{"authorization", "Bearer " <> pat}]}} end,
          fn pat -> {:error, %URI{scheme: "https", host: "github.com", path: "/" <> pat}} end,
          fn pat ->
            {:error, [binary_part(pat, 0, 6), binary_part(pat, 6, byte_size(pat) - 6)]}
          end,
          fn pat ->
            {:error, {binary_part(pat, 0, 6), binary_part(pat, 6, byte_size(pat) - 6)}}
          end,
          fn pat -> {:error, String.to_charlist(pat)} end,
          fn _pat -> {:error, :github_pat_first_secret} end,
          fn pat -> {:error, "credential rejected: " <> pat <> ": do not return"} end,
          fn _pat -> {:error, List.duplicate(:retry, 100)} end,
          fn _pat -> {:error, Enum.reduce(1..20, :done, fn _, nested -> {nested} end)} end,
          fn _pat -> {:ok, %{status: 202, imported: 3}} end
        ] do
      assert {:error, :unsafe_credential_result} =
               ForgeAccounts.with_github_credential(actor, view.identity_id, callback)
    end

    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential(actor, view.identity_id, fn pat ->
               assert pat == @first_pat
               :ok
             end)

    assert {:ok, {:error, {:rate_limited, 429, [:retryable, 3]}}} =
             ForgeAccounts.with_github_credential(actor, view.identity_id, fn _pat ->
               {:error, {:rate_limited, 429, [:retryable, 3]}}
             end)

    assert {:error, :unsafe_credential_result} =
             ForgeAccounts.with_github_credential(actor, view.identity_id, fn _pat ->
               :arbitrary
             end)
  end

  test "checkout sanitizes a credential found only in captured stack arguments" do
    actor = user_fixture("alice")

    assert {:ok, view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    {error, stacktrace} =
      try do
        ForgeAccounts.with_github_credential(actor, view.identity_id, fn pat ->
          String.to_integer(pat)
        end)

        flunk("credential-bearing stack was not sanitized")
      rescue
        error -> {error, __STACKTRACE__}
      end

    assert %ForgeAccounts.GitHubAccounts.CredentialCallbackError{} = error
    formatted = Exception.format(:error, error, stacktrace)
    inspected = inspect({error, stacktrace})
    logged = capture_log(fn -> Logger.error(formatted) end)

    for rendered <- [Exception.message(error), formatted, inspected, logged] do
      refute rendered =~ @first_pat
    end
  end

  test "saving after credential deletion emits replacement without relinking" do
    actor = user_fixture("alice")

    assert {:ok, first} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    assert {:ok, %GitHubAccountView{credential_present: false}} =
             ForgeAccounts.delete_github_credential(actor, first.identity_id, %{})

    assert {:ok, replacement} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat-renamed"),
               @second_pat,
               %{}
             )

    assert replacement.identity_id == first.identity_id
    assert_saved_pat(actor, first.identity_id, @second_pat)

    assert action_count("github.account.linked") == 1
    assert action_count("github.credential.deleted") == 1
    assert action_count("github.credential.replaced") == 1
  end

  test "operation IDs guard the whole lifecycle before action inference or mutation" do
    actor = user_fixture("alice")
    first_operation = %{operation_id: "github-lifecycle-1"}

    assert {:ok, first} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               first_operation
             )

    credential_before = Repo.get_by!(GitHubCredential, github_identity_id: first.identity_id)

    assert {:error, :duplicate_operation} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "should-not-persist"),
               @second_pat,
               first_operation
             )

    assert Repo.get_by!(GitHubCredential, github_identity_id: first.identity_id) ==
             credential_before

    assert %GitHubIdentity{login: "octocat"} = Repo.get!(GitHubIdentity, first.identity_id)
    assert_saved_pat(actor, first.identity_id, @first_pat)

    assert {:ok, _replacement} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat-renamed"),
               @second_pat,
               %{operation_id: "github-lifecycle-2"}
             )

    assert_saved_pat(actor, first.identity_id, @second_pat)

    assert [linked, replaced] =
             AuditEvent
             |> where([event], event.target_id == ^Integer.to_string(first.identity_id))
             |> order_by([event], asc: event.id)
             |> Repo.all()

    assert {linked.action, linked.operation_id} ==
             {"github.account.linked", "github-lifecycle-1"}

    assert {replaced.action, replaced.operation_id} ==
             {"github.credential.replaced", "github-lifecycle-2"}
  end

  test "disabled users and organization rows are forbidden" do
    disabled = user_fixture("disabled", state: :disabled)
    organization = organization_fixture("acme")

    for actor <- [disabled, organization] do
      assert {:error, :forbidden} = ForgeAccounts.list_github_accounts(actor)

      assert {:error, :forbidden} =
               ForgeAccounts.save_github_account(
                 actor,
                 profile(9_000_000_001, "octocat"),
                 @first_pat,
                 %{}
               )

      assert {:error, :forbidden} =
               ForgeAccounts.with_github_credential(actor, 1, fn _ -> :never end)
    end

    assert Repo.aggregate(GitHubIdentity, :count, :id) == 0
    assert Repo.aggregate(GitHubCredential, :count, :id) == 0
  end

  test "list returns deterministic safe views for every linked account" do
    actor = user_fixture("alice")

    for {github_user_id, login, pat} <- [
          {9_000_000_003, "zeta", @first_pat},
          {9_000_000_001, "alpha", @second_pat},
          {9_000_000_002, "alpha", "github_pat_third_secret"}
        ] do
      assert {:ok, %GitHubAccountView{}} =
               ForgeAccounts.save_github_account(
                 actor,
                 profile(github_user_id, login),
                 pat,
                 %{}
               )
    end

    assert {:ok, [first, second, third]} = ForgeAccounts.list_github_accounts(actor)

    assert [{"alpha", 9_000_000_001}, {"alpha", 9_000_000_002}, {"zeta", 9_000_000_003}] ==
             Enum.map([first, second, third], &{&1.login, &1.github_user_id})

    inspected = inspect([first, second, third])

    for forbidden <- [
          @first_pat,
          @second_pat,
          "github_pat_third_secret",
          "ciphertext:",
          "nonce:",
          "tag:",
          "key_id:"
        ] do
      refute inspected =~ forbidden
    end
  end

  test "PostgreSQL list explicitly rejects a deleted identity even if its link invariant is corrupted" do
    if postgres?() do
      actor = user_fixture("alice")

      SQL.query!(Repo, "delete from github_identities where kind = 'deleted'", [])

      SQL.query!(
        Repo,
        "alter table github_identities drop constraint github_identities_deleted_sentinel_check",
        []
      )

      Repo.insert!(%GitHubIdentity{
        kind: :deleted,
        github_user_id: nil,
        login: "ghost",
        local_user_id: actor.id
      })

      assert {:ok, []} = ForgeAccounts.list_github_accounts(actor)
    else
      assert true
    end
  end

  test "Turso list stays bounded by persisted identity and ownership invariants" do
    if turso?() do
      actor = user_fixture("alice")
      other = user_fixture("bob")

      invalid_deleted_identity =
        %GitHubIdentity{}
        |> Ecto.Changeset.change(%{
          kind: :deleted,
          github_user_id: nil,
          login: "ghost",
          local_user_id: actor.id
        })
        |> Ecto.Changeset.check_constraint(:local_user_id,
          name: ~r/github_identities_deleted_sentinel_check/
        )

      assert {:error, %Ecto.Changeset{errors: [local_user_id: {_, metadata}]}} =
               Repo.insert(invalid_deleted_identity)

      assert metadata[:constraint] == :check

      assert {:ok, actor_account} =
               ForgeAccounts.save_github_account(
                 actor,
                 profile(9_000_000_001, "octocat"),
                 @first_pat,
                 %{}
               )

      assert {:ok, _other_account} =
               ForgeAccounts.save_github_account(
                 other,
                 profile(9_000_000_002, "hubot"),
                 @second_pat,
                 %{}
               )

      assert %GitHubIdentity{kind: :deleted, local_user_id: nil} =
               ForgeAccounts.github_deleted_identity()

      assert {:ok, [listed]} = ForgeAccounts.list_github_accounts(actor)
      assert listed.identity_id == actor_account.identity_id
      assert listed.github_user_id == actor_account.github_user_id
    else
      assert true
    end
  end

  test "vault failure rolls back identity observation, link, and placeholder credential" do
    actor = user_fixture("alice")
    original = Application.get_env(:fornacast, :github_credential_keyring)
    Application.put_env(:fornacast, :github_credential_keyring, :unavailable)
    on_exit(fn -> Application.put_env(:fornacast, :github_credential_keyring, original) end)

    assert {:error, :credential_service_unavailable} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    refute Repo.get_by(GitHubIdentity, github_user_id: 9_000_000_001)
    assert Repo.aggregate(GitHubCredential, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "audit failure rolls replacement back with the old credential unchanged" do
    actor = user_fixture("alice")

    assert {:ok, view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{}
             )

    before = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)

    assert {:error, %Ecto.Changeset{}} =
             ForgeAccounts.replace_github_credential(
               actor,
               view.identity_id,
               profile(9_000_000_001, "renamed"),
               @second_pat,
               %{ip_address: {:invalid, :ip}}
             )

    assert Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id) == before
    assert %GitHubIdentity{login: "octocat"} = Repo.get!(GitHubIdentity, view.identity_id)
    assert_saved_pat(actor, view.identity_id, @first_pat)
  end

  test "concurrent saves keep one credential row with a matching decryptable envelope" do
    prepare_independent_concurrency!()
    actor = independent_user_fixture("alice")

    results =
      run_independent_workers([@first_pat, @second_pat], fn pat ->
        ForgeAccounts.save_github_account(
          actor,
          profile(9_000_000_001, "octocat"),
          pat,
          %{}
        )
      end)

    assert Enum.all?(results, &match?({:ok, %GitHubAccountView{}}, &1))

    assert %GitHubIdentity{id: identity_id, local_user_id: actor_id} =
             independent_get_by!(GitHubIdentity, github_user_id: 9_000_000_001)

    assert actor_id == actor.id
    assert independent_count(GitHubCredential) == 1

    assert {:ok, checked_out_digest} = independent_with_github_credential(actor, identity_id)

    assert checked_out_digest in Enum.map([@first_pat, @second_pat], &credential_digest/1)
  end

  test "concurrent retries with one operation ID mutate and audit exactly once" do
    prepare_independent_concurrency!()
    actor = independent_user_fixture("alice")

    results =
      run_independent_workers([@first_pat, @second_pat], fn pat ->
        ForgeAccounts.save_github_account(
          actor,
          profile(9_000_000_001, "octocat"),
          pat,
          %{operation_id: "concurrent-first-save"}
        )
      end)

    assert Enum.count(results, &match?({:ok, %GitHubAccountView{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :duplicate_operation})) == 1

    identity = independent_get_by!(GitHubIdentity, github_user_id: 9_000_000_001)
    assert identity.local_user_id == actor.id
    assert independent_count(GitHubCredential) == 1

    assert {:ok, digest} = independent_with_github_credential(actor, identity.id)

    assert digest in Enum.map([@first_pat, @second_pat], &credential_digest/1)
    assert independent_action_count("github.account.linked") == 1
    assert independent_action_count("github.credential.replaced") == 0
  end

  test "one operation ID globally guards different actors and identities" do
    prepare_independent_concurrency!()
    first_actor = independent_user_fixture("alice")
    second_actor = independent_user_fixture("bob")

    assert {:ok, first_view} =
             independent_saved_account(
               first_actor,
               9_000_000_001,
               "alice-seed",
               @first_pat
             )

    assert {:ok, second_view} =
             independent_saved_account(
               second_actor,
               9_000_000_002,
               "bob-seed",
               @second_pat
             )

    first_credential =
      independent_get_by!(GitHubCredential, github_identity_id: first_view.identity_id)

    second_credential =
      independent_get_by!(GitHubCredential, github_identity_id: second_view.identity_id)

    inputs = [
      %{
        actor: first_actor,
        identity_id: first_view.identity_id,
        github_user_id: 9_000_000_001,
        seed_login: "alice-seed",
        seed_pat: @first_pat,
        replacement_login: "alice-winner",
        replacement_pat: "github_pat_alice_winner",
        credential_id: first_credential.id
      },
      %{
        actor: second_actor,
        identity_id: second_view.identity_id,
        github_user_id: 9_000_000_002,
        seed_login: "bob-seed",
        seed_pat: @second_pat,
        replacement_login: "bob-winner",
        replacement_pat: "github_pat_bob_winner",
        credential_id: second_credential.id
      }
    ]

    results =
      run_independent_workers(inputs, fn input ->
        ForgeAccounts.replace_github_credential(
          input.actor,
          input.identity_id,
          profile(input.github_user_id, input.replacement_login),
          input.replacement_pat,
          %{operation_id: "cross-actor-shared-operation"}
        )
      end)

    assert Enum.count(results, &match?({:ok, %GitHubAccountView{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :duplicate_operation})) == 1

    winner_index = Enum.find_index(results, &match?({:ok, %GitHubAccountView{}}, &1))
    winner = Enum.at(inputs, winner_index)

    Enum.with_index(inputs, fn input, index ->
      identity = independent_get_by!(GitHubIdentity, id: input.identity_id)
      credential = independent_get_by!(GitHubCredential, github_identity_id: input.identity_id)
      assert credential.id == input.credential_id
      assert {:ok, digest} = independent_with_github_credential(input.actor, input.identity_id)

      if index == winner_index do
        assert identity.login == input.replacement_login
        assert digest == credential_digest(input.replacement_pat)
      else
        assert identity.login == input.seed_login
        assert digest == credential_digest(input.seed_pat)
      end
    end)

    assert %AuditEvent{
             actor_user_id: winner_actor_id,
             action: "github.credential.replaced",
             target_id: winner_target_id
           } =
             independent_get_by!(AuditEvent, operation_id: "cross-actor-shared-operation")

    assert winner_actor_id == winner.actor.id
    assert winner_target_id == Integer.to_string(winner.identity_id)
    assert independent_action_count("github.account.linked") == 2
    assert independent_action_count("github.credential.replaced") == 1
  end

  test "concurrent replacements retain one row with a decryptable winning envelope" do
    prepare_independent_concurrency!()
    actor = independent_user_fixture("alice")

    assert {:ok, view} =
             independent_call(fn ->
               ForgeAccounts.save_github_account(
                 actor,
                 profile(9_000_000_001, "octocat"),
                 @first_pat,
                 %{operation_id: "replace-race-seed"}
               )
             end)

    original = independent_get_by!(GitHubCredential, github_identity_id: view.identity_id)

    results =
      run_independent_workers(
        [
          {@second_pat, "replace-race-1", "octocat-second"},
          {"github_pat_third_secret", "replace-race-2", "octocat-third"}
        ],
        fn {pat, operation_id, login} ->
          ForgeAccounts.replace_github_credential(
            actor,
            view.identity_id,
            profile(9_000_000_001, login),
            pat,
            %{operation_id: operation_id}
          )
        end
      )

    assert Enum.all?(results, &match?({:ok, %GitHubAccountView{}}, &1))

    final = independent_get_by!(GitHubCredential, github_identity_id: view.identity_id)
    final_identity = independent_get_by!(GitHubIdentity, id: view.identity_id)
    assert final.id == original.id
    assert independent_count(GitHubCredential) == 1

    assert {:ok, digest} = independent_with_github_credential(actor, view.identity_id)

    assert {final_identity.login, digest} in [
             {"octocat-second", credential_digest(@second_pat)},
             {"octocat-third", credential_digest("github_pat_third_secret")}
           ]

    assert independent_action_count("github.account.linked") == 1
    assert independent_action_count("github.credential.replaced") == 2

    for operation_id <- ["replace-race-1", "replace-race-2"] do
      assert %AuditEvent{
               actor_user_id: actor_id,
               action: "github.credential.replaced",
               target_id: target_id
             } = independent_get_by!(AuditEvent, operation_id: operation_id)

      assert actor_id == actor.id
      assert target_id == Integer.to_string(view.identity_id)
    end
  end

  test "concurrent replace and delete leave the link without a partial credential" do
    prepare_independent_concurrency!()
    actor = independent_user_fixture("alice")

    assert {:ok, view} = independent_saved_account(actor, 9_000_000_001, "octocat", @first_pat)

    [replace_result, delete_result] =
      run_independent_workers([:replace, :delete], fn
        :replace ->
          ForgeAccounts.replace_github_credential(
            actor,
            view.identity_id,
            profile(9_000_000_001, "replace-delete-winner"),
            @second_pat,
            %{operation_id: "replace-delete-replace"}
          )

        :delete ->
          ForgeAccounts.delete_github_credential(
            actor,
            view.identity_id,
            %{operation_id: "replace-delete-delete"}
          )
      end)

    assert match?({:ok, %GitHubAccountView{}}, delete_result)

    assert match?({:ok, %GitHubAccountView{}}, replace_result) or
             replace_result == {:error, :not_found}

    assert %GitHubIdentity{local_user_id: actor_id} =
             identity =
             independent_get_by!(GitHubIdentity, id: view.identity_id)

    assert actor_id == actor.id
    assert independent_count(GitHubCredential) == 0
    assert independent_action_count("github.credential.deleted") == 1

    expected_replacements = if match?({:ok, _view}, replace_result), do: 1, else: 0
    assert independent_action_count("github.credential.replaced") == expected_replacements

    case replace_result do
      {:ok, %GitHubAccountView{}} ->
        assert identity.login == "replace-delete-winner"

        assert %AuditEvent{
                 actor_user_id: actor_id,
                 action: "github.credential.replaced",
                 target_id: target_id
               } =
                 independent_get_by!(AuditEvent, operation_id: "replace-delete-replace")

        assert actor_id == actor.id
        assert target_id == Integer.to_string(view.identity_id)

      {:error, :not_found} ->
        assert identity.login == "octocat"
        refute independent_get_by(AuditEvent, operation_id: "replace-delete-replace")
    end
  end

  test "concurrent replace and unlink leave no credential or accidental link" do
    prepare_independent_concurrency!()
    actor = independent_user_fixture("alice")

    assert {:ok, view} = independent_saved_account(actor, 9_000_000_001, "octocat", @first_pat)

    [replace_result, unlink_result] =
      run_independent_workers([:replace, :unlink], fn
        :replace ->
          ForgeAccounts.replace_github_credential(
            actor,
            view.identity_id,
            profile(9_000_000_001, "replace-unlink-winner"),
            @second_pat,
            %{operation_id: "replace-unlink-replace"}
          )

        :unlink ->
          ForgeAccounts.unlink_github_account(
            actor,
            view.identity_id,
            %{operation_id: "replace-unlink-unlink"}
          )
      end)

    assert match?({:ok, %GitHubAccountView{}}, unlink_result)

    assert match?({:ok, %GitHubAccountView{}}, replace_result) or
             replace_result == {:error, :not_found}

    assert %GitHubIdentity{local_user_id: nil} =
             identity =
             independent_get_by!(GitHubIdentity, id: view.identity_id)

    assert independent_count(GitHubCredential) == 0
    assert independent_action_count("github.account.unlinked") == 1

    expected_replacements = if match?({:ok, _view}, replace_result), do: 1, else: 0
    assert independent_action_count("github.credential.replaced") == expected_replacements

    case replace_result do
      {:ok, %GitHubAccountView{}} ->
        assert identity.login == "replace-unlink-winner"

        assert %AuditEvent{
                 actor_user_id: actor_id,
                 action: "github.credential.replaced",
                 target_id: target_id
               } =
                 independent_get_by!(AuditEvent, operation_id: "replace-unlink-replace")

        assert actor_id == actor.id
        assert target_id == Integer.to_string(view.identity_id)

      {:error, :not_found} ->
        assert identity.login == "octocat"
        refute independent_get_by(AuditEvent, operation_id: "replace-unlink-replace")
    end
  end

  test "different users claiming one identity concurrently produce one masked loser" do
    prepare_independent_concurrency!()
    first_actor = independent_user_fixture("alice")
    second_actor = independent_user_fixture("bob")

    inputs = [
      {first_actor, @first_pat, "claim-race-alice", "octocat-alice"},
      {second_actor, @second_pat, "claim-race-bob", "octocat-bob"}
    ]

    results =
      run_independent_workers(inputs, fn {actor, pat, operation_id, login} ->
        ForgeAccounts.save_github_account(
          actor,
          profile(9_000_000_001, login),
          pat,
          %{operation_id: operation_id}
        )
      end)

    assert Enum.count(results, &match?({:ok, %GitHubAccountView{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_linked})) == 1

    winner_index = Enum.find_index(results, &match?({:ok, %GitHubAccountView{}}, &1))
    {winner, winning_pat, _operation_id, winning_login} = Enum.at(inputs, winner_index)
    identity = independent_get_by!(GitHubIdentity, github_user_id: 9_000_000_001)
    credential = independent_get_by!(GitHubCredential, github_identity_id: identity.id)

    assert identity.local_user_id == winner.id
    assert identity.login == winning_login
    assert credential.local_user_id == winner.id
    assert independent_count(GitHubCredential) == 1
    assert {:ok, digest} = independent_with_github_credential(winner, identity.id)
    assert digest == credential_digest(winning_pat)
    assert independent_action_count("github.account.linked") == 1
    assert independent_action_count("github.credential.replaced") == 0

    audit = independent_get_by!(AuditEvent, action: "github.account.linked")
    assert audit.actor_user_id == winner.id
    assert audit.target_id == Integer.to_string(identity.id)
  end

  test "an in-flight safe checkout can finish while deletion revokes future checkout" do
    prepare_independent_concurrency!()
    actor = independent_user_fixture("alice")

    assert {:ok, view} = independent_saved_account(actor, 9_000_000_001, "octocat", @first_pat)
    {checkout, release_ref, digest} = start_blocked_checkout(actor, view.identity_id)
    assert digest == credential_digest(@first_pat)

    assert {:ok, %GitHubAccountView{credential_present: false}} =
             independent_call(fn ->
               ForgeAccounts.delete_github_credential(
                 actor,
                 view.identity_id,
                 %{operation_id: "checkout-delete"}
               )
             end)

    send(checkout.pid, {:release_checkout, release_ref})
    assert {:ok, :ok} = Task.await(checkout, 30_000)
    assert {:error, :not_found} = independent_with_github_credential(actor, view.identity_id)

    assert %GitHubIdentity{local_user_id: actor_id} =
             independent_get_by!(GitHubIdentity, id: view.identity_id)

    assert actor_id == actor.id
    assert independent_count(GitHubCredential) == 0
    assert independent_action_count("github.credential.deleted") == 1
  end

  test "an in-flight safe checkout can finish while unlink revokes ownership" do
    prepare_independent_concurrency!()
    actor = independent_user_fixture("alice")

    assert {:ok, view} = independent_saved_account(actor, 9_000_000_001, "octocat", @first_pat)
    {checkout, release_ref, digest} = start_blocked_checkout(actor, view.identity_id)
    assert digest == credential_digest(@first_pat)

    assert {:ok, %GitHubAccountView{credential_present: false}} =
             independent_call(fn ->
               ForgeAccounts.unlink_github_account(
                 actor,
                 view.identity_id,
                 %{operation_id: "checkout-unlink"}
               )
             end)

    send(checkout.pid, {:release_checkout, release_ref})
    assert {:ok, :ok} = Task.await(checkout, 30_000)
    assert {:error, :not_found} = independent_with_github_credential(actor, view.identity_id)

    assert %GitHubIdentity{local_user_id: nil} =
             independent_get_by!(GitHubIdentity, id: view.identity_id)

    assert independent_count(GitHubCredential) == 0
    assert independent_action_count("github.account.unlinked") == 1
  end

  test "audit metadata drops unrelated profile and secret-shaped request values" do
    actor = user_fixture("alice")

    assert {:ok, _view} =
             ForgeAccounts.save_github_account(
               actor,
               profile(9_000_000_001, "octocat"),
               @first_pat,
               %{
                 request_id: "safe-request",
                 profile_url: "https://github.com/should-not-be-copied",
                 arbitrary_secret: "unrecognized-secret"
               }
             )

    audit = Repo.get_by!(AuditEvent, action: "github.account.linked")
    assert audit.metadata["request_id"] == "safe-request"
    refute Map.has_key?(audit.metadata, "profile_url")
    refute Map.has_key?(audit.metadata, "arbitrary_secret")
  end

  defp profile(github_user_id, login) do
    %{
      github_user_id: github_user_id,
      login: login,
      avatar_url: "https://avatars.githubusercontent.com/u/#{github_user_id}",
      profile_url: "https://github.com/#{login}"
    }
  end

  defp user_fixture(username, opts \\ []) do
    Repo.insert!(%User{
      username: username,
      email: "#{username}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: :user,
      state: Keyword.get(opts, :state, :active)
    })
  end

  defp organization_fixture(username) do
    Repo.insert!(%Organization{
      username: username,
      email: "organization+#{username}@fornacast.invalid",
      password_hash: "organization-account",
      kind: :organization,
      state: :active
    })
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(reset_tables(), &SQL.query!(Repo, "delete from #{&1}", []))
    end
  end

  defp reset_tables do
    [
      "github_credentials",
      "github_identities",
      "audit_events",
      "repository_collaborators",
      "repositories",
      "organization_members",
      "api_keys",
      "ssh_keys",
      "users"
    ]
  end

  defp prepare_independent_concurrency! do
    if postgres?() do
      SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(AuditEvent)
        Repo.delete_all(GitHubCredential)
        Repo.delete_all(GitHubIdentity)
      end)

      on_exit(fn ->
        SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(AuditEvent)
          Repo.delete_all(GitHubCredential)
          Repo.delete_all(GitHubIdentity)
        end)
      end)
    end
  end

  defp run_independent_workers(inputs, worker) do
    parent = self()
    ready_ref = make_ref()

    tasks =
      for input <- inputs do
        Task.async(fn ->
          backend_pid = independent_checkout!()
          send(parent, {ready_ref, self(), backend_pid})

          receive do
            {:go, ^ready_ref} ->
              try do
                worker.(input)
              after
                independent_checkin!()
              end
          end
        end)
      end

    backend_pids =
      Enum.map(tasks, fn task ->
        receive do
          {^ready_ref, worker_pid, backend_pid} when worker_pid == task.pid -> backend_pid
        after
          15_000 -> flunk("independent lifecycle worker did not reach the start barrier")
        end
      end)

    if postgres?(), do: assert(MapSet.size(MapSet.new(backend_pids)) > 1)

    Enum.each(tasks, &send(&1.pid, {:go, ready_ref}))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end

  defp independent_checkout! do
    if postgres?() do
      :ok = SQL.Sandbox.checkout(Repo, sandbox: false)
      %{rows: [[backend_pid]]} = SQL.query!(Repo, "select pg_backend_pid()", [])
      backend_pid
    end
  end

  defp independent_checkin! do
    if postgres?(), do: :ok = SQL.Sandbox.checkin(Repo)
  end

  defp independent_get_by!(schema, criteria) do
    if postgres?(),
      do: SQL.Sandbox.unboxed_run(Repo, fn -> Repo.get_by!(schema, criteria) end),
      else: Repo.get_by!(schema, criteria)
  end

  defp independent_get_by(schema, criteria) do
    if postgres?(),
      do: SQL.Sandbox.unboxed_run(Repo, fn -> Repo.get_by(schema, criteria) end),
      else: Repo.get_by(schema, criteria)
  end

  defp independent_call(callback) do
    if postgres?(), do: SQL.Sandbox.unboxed_run(Repo, callback), else: callback.()
  end

  defp independent_saved_account(actor, github_user_id, login, pat) do
    independent_call(fn ->
      ForgeAccounts.save_github_account(
        actor,
        profile(github_user_id, login),
        pat,
        %{operation_id: "race-seed-#{github_user_id}"}
      )
    end)
  end

  defp independent_user_fixture(username) do
    if postgres?() do
      actor = SQL.Sandbox.unboxed_run(Repo, fn -> user_fixture(username) end)

      on_exit(fn ->
        SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from(user in User, where: user.id == ^actor.id))
        end)
      end)

      actor
    else
      user_fixture(username)
    end
  end

  defp independent_count(schema) do
    if postgres?(),
      do: SQL.Sandbox.unboxed_run(Repo, fn -> Repo.aggregate(schema, :count, :id) end),
      else: Repo.aggregate(schema, :count, :id)
  end

  defp independent_action_count(action) do
    independent_call(fn ->
      Repo.aggregate(from(event in AuditEvent, where: event.action == ^action), :count, :id)
    end)
  end

  defp independent_with_github_credential(actor, identity_id) do
    parent = self()
    digest_ref = make_ref()

    result =
      independent_call(fn ->
        ForgeAccounts.with_github_credential(actor, identity_id, fn pat ->
          send(parent, {digest_ref, credential_digest(pat)})
          :ok
        end)
      end)

    case result do
      {:ok, :ok} ->
        receive do
          {^digest_ref, digest} -> {:ok, digest}
        after
          1_000 -> flunk("successful credential checkout omitted its test digest")
        end

      {:error, _reason} = error ->
        refute_received {^digest_ref, _digest}
        error
    end
  end

  defp start_blocked_checkout(actor, identity_id) do
    parent = self()
    ready_ref = make_ref()
    release_ref = make_ref()

    checkout =
      Task.async(fn ->
        independent_checkout!()

        try do
          ForgeAccounts.with_github_credential(actor, identity_id, fn pat ->
            digest = credential_digest(pat)
            send(parent, {ready_ref, self(), digest})

            receive do
              {:release_checkout, ^release_ref} -> :ok
            after
              30_000 -> raise "checkout release timed out"
            end
          end)
        after
          independent_checkin!()
        end
      end)

    digest =
      receive do
        {^ready_ref, checkout_pid, digest} when checkout_pid == checkout.pid -> digest
      after
        15_000 -> flunk("credential checkout did not reach the revocation barrier")
      end

    {checkout, release_ref, digest}
  end

  defp assert_saved_pat(actor, identity_id, expected_pat) do
    expected_digest = credential_digest(expected_pat)
    digest_ref = make_ref()

    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential(actor, identity_id, fn pat ->
               send(self(), {digest_ref, credential_digest(pat)})
               :ok
             end)

    assert_receive {^digest_ref, ^expected_digest}
  end

  defp credential_digest(pat), do: :crypto.hash(:sha256, pat)

  defp action_count(action) do
    Repo.aggregate(from(event in AuditEvent, where: event.action == ^action), :count, :id)
  end

  defp postgres?,
    do: Application.get_env(:fornacast, :database_adapter) in ["postgres", "postgresql"]

  defp turso?, do: not postgres?()
end
