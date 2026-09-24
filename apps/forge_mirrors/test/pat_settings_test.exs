defmodule ForgeMirrors.PatSettingsTest do
  use ExUnit.Case, async: false
  alias ForgeMirrors.{PatSettings, PatConfiguration}
  alias ForgeAccounts.{User, GitHubCredential, GitHubIdentity}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = user()
    outsider = user()
    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: unique("pat-org")})

    identity =
      Repo.insert!(%GitHubIdentity{
        kind: :user,
        github_user_id: System.unique_integer([:positive]),
        login: unique("github"),
        local_user_id: owner.id
      })

    Repo.insert!(%GitHubCredential{
      local_user_id: owner.id,
      github_identity_id: identity.id,
      ciphertext: "encrypted",
      nonce: <<0::96>>,
      tag: <<0::128>>,
      key_id: "test",
      status: :valid
    })

    attrs = %{
      "owner_user_id" => to_string(owner.id),
      "github_identity_id" => to_string(identity.id),
      "github_organization" => "gsmlg-ci",
      "enabled" => "true",
      "lock_version" => "1"
    }

    %{owner: owner, outsider: outsider, org: org, identity: identity, attrs: attrs}
  end

  test "saves configuration without creating an active mirror or executing sync", c do
    assert {:ok, saved} = PatSettings.save(c.owner, c.org.id, c.attrs, %{})
    assert saved.enabled
    assert saved.direction == "github_to_fornacast"

    assert {:ok, %{config: %{id: id}, credential: %{credential_status: :valid}}} =
             PatSettings.view(c.owner, c.org.id)

    assert id == saved.id
    assert Repo.aggregate(ForgeMirrors.OrganizationMirror, :count) == 0

    assert {:ok, disabled} =
             PatSettings.save(
               c.owner,
               c.org.id,
               %{c.attrs | "enabled" => "false", "lock_version" => "2"},
               %{}
             )

    refute disabled.enabled
    assert disabled.github_identity_id == c.identity.id
    assert {:error, :stale} = PatSettings.save(c.owner, c.org.id, c.attrs, %{})
  end

  test "rejects unauthorized actors and non-owner credentials", c do
    assert {:error, :forbidden} = PatSettings.view(c.outsider, c.org.id)
    assert {:error, :forbidden} = PatSettings.save(c.outsider, c.org.id, c.attrs, %{})

    assert {:error, :credential_unavailable} =
             PatSettings.save(
               c.owner,
               c.org.id,
               %{c.attrs | "owner_user_id" => to_string(c.outsider.id)},
               %{}
             )

    assert Repo.aggregate(PatConfiguration, :count) == 0
  end

  test "repository selection persists and excludes unknown IDs; changing source clears scope",
       c do
    assert {:ok, saved} = PatSettings.save(c.owner, c.org.id, c.attrs, %{})

    assert {:ok, refreshed} =
             PatSettings.store_inventory(
               c.owner,
               c.org.id,
               to_string(saved.lock_version),
               %{
                 "repositories" => [
                   %{"id" => 42, "full_name" => "gsmlg-ci/repo", "visibility" => "private"}
                 ]
               },
               %{}
             )

    attrs = %{
      "lock_version" => to_string(refreshed.lock_version),
      "repository_selection" => "selected",
      "selected_repository_ids" => ["42"]
    }

    assert {:error, :invalid_request} =
             PatSettings.select_repositories(
               c.owner,
               c.org.id,
               %{attrs | "selected_repository_ids" => ["99"]},
               %{}
             )

    assert {:ok, selected} = PatSettings.select_repositories(c.owner, c.org.id, attrs, %{})
    assert selected.selected_repository_ids == [42]

    assert {:ok, changed} =
             PatSettings.save(
               c.owner,
               c.org.id,
               %{
                 c.attrs
                 | "github_organization" => "other",
                   "lock_version" => to_string(selected.lock_version)
               },
               %{}
             )

    assert changed.inventory == %{}
    assert changed.selected_repository_ids == []
  end

  test "invalid credential blocks enabling but does not prevent disabling", c do
    {:ok, saved} = PatSettings.save(c.owner, c.org.id, c.attrs, %{})
    credential = Repo.get_by!(GitHubCredential, github_identity_id: c.identity.id)
    Repo.update!(Ecto.Changeset.change(credential, status: :invalid))
    attrs = %{c.attrs | "lock_version" => to_string(saved.lock_version)}
    assert {:error, :credential_unavailable} = PatSettings.save(c.owner, c.org.id, attrs, %{})

    assert {:ok, %{enabled: false}} =
             PatSettings.save(c.owner, c.org.id, %{attrs | "enabled" => "false"}, %{})
  end

  test "owner removal prevents enablement but allows disabling the saved configuration", c do
    {:ok, saved} = PatSettings.save(c.owner, c.org.id, c.attrs, %{})
    admin = Repo.update!(Ecto.Changeset.change(c.outsider, role: :admin))

    membership =
      Repo.get_by!(ForgeAccounts.OrganizationMember,
        organization_id: c.org.id,
        user_id: c.owner.id
      )

    Repo.update!(Ecto.Changeset.change(membership, role: :member))
    attrs = %{c.attrs | "lock_version" => to_string(saved.lock_version)}
    assert {:error, :credential_unavailable} = PatSettings.save(admin, c.org.id, attrs, %{})

    assert {:ok, %{enabled: false}} =
             PatSettings.save(admin, c.org.id, %{attrs | "enabled" => "false"}, %{})
  end

  test "rejects forged outbound direction and does not overwrite repository selection on toggle",
       c do
    assert {:error, :invalid_request} =
             PatSettings.save(
               c.owner,
               c.org.id,
               Map.put(c.attrs, "direction", "bidirectional"),
               %{}
             )

    {:ok, saved} = PatSettings.save(c.owner, c.org.id, c.attrs, %{})

    {:ok, inventory} =
      PatSettings.store_inventory(
        c.owner,
        c.org.id,
        to_string(saved.lock_version),
        %{"repositories" => [%{"id" => 42}]},
        %{}
      )

    {:ok, selected} =
      PatSettings.select_repositories(
        c.owner,
        c.org.id,
        %{
          "lock_version" => to_string(inventory.lock_version),
          "repository_selection" => "selected",
          "selected_repository_ids" => ["42"]
        },
        %{}
      )

    assert {:ok, disabled} =
             PatSettings.save(
               c.owner,
               c.org.id,
               %{
                 c.attrs
                 | "lock_version" => to_string(selected.lock_version),
                   "enabled" => "false"
               },
               %{}
             )

    assert disabled.selected_repository_ids == [42]
    assert disabled.repository_selection == "selected"
  end

  defp user,
    do:
      Repo.insert!(%User{
        username: unique("pat-user"),
        email: unique("email") <> "@test.local",
        password_hash: "unused",
        kind: :user,
        state: :active,
        role: :user
      })

  defp unique(prefix),
    do: prefix <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
end
