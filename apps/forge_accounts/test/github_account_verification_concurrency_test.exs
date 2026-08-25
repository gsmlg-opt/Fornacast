defmodule ForgeAccounts.GitHubAccountVerificationConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias ForgeAccounts.{GitHubCredential, GitHubIdentity}
  alias Fornacast.{AuditEvent, Repo}

  @old_pat "github_pat_verification_old"
  @new_pat "github_pat_verification_new"

  setup do
    database_run(&reset_database!/0)
    on_exit(fn -> database_run(&reset_database!/0) end)

    {actor, account} =
      database_run(fn ->
        actor = user_fixture("verification-race")

        {:ok, account} =
          ForgeAccounts.save_github_account(
            actor,
            profile(9_000_000_001, "octocat-old"),
            @old_pat,
            %{operation_id: "verification-race-seed"}
          )

        {actor, account}
      end)

    %{actor: actor, account: account}
  end

  test "a replacement makes an in-flight invalidation reference stale", context do
    verification = start_verification(context, :invalidate)
    assert_receive {:verification_checked_out, verification_pid, old_version}
    assert verification_pid == verification.pid

    assert {:ok, replacement} = replace_account(context, "replace-before-invalidate")
    assert replacement.login == "octocat-new"
    send(verification.pid, :apply_verification)

    assert {:ok, {:error, :stale}} = Task.await(verification, 30_000)
    assert_final_replacement(context, old_version)
    refute_operation("stale-invalidation")
  end

  test "a replacement makes an in-flight successful refresh reference stale", context do
    verification = start_verification(context, :refresh)
    assert_receive {:verification_checked_out, verification_pid, old_version}
    assert verification_pid == verification.pid

    assert {:ok, replacement} = replace_account(context, "replace-before-refresh")
    assert replacement.login == "octocat-new"
    send(verification.pid, :apply_verification)

    assert {:ok, {:error, :stale}} = Task.await(verification, 30_000)
    assert_final_replacement(context, old_version)
    refute_operation("stale-refresh")
  end

  test "a verified replacement cannot overwrite a newer replacement", context do
    reference = account_reference(context)
    stale = start_stale_replacement(context, reference, "stale-replacement")
    assert_receive {:stale_replacement_ready, stale_pid}
    assert stale_pid == stale.pid

    assert {:ok, _replacement} = replace_account(context, "newer-replacement")
    send(stale.pid, :persist_stale_replacement)

    assert {:error, :stale} = Task.await(stale, 30_000)
    assert_final_replacement(context, reference.verification_version)
    refute_operation("stale-replacement")
  end

  test "a verified replacement cannot overwrite a deleted and re-saved credential row", context do
    reference = account_reference(context)
    stale = start_stale_replacement(context, reference, "stale-after-resave")
    assert_receive {:stale_replacement_ready, stale_pid}
    assert stale_pid == stale.pid

    database_run(fn ->
      assert {:ok, _deleted} =
               ForgeAccounts.delete_github_credential(
                 context.actor,
                 context.account.identity_id,
                 %{operation_id: "delete-before-resave"}
               )

      assert {:ok, _resaved} =
               ForgeAccounts.save_github_account(
                 context.actor,
                 profile(9_000_000_001, "octocat-new"),
                 @new_pat,
                 %{operation_id: "resave-before-stale"}
               )
    end)

    send(stale.pid, :persist_stale_replacement)
    assert {:error, :stale} = Task.await(stale, 30_000)

    database_run(fn ->
      {:ok, current_account} =
        ForgeAccounts.github_account_reference(context.actor, context.account.identity_id)

      assert current_account.credential.generation_digest != reference.generation_digest
      assert_current_pat(context, @new_pat)
      refute Repo.get_by(AuditEvent, operation_id: "stale-after-resave")
    end)
  end

  defp start_verification(context, action) do
    parent = self()

    Task.async(fn ->
      independent_checkout!()

      try do
        ForgeAccounts.with_github_credential_for_verification(
          context.actor,
          context.account.identity_id,
          fn pat, reference ->
            assert pat == @old_pat

            send(
              parent,
              {:verification_checked_out, self(), reference.verification_version}
            )

            receive do
              :apply_verification -> apply_verification(context, action, reference)
            after
              30_000 -> raise "verification release timed out"
            end
          end
        )
      after
        independent_checkin!()
      end
    end)
  end

  defp apply_verification(context, :invalidate, reference) do
    case ForgeAccounts.mark_github_credential_invalid(
           context.actor,
           context.account.identity_id,
           reference,
           %{operation_id: "stale-invalidation"}
         ) do
      {:ok, _view} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_verification(context, :refresh, reference) do
    case ForgeAccounts.refresh_github_account_if_current(
           context.actor,
           context.account.identity_id,
           reference,
           profile(9_000_000_001, "stale-refresh"),
           %{operation_id: "stale-refresh"}
         ) do
      {:ok, _view} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_account(context, operation_id) do
    database_run(fn ->
      ForgeAccounts.replace_github_credential(
        context.actor,
        context.account.identity_id,
        profile(9_000_000_001, "octocat-new"),
        @new_pat,
        %{operation_id: operation_id}
      )
    end)
  end

  defp account_reference(context) do
    database_run(fn ->
      {:ok, account_reference} =
        ForgeAccounts.github_account_reference(context.actor, context.account.identity_id)

      account_reference.credential
    end)
  end

  defp start_stale_replacement(context, reference, operation_id) do
    parent = self()

    Task.async(fn ->
      independent_checkout!()

      try do
        send(parent, {:stale_replacement_ready, self()})

        receive do
          :persist_stale_replacement ->
            ForgeAccounts.replace_github_credential_if_current(
              context.actor,
              context.account.identity_id,
              reference,
              profile(9_000_000_001, "must-not-win"),
              "github_pat_must_not_win",
              %{operation_id: operation_id}
            )
        after
          30_000 -> raise "stale replacement release timed out"
        end
      after
        independent_checkin!()
      end
    end)
  end

  defp assert_final_replacement(context, old_version) do
    database_run(fn ->
      credential =
        Repo.get_by!(GitHubCredential, github_identity_id: context.account.identity_id)

      identity = Repo.get!(GitHubIdentity, context.account.identity_id)
      assert credential.status == :valid
      assert credential.verification_version > old_version
      assert identity.login == "octocat-new"

      assert_current_pat(context, @new_pat)
    end)
  end

  defp assert_current_pat(context, expected) do
    assert {:ok, :ok} =
             ForgeAccounts.with_github_credential(
               context.actor,
               context.account.identity_id,
               fn pat ->
                 assert pat == expected
                 :ok
               end
             )
  end

  defp refute_operation(operation_id) do
    database_run(fn -> refute Repo.get_by(AuditEvent, operation_id: operation_id) end)
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

  defp profile(id, login) do
    %{
      github_user_id: id,
      login: login,
      avatar_url: "https://avatars.githubusercontent.com/u/#{id}",
      profile_url: "https://github.com/#{login}"
    }
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
