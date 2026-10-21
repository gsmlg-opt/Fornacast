defmodule ForgeImports.GitHubDeviceAccountsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForgeAccounts.{GitHubCredential, GitHubIdentity, User}
  alias ForgeGitHub.DeviceFlow.Token
  alias ForgeGitHub.User, as: GitHubUser
  alias Fornacast.{AuditEvent, Repo}

  defmodule StubClient do
    def authenticated_user(_access, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:client_options, opts})
      Keyword.fetch!(opts, :response)
    end
  end

  defmodule LeakyClient do
    def authenticated_user(access, opts), do: raise(Keyword.get(opts, :leak, access))
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    suffix = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "device-import-#{suffix}",
        email: "device-import-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, checked} = ForgeAccounts.validate_github_link_request(actor, %{})
    %{actor: actor, references: checked.references, token: token()}
  end

  test "verifies /user through the REST gate and encrypts the client-bound tokens", ctx do
    stub = {__MODULE__, make_ref()}
    owner = self()

    Req.Test.expect(stub, fn conn ->
      assert conn.request_path == "/user"
      assert conn.method == "GET"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer " <> ctx.token.access_token
             ]

      send(owner, :profile_verified)

      Req.Test.json(conn, %{
        "id" => 9_976_101,
        "login" => "device-octocat",
        "node_id" => "U_device"
      })
    end)

    before_save = fn ->
      assert_received :profile_verified
      send(owner, :before_save)
      :ok
    end

    assert {:ok, view} =
             ForgeImports.link_github_device_account(ctx.actor, ctx.token, %{}, ctx.references,
               plug: {Req.Test, stub},
               resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end,
               before_save: before_save
             )

    assert_received :before_save
    assert view.github_user_id == 9_976_101
    assert view.credential_kind == :github_app_user
    credential = Repo.get_by!(GitHubCredential, github_identity_id: view.identity_id)
    identity = Repo.get!(GitHubIdentity, view.identity_id)
    assert credential.client_id == ctx.token.client_id
    refute credential.ciphertext == ctx.token.access_token
    refute credential.refresh_ciphertext == ctx.token.refresh_token

    assert {:ok, :ok} =
             ForgeAccounts.GitHubCredentialVault.with_saved_secrets(
               credential,
               identity,
               fn access, refresh ->
                 assert access == ctx.token.access_token
                 assert refresh == ctx.token.refresh_token
                 :ok
               end
             )

    for value <- [view, Repo.all(AuditEvent)] do
      refute inspect(value) =~ ctx.token.access_token
      refute inspect(value) =~ ctx.token.refresh_token
    end
  end

  test "never forwards the before-save callback and overrides a supplied gate", ctx do
    assert {:ok, _view} =
             link(ctx, before_save: fn -> :ok end, gate_key: {:unsafe, ctx.token.refresh_token})

    assert_received {:client_options, options}
    refute Keyword.has_key?(options, :before_save)
    assert options[:gate_key] == {:account_setup, ctx.actor.id}
  end

  test "rejects either token in request metadata before HTTP", ctx do
    for secret <- [ctx.token.access_token, ctx.token.refresh_token] do
      assert {:error, :invalid_request_metadata} =
               ForgeImports.link_github_device_account(
                 ctx.actor,
                 ctx.token,
                 %{request_id: secret},
                 ctx.references,
                 options()
               )
    end

    refute_received {:client_options, _}
    assert [] = Repo.all(GitHubCredential)
  end

  test "rejects either token reflected in any public profile field", ctx do
    for secret <- [ctx.token.access_token, ctx.token.refresh_token],
        field <- [:login, :name, :node_id] do
      assert {:error, :invalid_response} =
               link(ctx, response: {:ok, Map.put(user(), field, secret)})
    end

    assert [] = Repo.all(GitHubCredential)
  end

  test "the start snapshot cannot overwrite a credential added before completion", ctx do
    {:ok, winner} =
      ForgeAccounts.save_github_account(ctx.actor, profile(), "winning-manual-token", %{})

    saved = Repo.get_by!(GitHubCredential, github_identity_id: winner.identity_id)
    assert {:error, :stale} = link(ctx)
    assert Repo.get!(GitHubCredential, saved.id) == saved
  end

  test "the start snapshot cannot overwrite a newer replacement", ctx do
    {:ok, winner} =
      ForgeAccounts.save_github_account(ctx.actor, profile(), "initial-manual-token", %{})

    {:ok, checked} = ForgeAccounts.validate_github_link_request(ctx.actor, %{})

    {:ok, _updated} =
      ForgeAccounts.replace_github_credential(
        ctx.actor,
        winner.identity_id,
        profile(),
        "newer-manual-token",
        %{}
      )

    saved = Repo.get_by!(GitHubCredential, github_identity_id: winner.identity_id)
    assert {:error, :stale} = link(%{ctx | references: checked.references})
    assert Repo.get!(GitHubCredential, saved.id) == saved
  end

  test "cancellation checked after HTTP prevents saving or audit", ctx do
    before_save = fn ->
      assert_received {:client_options, _}
      {:error, :stale}
    end

    before_audits = Repo.aggregate(AuditEvent, :count)
    assert {:error, :stale} = link(ctx, before_save: before_save)
    assert [] = Repo.all(GitHubCredential)
    assert Repo.aggregate(AuditEvent, :count) == before_audits
  end

  test "sanitizes exceptions containing either token", ctx do
    for secret <- [ctx.token.access_token, ctx.token.refresh_token] do
      log =
        capture_log(fn ->
          error =
            assert_raise ForgeImports.GitHubDeviceAccounts.CredentialVerificationError, fn ->
              link(ctx, client: LeakyClient, leak: secret)
            end

          refute Exception.message(error) =~ secret
        end)

      refute log =~ secret
    end

    assert [] = Repo.all(GitHubCredential)
  end

  test "rejects disabled actors and invalid tokens before HTTP", ctx do
    assert {:error, :invalid_response} = link(%{ctx | token: %{ctx.token | refresh_token: nil}})
    {:ok, _disabled} = ctx.actor |> User.state_changeset(%{state: :disabled}) |> Repo.update()
    assert {:error, :forbidden} = link(ctx)
    refute_received {:client_options, _}
  end

  defp link(ctx, opts \\ []),
    do:
      ForgeImports.link_github_device_account(
        ctx.actor,
        ctx.token,
        %{},
        ctx.references,
        Keyword.merge(options(), opts)
      )

  defp options, do: [client: StubClient, test_pid: self(), response: {:ok, user()}]

  defp user,
    do: %GitHubUser{
      id: 9_976_101,
      node_id: "U_device",
      login: "device-octocat",
      name: "Device User"
    }

  defp profile, do: %{github_user_id: 9_976_101, login: "device-octocat", name: "Device User"}

  defp token do
    now = DateTime.utc_now(:second)

    %Token{
      client_id: "Iv23lizCVE3E24s7fCA0",
      access_token: "device-import-access-secret",
      refresh_token: "device-import-refresh-secret",
      expires_at: DateTime.add(now, 3600),
      refresh_expires_at: DateTime.add(now, 86_400)
    }
  end
end
