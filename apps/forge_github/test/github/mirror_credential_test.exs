defmodule ForgeGitHub.MirrorCredentialTest do
  use ExUnit.Case, async: true

  alias ForgeAccounts.GitHubCredentialVerification
  alias ForgeGitHub.{InstallationToken, MirrorCredential}

  test "PAT checkout is callback scoped and freshly authorizes the pinned credential" do
    parent = self()
    scope = scope()
    options = options(parent)

    assert :ok =
             MirrorCredential.with_token(scope, %{}, options, fn "saved-secret" ->
               send(parent, :provider_called)
               :ok
             end)

    assert_receive :authorized
    assert_receive :checkout
    assert_receive :authorized
    assert_receive :provider_called
    assert MirrorCredential.gate_key(scope) == {:saved_credential, 8}
  end

  test "rotation or a revoked authority prevents using a checked out token" do
    parent = self()

    assert {:error, :credential_unavailable} =
             MirrorCredential.with_token(
               scope(),
               %{},
               Keyword.put(options(parent), :pat_checkout, fn _scope, callback ->
                 {:ok, callback.("rotated-secret", %{reference() | verification_version: 4})}
               end),
               fn _ -> flunk("rotated token used") end
             )

    assert {:error, :revoked} =
             MirrorCredential.with_token(
               scope(),
               %{},
               Keyword.put(options(parent), :pat_authorize, fn _ -> {:error, :revoked} end),
               fn _ -> flunk("revoked token used") end
             )
  end

  test "authority lost during checkout prevents the provider callback" do
    scope = scope()
    parent = self()
    key = {__MODULE__, :authority_check}

    options =
      Keyword.put(options(parent), :pat_authorize, fn _ ->
        case Process.get(key) do
          nil ->
            Process.put(key, true)
            :ok

          true ->
            {:error, :revoked}
        end
      end)

    assert {:error, :revoked} =
             MirrorCredential.with_token(scope, %{}, options, fn _ ->
               flunk("authority changed during checkout")
             end)
  end

  test "App token_fetch injection remains compatible" do
    assert {:ok, :observed} =
             MirrorCredential.with_token(
               %{github_installation_id: 44},
               %{permissions: %{"contents" => "write"}},
               [
                 token_fetch: fn 44, %{permissions: %{"contents" => "write"}} ->
                   %InstallationToken{
                     token: "app-secret",
                     permissions: %{},
                     expires_at: ~U[2026-10-19 12:00:00Z]
                   }
                 end
               ],
               fn "app-secret" -> {:ok, :observed} end
             )
  end

  defp scope do
    %{
      credential_source: :pat,
      github_installation_id: nil,
      github_credential_id: 8,
      github_identity_id: 6,
      github_credential_version: 3,
      credential_owner_user_id: 2
    }
  end

  defp reference do
    %GitHubCredentialVerification{
      credential_id: 8,
      identity_id: 6,
      local_user_id: 2,
      verification_version: 3,
      generation_digest: <<0::256>>
    }
  end

  defp options(parent) do
    [
      pat_authorize: fn _ ->
        send(parent, :authorized)
        :ok
      end,
      pat_checkout: fn _scope, callback ->
        send(parent, :checkout)
        {:ok, callback.("saved-secret", reference())}
      end
    ]
  end
end
