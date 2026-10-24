defmodule ForgeAccounts.OrganizationGitHubCredentialsTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  alias ForgeAccounts.{
    GitHubCredentialVault,
    OrganizationGitHubCredential,
    OrganizationGitHubCredentials,
    User
  }

  alias Fornacast.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    {:ok, owner} =
      ForgeAccounts.create_user(%{
        username: "org-grant-#{suffix}",
        email: "org-grant-#{suffix}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, organization} =
      ForgeAccounts.create_organization(owner, %{
        username: "grant-org-#{suffix}",
        display_name: "Grant organization"
      })

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from c in OrganizationGitHubCredential, where: c.organization_id == ^organization.id
        )

        Repo.delete_all(from a in Fornacast.AuditEvent, where: a.actor_user_id == ^owner.id)

        Repo.delete_all(
          from m in ForgeAccounts.OrganizationMember, where: m.organization_id == ^organization.id
        )

        Repo.delete_all(from u in User, where: u.id in ^[owner.id, organization.id])
      end)
    end)

    %{owner: owner, organization: organization}
  end

  test "saves independent encrypted grants and fences concurrent initial completion", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
    assert absent.credential_id == nil
    assert {:ok, saved} = save(c, absent)
    assert saved.organization_id == c.organization.id
    assert {:ok, []} = ForgeAccounts.list_github_accounts(c.owner)
    assert {:error, :stale} = save(c, absent)
    credential = Repo.get!(OrganizationGitHubCredential, saved.credential_id)
    refute credential.ciphertext == token().access_token
    refute credential.refresh_ciphertext == token().refresh_token
    refute inspect(credential) =~ token().access_token
    refute inspect(saved) =~ token().refresh_token

    assert {:ok, :ok} =
             OrganizationGitHubCredentials.with_credential(saved, fn access, current ->
               assert access == token().access_token
               assert current.verification_version == saved.verification_version
               :ok
             end)
  end

  test "membership removal fences an uncommitted authorization", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    Repo.delete_all(
      from m in ForgeAccounts.OrganizationMember, where: m.organization_id == ^c.organization.id
    )

    assert {:error, :forbidden} = save(c, absent)
  end

  test "ordinary members cannot inspect or finish organization grants", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    membership =
      Repo.get_by!(ForgeAccounts.OrganizationMember,
        organization_id: c.organization.id,
        user_id: c.owner.id
      )

    Repo.update!(Ecto.Changeset.change(membership, role: :member))

    assert {:error, :forbidden} =
             OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    assert {:error, :forbidden} = save(c, absent)
  end

  test "committed grant remains usable after connecting user deactivation", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
    {:ok, saved} = save(c, absent)
    Repo.update!(Ecto.Changeset.change(c.owner, state: :disabled))
    assert {:ok, :ok} = OrganizationGitHubCredentials.with_credential(saved, fn _, _ -> :ok end)

    assert {:error, :forbidden} =
             OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
  end

  test "access/refresh and cross-organization AAD substitution fail closed", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
    {:ok, saved} = save(c, absent)
    credential = Repo.get!(OrganizationGitHubCredential, saved.credential_id)

    swapped = %{
      credential
      | ciphertext: credential.refresh_ciphertext,
        nonce: credential.refresh_nonce,
        tag: credential.refresh_tag,
        key_id: credential.refresh_key_id
    }

    assert {:error, :credential_service_unavailable} =
             GitHubCredentialVault.with_organization_access(swapped, fn _ -> :ok end)

    for replacement <- [
          %{credential | organization_id: c.owner.id},
          %{credential | client_id: "another-client"},
          %{credential | github_user_id: 999}
        ] do
      assert {:error, :credential_service_unavailable} =
               GitHubCredentialVault.with_organization_access(replacement, fn _ -> :ok end)
    end
  end

  test "outer transaction rollback rolls back both credential creation and audit", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    assert {:error, :binding_failed} =
             Repo.transaction(fn ->
               assert {:ok, _} = save(c, absent)
               Repo.rollback(:binding_failed)
             end)

    assert {:ok, %{credential_id: nil}} =
             OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
  end

  test "refresh rotates pair without changing admitted authority", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    {:ok, saved} =
      save(c, absent, token(%{expires_at: DateTime.add(DateTime.utc_now(:second), 30)}))

    assert :ok =
             OrganizationGitHubCredentials.refresh_credential(saved, fn refresh, client ->
               assert refresh == token().refresh_token
               assert client == token().client_id

               assert Repo.get!(OrganizationGitHubCredential, saved.credential_id).refresh_claim_id !=
                        nil

               {:ok,
                token(%{access_token: "rotated-org-access", refresh_token: "rotated-org-refresh"})}
             end)

    current = Repo.get!(OrganizationGitHubCredential, saved.credential_id)
    assert current.token_generation == 2
    assert current.verification_version == saved.verification_version

    assert {:ok, :ok} =
             OrganizationGitHubCredentials.with_credential(saved, fn access, _ ->
               assert access == "rotated-org-access"
               :ok
             end)
  end

  test "ambiguous refresh requires reconnect and cannot replay the refresh token", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    {:ok, saved} =
      save(c, absent, token(%{expires_at: DateTime.add(DateTime.utc_now(:second), 30)}))

    assert {:error, :reauthorization_required} =
             OrganizationGitHubCredentials.refresh_credential(saved, fn _, _ ->
               {:error, :timeout}
             end)

    assert {:error, :stale} =
             OrganizationGitHubCredentials.refresh_credential(saved, fn _, _ ->
               flunk("replayed")
             end)

    assert {:ok, %{status: :invalid}} =
             OrganizationGitHubCredentials.current_reference(c.organization.id)
  end

  test "disconnect during provider refresh fences late token settlement", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    {:ok, saved} =
      save(c, absent, token(%{expires_at: DateTime.add(DateTime.utc_now(:second), 30)}))

    assert {:error, :stale} =
             OrganizationGitHubCredentials.refresh_credential(saved, fn _, _ ->
               assert {:ok, %{status: :invalid}} =
                        OrganizationGitHubCredentials.disconnect_if_current(
                          c.owner,
                          c.organization.id,
                          saved,
                          %{}
                        )

               {:ok, token(%{access_token: "late-access", refresh_token: "late-refresh"})}
             end)

    assert {:error, :stale} =
             OrganizationGitHubCredentials.with_credential(saved, fn _, _ ->
               flunk("stale checkout")
             end)
  end

  test "checkout refuses secret-bearing callback results", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
    {:ok, saved} = save(c, absent)

    assert {:error, :unsafe_credential_result} =
             OrganizationGitHubCredentials.with_credential(saved, fn access, _ ->
               {:ok, access}
             end)
  end

  test "both secret purposes are checked before external profiles can be persisted", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
    {:ok, saved} = save(c, absent)

    assert :ok =
             OrganizationGitHubCredentials.validate_external_profiles(saved, [
               %{login: "safe-name"}
             ])

    for secret <- [token().access_token, token().refresh_token] do
      assert {:error, :invalid_response} =
               OrganizationGitHubCredentials.validate_external_profiles(saved, [
                 %{description: secret}
               ])
    end

    assert_raise OrganizationGitHubCredentials.CallbackError, fn ->
      OrganizationGitHubCredentials.with_credential(saved, fn _, _ ->
        raise "reflected #{token().refresh_token}"
      end)
    end
  end

  test "reconnecting during refresh prevents stale rotation of the new grant", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    {:ok, saved} =
      save(c, absent, token(%{expires_at: DateTime.add(DateTime.utc_now(:second), 30)}))

    assert {:error, :stale} =
             OrganizationGitHubCredentials.refresh_credential(saved, fn _, _ ->
               assert {:ok, replacement} =
                        save(
                          c,
                          saved,
                          token(%{
                            access_token: "reconnected-access",
                            refresh_token: "reconnected-refresh"
                          })
                        )

               assert replacement.verification_version == saved.verification_version + 1
               {:ok, token(%{access_token: "late-access", refresh_token: "late-refresh"})}
             end)

    {:ok, replacement} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    assert {:ok, :ok} =
             OrganizationGitHubCredentials.with_credential(replacement, fn access, _ ->
               assert access == "reconnected-access"
               :ok
             end)
  end

  test "a concurrent refresh observes the durable claim without consuming it", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)

    {:ok, saved} =
      save(c, absent, token(%{expires_at: DateTime.add(DateTime.utc_now(:second), 30)}))

    assert :ok =
             OrganizationGitHubCredentials.refresh_credential(saved, fn _, _ ->
               assert {:error, :refresh_in_progress} =
                        OrganizationGitHubCredentials.refresh_credential(saved, fn _, _ ->
                          flunk("concurrent exchange")
                        end)

               {:ok, token(%{access_token: "next-access", refresh_token: "next-refresh"})}
             end)
  end

  test "abandoned durable claims invalidate instead of replaying refresh", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
    {:ok, saved} = save(c, absent)
    credential = Repo.get!(OrganizationGitHubCredential, saved.credential_id)

    Repo.update!(
      Ecto.Changeset.change(credential,
        refresh_claim_id: Ecto.UUID.generate(),
        refresh_claimed_at: DateTime.add(DateTime.utc_now(:second), -120)
      )
    )

    assert {:error, :reauthorization_required} =
             OrganizationGitHubCredentials.refresh_credential(saved, fn _, _ ->
               flunk("abandoned exchange")
             end)
  end

  test "refresh refuses an outer transaction before dispatch", c do
    {:ok, absent} = OrganizationGitHubCredentials.reference(c.owner, c.organization.id)
    {:ok, saved} = save(c, absent)

    assert {:ok, :checked} =
             Repo.transaction(fn ->
               assert {:error, :credential_service_unavailable} =
                        OrganizationGitHubCredentials.refresh_credential(saved, fn _, _ ->
                          flunk("uncommitted claim")
                        end)

               :checked
             end)
  end

  defp save(c, expected, value \\ token()),
    do:
      OrganizationGitHubCredentials.save_device_grant_if_current(
        c.owner,
        c.organization.id,
        %{github_user_id: 9_000_000_001, login: "octocat"},
        value,
        expected,
        %{}
      )

  defp token(overrides \\ %{}),
    do:
      Map.merge(
        %{
          client_id: "Iv23lizCVE3E24s7fCA0",
          access_token: "test-org-access",
          refresh_token: "test-org-refresh",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600),
          refresh_expires_at: DateTime.add(DateTime.utc_now(:second), 86400)
        },
        overrides
      )
end
