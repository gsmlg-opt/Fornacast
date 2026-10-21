defmodule ForgeImports.SavedDeviceCredentialsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ForgeAccounts.{GitHubCredential, User}
  alias ForgeGitHub.{MirrorCredential, SavedCredential}
  alias ForgeImports.{CredentialProvider, ImportRun, Persistence}
  alias Fornacast.{OperationLease, Repo}

  setup {Req.Test, :verify_on_exit!}

  setup do
    :ok = SQL.Sandbox.checkout(Repo, sandbox: false)
    reset_database!()
    on_exit(fn -> SQL.Sandbox.unboxed_run(Repo, &reset_database!/0) end)
    suffix = System.unique_integer([:positive])

    actor =
      Repo.insert!(%User{
        username: "device-consumer-#{suffix}",
        email: "device-consumer-#{suffix}@test.local",
        password_hash: "unused",
        kind: :user,
        role: :user,
        state: :active
      })

    token = %{
      client_id: "original-device-client",
      access_token: "old-device-access",
      refresh_token: "old-device-refresh",
      expires_at: DateTime.add(DateTime.utc_now(:second), 30),
      refresh_expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
    }

    {:ok, account} =
      ForgeAccounts.save_github_device_account(
        actor,
        %{github_user_id: 9_000_000_001, login: "octocat"},
        token,
        %{}
      )

    credential = Repo.get_by!(GitHubCredential, github_identity_id: account.identity_id)
    %{actor: actor, account: account, credential: credential}
  end

  test "saved checkout renews through the provider using the stored client binding", c do
    opts = refresh_options()

    assert {:ok, :ok} =
             SavedCredential.with_credential(
               c.actor,
               c.account.identity_id,
               fn access ->
                 assert access == "renewed-device-access"
                 :ok
               end,
               opts
             )

    assert {:ok, :ok} =
             SavedCredential.with_credential(
               c.actor,
               c.account.identity_id,
               fn _ -> :ok end,
               opts
             )

    current = Repo.get!(GitHubCredential, c.credential.id)
    assert current.verification_version == c.credential.verification_version
    assert current.token_generation == c.credential.token_generation + 1
  end

  test "saved import checkout receives the renewed access token and keeps callback acknowledgments",
       c do
    run = run(c)

    assert {:ok, :acknowledged} =
             CredentialProvider.checkout(
               %{actor: c.actor, run: run, capability: run},
               fn access, metadata ->
                 assert access == "renewed-device-access"
                 assert metadata.gate_key == {:saved_credential, c.credential.id}
                 :ok
               end,
               refresh_options()
             )
  end

  test "mirror checkout retains its pinned authorization version after renewal", c do
    scope = %{
      credential_source: :pat,
      credential_owner_user_id: c.actor.id,
      github_identity_id: c.account.identity_id,
      github_credential_id: c.credential.id,
      github_credential_version: c.credential.verification_version
    }

    opts = Keyword.put(refresh_options(), :pat_authorize, fn ^scope -> :ok end)

    assert :ok =
             MirrorCredential.with_token(scope, %{}, opts, fn access ->
               assert access == "renewed-device-access"
               {:ok, :durable_result}
             end)

    assert Repo.get!(GitHubCredential, c.credential.id).verification_version ==
             scope.github_credential_version
  end

  test "invalid refresh stops imports and reports a credential requiring replacement", c do
    run = run(c)

    assert {:error, :invalid_credential} =
             CredentialProvider.checkout(
               %{actor: c.actor, run: run, capability: run},
               fn _, _ -> flunk("provider used invalid refresh") end,
               refresh_options(%{"error" => "bad_refresh_token"})
             )

    assert {:ok, [view]} = ForgeAccounts.list_github_accounts(c.actor)
    assert view.reconnect_required
  end

  test "renewal failure remains an explicit reconnect error at the coordinator boundary", c do
    assert {:error, :reauthorization_required} =
             SavedCredential.with_credential(
               c.actor,
               c.account.identity_id,
               fn _ -> flunk("provider used invalid credential") end,
               refresh_options(%{"error" => "bad_refresh_token"})
             )
  end

  test "unsafe callback results cannot cross the coordinator", c do
    assert {:error, :unsafe_credential_result} =
             SavedCredential.with_credential(
               c.actor,
               c.account.identity_id,
               fn access -> {:ok, access} end,
               refresh_options()
             )
  end

  test "independent checkouts wait for one refresh and use its rotated token", c do
    parent = self()

    options =
      refresh_options(token_response(), fn ->
        send(parent, {:refresh_waiting, self()})

        receive do
          :complete_refresh -> :ok
        after
          5_000 -> flunk("refresh was not released")
        end
      end)

    first =
      Task.async(fn ->
        :ok = SQL.Sandbox.checkout(Repo, sandbox: false)

        try do
          SavedCredential.with_credential(
            c.actor,
            c.account.identity_id,
            fn token ->
              assert token == "renewed-device-access"
              :ok
            end,
            options
          )
        after
          SQL.Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:refresh_waiting, worker}, 1_000
    Process.send_after(worker, :complete_refresh, 150)

    assert {:ok, :ok} =
             SavedCredential.with_credential(
               c.actor,
               c.account.identity_id,
               fn token ->
                 assert token == "renewed-device-access"
                 :ok
               end,
               options
             )

    assert {:ok, :ok} = Task.await(first)

    assert Repo.get!(GitHubCredential, c.credential.id).token_generation ==
             c.credential.token_generation + 1
  end

  test "an import losing its lease during refresh cannot reach the provider", c do
    run = run(c)

    opts =
      refresh_options(token_response(), fn ->
        SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.update_all(from(r in ImportRun, where: r.id == ^run.id),
            set: [lease_owner: "new-lease-owner"],
            inc: [lock_version: 1]
          )
        end)
      end)

    assert {:error, :credential_changed} =
             CredentialProvider.checkout(
               %{actor: c.actor, run: run, capability: run},
               fn _, _ -> flunk("lost lease used provider") end,
               opts
             )
  end

  test "account reverification renews before /user", c do
    opts = refresh_options() |> Keyword.merge(client: __MODULE__.Client, test_pid: self())

    assert {:ok, view} =
             ForgeImports.GitHubAccounts.reverify(c.actor, c.account.identity_id, %{}, opts)

    assert view.credential_kind == :github_app_user
    assert_receive :renewed_authenticated_user
  end

  test "organization discovery renews the saved connection before requesting inventory", c do
    suffix = System.unique_integer([:positive])

    {:ok, org} =
      ForgeAccounts.create_organization(c.actor, %{username: "device-inventory-#{suffix}"})

    {:ok, _} =
      ForgeMirrors.PatSettings.save(
        c.actor,
        org.id,
        %{
          "owner_user_id" => to_string(c.actor.id),
          "github_identity_id" => to_string(c.account.identity_id),
          "github_organization" => "acme",
          "enabled" => "true",
          "lock_version" => "1"
        },
        %{}
      )

    opts = Keyword.put(refresh_options(), :client, __MODULE__.Client)

    assert {:ok, %{repository_count: 0}} =
             ForgeImports.OrganizationPatSettings.check(c.actor, org.id, opts)
  end

  defmodule Client do
    def authenticated_user("renewed-device-access", opts) do
      send(Keyword.fetch!(opts, :test_pid), :renewed_authenticated_user)
      {:ok, %ForgeGitHub.User{id: 9_000_000_001, login: "octocat"}}
    end

    def organization_repositories("renewed-device-access", "acme", _opts), do: {:ok, []}
  end

  defp refresh_options(
         response \\ token_response(),
         before_response \\ fn -> :ok end
       ) do
    stub = {__MODULE__, make_ref()}

    Req.Test.expect(stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/login/oauth/access_token"

      assert URI.decode_query(body) == %{
               "client_id" => "original-device-client",
               "refresh_token" => "old-device-refresh",
               "grant_type" => "refresh_token"
             }

      before_response.()
      Req.Test.json(conn, response)
    end)

    [device_flow_options: [plug: {Req.Test, stub}, client_id: "must-be-overridden"]]
  end

  defp token_response do
    %{
      "access_token" => "renewed-device-access",
      "refresh_token" => "renewed-device-refresh",
      "token_type" => "bearer",
      "expires_in" => 28_800,
      "refresh_token_expires_in" => 15_897_600
    }
  end

  defp run(c) do
    {:ok, run} =
      Persistence.insert_run(%{
        actor_user_id: c.actor.id,
        source_kind: :organization,
        github_identity_id: c.account.identity_id,
        credential_source: :saved,
        github_credential_id: c.credential.id,
        source_owner_github_id: 9_500_000_001,
        source_owner_login: "acme",
        state: :discovering,
        request_metadata: %{}
      })

    {:ok, claimed} =
      OperationLease.claim(
        ImportRun,
        run.id,
        "device-consumer-test",
        DateTime.utc_now(:second),
        60
      )

    claimed
  end

  defp reset_database! do
    for table <- [
          "github_import_report_entries",
          "github_import_page_checkpoints",
          "github_import_object_mappings",
          "github_import_attempts",
          "github_import_repository_items",
          "github_import_runs",
          "organization_pat_configurations",
          "github_credentials",
          "github_identities",
          "audit_events",
          "repository_collaborators",
          "repositories",
          "organization_members",
          "api_keys",
          "ssh_keys",
          "users"
        ],
        do: SQL.query!(Repo, "delete from #{table}", [])
  end
end
