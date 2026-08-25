defmodule ForgeImports.GitHubAccountLinkConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeAccounts.{GitHubCredential, GitHubIdentity}
  alias ForgeImports.GitHub.User, as: GitHubUser
  alias Fornacast.{AuditEvent, Repo}

  @seed_pat "link-seed-token"
  @winner_pat "link-winner-token"
  @stale_pat "link-stale-token"

  defmodule BlockingClient do
    def authenticated_user(_pat, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      tag = Keyword.fetch!(opts, :tag)
      send(test_pid, {:link_verification_started, tag, self()})

      receive do
        {:release_link_verification, ^tag} -> Keyword.fetch!(opts, :response)
      after
        30_000 -> raise "link verification release timed out"
      end
    end
  end

  setup do
    database_run(&reset_database!/0)
    on_exit(fn -> database_run(&reset_database!/0) end)
    %{actor: database_run(&user_fixture/0)}
  end

  test "an older verified link cannot overwrite a newer explicit replacement", %{actor: actor} do
    account = database_run(fn -> saved_account!(actor, @seed_pat, "seed") end)
    stale = start_link(actor, account.github_user_id, "stale", @stale_pat, "stale-link")
    assert_receive {:link_verification_started, "stale-link", stale_pid}
    assert stale_pid == stale.pid

    assert {:ok, winner} =
             database_run(fn ->
               ForgeAccounts.replace_github_credential(
                 actor,
                 account.identity_id,
                 profile(account.github_user_id, "winner"),
                 @winner_pat,
                 %{operation_id: "winning-explicit-replace"}
               )
             end)

    assert winner.login == "winner"
    send(stale.pid, {:release_link_verification, "stale-link"})
    assert {:error, :stale} = Task.await(stale, 30_000)

    assert_final_account(actor, account.identity_id, "winner", @winner_pat)
    refute_operation("stale-link")
    assert_operation("winning-explicit-replace", "github.credential.replaced")
  end

  test "an older verified link cannot overwrite a deleted and re-saved credential", %{
    actor: actor
  } do
    account = database_run(fn -> saved_account!(actor, @seed_pat, "seed") end)
    original = database_run(fn -> credential(account.identity_id) end)
    stale = start_link(actor, account.github_user_id, "stale", @stale_pat, "stale-resave")
    assert_receive {:link_verification_started, "stale-resave", stale_pid}
    assert stale_pid == stale.pid

    database_run(fn ->
      assert {:ok, _deleted} =
               ForgeAccounts.delete_github_credential(
                 actor,
                 account.identity_id,
                 %{operation_id: "delete-before-link-resave"}
               )

      assert {:ok, _resaved} =
               ForgeAccounts.save_github_account(
                 actor,
                 profile(account.github_user_id, "resaved"),
                 @winner_pat,
                 %{operation_id: "winning-link-resave"}
               )
    end)

    send(stale.pid, {:release_link_verification, "stale-resave"})
    assert {:error, :stale} = Task.await(stale, 30_000)

    final = database_run(fn -> credential(account.identity_id) end)
    assert final.nonce != original.nonce
    assert final.ciphertext != original.ciphertext
    assert_final_account(actor, account.identity_id, "resaved", @winner_pat)
    refute_operation("stale-resave")
    assert_operation("winning-link-resave", "github.credential.replaced")
  end

  test "only one first-link snapshot may create the account credential", %{actor: actor} do
    github_user_id = 9_880_000_001
    older = start_link(actor, github_user_id, "older", @stale_pat, "older-first-link")
    assert_receive {:link_verification_started, "older-first-link", older_pid}
    assert older_pid == older.pid

    newer = start_link(actor, github_user_id, "newer", @winner_pat, "newer-first-link")
    assert_receive {:link_verification_started, "newer-first-link", newer_pid}
    assert newer_pid == newer.pid

    send(newer.pid, {:release_link_verification, "newer-first-link"})
    assert {:ok, winner} = Task.await(newer, 30_000)

    send(older.pid, {:release_link_verification, "older-first-link"})
    assert {:error, :stale} = Task.await(older, 30_000)

    assert_final_account(actor, winner.identity_id, "newer", @winner_pat)
    refute_operation("older-first-link")
    assert_operation("newer-first-link", "github.account.linked")
    assert database_run(fn -> Repo.aggregate(AuditEvent, :count, :id) end) == 1
  end

  test "a link loses when a concurrently added account owns its metadata secret", %{
    actor: actor
  } do
    target_github_user_id = 9_880_000_011
    other_github_user_id = 9_880_000_012
    other_pat = "concurrently-added-account-token"

    stale =
      start_link(
        actor,
        target_github_user_id,
        "must-not-link",
        @stale_pat,
        "stale-after-account-add",
        %{operation_id: "stale-after-account-add", request_id: other_pat}
      )

    assert_receive {:link_verification_started, "stale-after-account-add", stale_pid}
    assert stale_pid == stale.pid

    assert {:ok, other} =
             database_run(fn ->
               ForgeAccounts.save_github_account(
                 actor,
                 profile(other_github_user_id, "concurrent-account"),
                 other_pat,
                 %{operation_id: "concurrent-account-add"}
               )
             end)

    send(stale.pid, {:release_link_verification, "stale-after-account-add"})
    assert {:error, :invalid_request_metadata} = Task.await(stale, 30_000)

    database_run(fn ->
      refute Repo.get_by(GitHubIdentity, github_user_id: target_github_user_id)
      assert Repo.get!(GitHubIdentity, other.identity_id).login == "concurrent-account"

      assert {:ok, :ok} =
               ForgeAccounts.with_github_credential(actor, other.identity_id, fn pat ->
                 assert pat == other_pat
                 :ok
               end)

      refute Repo.get_by(AuditEvent, operation_id: "stale-after-account-add")
      assert Repo.aggregate(AuditEvent, :count, :id) == 1
    end)
  end

  test "a link loses when a concurrently added account owns a provider profile secret", %{
    actor: actor
  } do
    target_github_user_id = 9_880_000_021
    other_github_user_id = 9_880_000_022
    other_pat = "concurrently-added-profile-token"

    unsafe_user =
      github_user(target_github_user_id, "must-not-link")
      |> Map.put(:html_url, "https://github.com/must-not-link/#{other_pat}")

    stale =
      start_link(
        actor,
        target_github_user_id,
        "must-not-link",
        @stale_pat,
        "stale-profile-after-account-add",
        %{operation_id: "stale-profile-after-account-add"},
        unsafe_user
      )

    assert_receive {:link_verification_started, "stale-profile-after-account-add", stale_pid}
    assert stale_pid == stale.pid

    assert {:ok, other} =
             database_run(fn ->
               ForgeAccounts.save_github_account(
                 actor,
                 profile(other_github_user_id, "concurrent-profile-account"),
                 other_pat,
                 %{operation_id: "concurrent-profile-account-add"}
               )
             end)

    send(stale.pid, {:release_link_verification, "stale-profile-after-account-add"})
    assert {:error, :invalid_response} = Task.await(stale, 30_000)

    database_run(fn ->
      refute Repo.get_by(GitHubIdentity, github_user_id: target_github_user_id)
      assert Repo.get!(GitHubIdentity, other.identity_id).login == "concurrent-profile-account"

      assert {:ok, :ok} =
               ForgeAccounts.with_github_credential(actor, other.identity_id, fn pat ->
                 assert pat == other_pat
                 :ok
               end)

      refute Repo.get_by(AuditEvent, operation_id: "stale-profile-after-account-add")
      assert Repo.aggregate(AuditEvent, :count, :id) == 1
    end)
  end

  defp start_link(
         actor,
         github_user_id,
         login,
         pat,
         tag,
         metadata \\ nil,
         response_user \\ nil
       ) do
    parent = self()
    metadata = metadata || %{operation_id: tag}
    response_user = response_user || github_user(github_user_id, login)

    Task.async(fn ->
      independent_checkout!()

      try do
        ForgeImports.link_github_account(
          actor,
          pat,
          metadata,
          client: BlockingClient,
          test_pid: parent,
          tag: tag,
          response: {:ok, response_user}
        )
      after
        independent_checkin!()
      end
    end)
  end

  defp assert_final_account(actor, identity_id, login, pat) do
    database_run(fn ->
      assert Repo.get!(GitHubIdentity, identity_id).login == login

      assert {:ok, :ok} =
               ForgeAccounts.with_github_credential(actor, identity_id, fn checked_out ->
                 assert checked_out == pat
                 :ok
               end)
    end)
  end

  defp refute_operation(operation_id) do
    database_run(fn -> refute Repo.get_by(AuditEvent, operation_id: operation_id) end)
  end

  defp assert_operation(operation_id, action) do
    database_run(fn ->
      assert %AuditEvent{action: ^action} =
               Repo.get_by!(AuditEvent, operation_id: operation_id)
    end)
  end

  defp saved_account!(actor, pat, login) do
    {:ok, account} =
      ForgeAccounts.save_github_account(
        actor,
        profile(9_880_000_001, login),
        pat,
        %{operation_id: "link-race-seed"}
      )

    account
  end

  defp credential(identity_id) do
    Repo.get_by!(GitHubCredential, github_identity_id: identity_id)
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

  defp profile(id, login) do
    %{
      github_user_id: id,
      login: login,
      avatar_url: "https://avatars.githubusercontent.com/u/#{id}",
      profile_url: "https://github.com/#{login}"
    }
  end

  defp user_fixture do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "link-race-user-#{suffix}",
        email: "link-race-user-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    user
  end

  defp independent_checkout! do
    if postgres?(), do: :ok = SQL.Sandbox.checkout(Repo, sandbox: false)
  end

  defp independent_checkin! do
    if postgres?(), do: :ok = SQL.Sandbox.checkin(Repo)
  end

  defp database_run(callback) do
    if postgres?(), do: SQL.Sandbox.unboxed_run(Repo, callback), else: callback.()
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
