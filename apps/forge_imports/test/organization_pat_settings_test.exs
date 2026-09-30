defmodule ForgeImports.OrganizationPatSettingsTest do
  use ExUnit.Case, async: false
  alias ForgeAccounts.User
  alias ForgeMirrors.PatSettings
  alias ForgeImports.OrganizationPatSettings
  alias Fornacast.Repo

  defmodule Client do
    def organization_repositories(_token, "source-org", _opts) do
      Process.get({__MODULE__, :result}, {:error, %ForgeGitHub.Error{kind: :not_found}})
    end
  end

  defmodule Imports do
    def create_organization_discovery(actor, attrs, metadata, opts) do
      send(self(), {:pat_sync, actor.id, attrs, metadata, opts})
      {:ok, %{id: 99, state: :discovering}}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    n = System.unique_integer([:positive, :monotonic])

    owner =
      Repo.insert!(%User{
        username: "inventory#{n}",
        email: "inventory#{n}@test.local",
        password_hash: "unused",
        kind: :user,
        role: :user,
        state: :active
      })

    {:ok, org} = ForgeAccounts.create_organization(owner, %{username: "inventory-org#{n}"})

    {:ok, account} =
      ForgeAccounts.save_github_account(
        owner,
        %{github_user_id: n, login: "owner#{n}", avatar_url: nil, profile_url: nil},
        "github_pat_inventory_test",
        %{}
      )

    {:ok, config} =
      PatSettings.save(
        owner,
        org.id,
        %{
          "owner_user_id" => to_string(owner.id),
          "github_identity_id" => to_string(account.identity_id),
          "github_organization" => "source-org",
          "enabled" => "true",
          "lock_version" => "1"
        },
        %{}
      )

    %{owner: owner, org: org, version: to_string(config.lock_version)}
  end

  test "failed GitHub inventory is an error and leaves existing state unchanged", c do
    assert {:error, :not_found} =
             OrganizationPatSettings.refresh(c.owner, c.org.id, c.version, %{}, client: Client)

    assert {:ok, %{config: %{inventory: %{}, inventory_refreshed_at: nil}}} =
             PatSettings.view(c.owner, c.org.id)
  end

  test "read-only discovery persists safe rows, not a sync operation", c do
    Process.put(
      {Client, :result},
      {:ok,
       [%{id: 42, owner_login: "source-org", full_name: "source-org/repo", visibility: :private}]}
    )

    assert :ok =
             OrganizationPatSettings.refresh(c.owner, c.org.id, c.version, %{}, client: Client)

    assert {:ok, %{config: %{inventory: %{"repositories" => [row]}}}} =
             PatSettings.view(c.owner, c.org.id)

    assert row == %{"id" => 42, "full_name" => "source-org/repo", "visibility" => "private"}
    assert Repo.aggregate(ForgeMirrors.MirrorOperation, :count) == 0
  end

  test "sync starts a saved-PAT organization import for the existing destination", c do
    assert {:ok, %{id: 99, state: :discovering}} =
             OrganizationPatSettings.sync(c.owner, c.org.id, c.version, %{"request" => "test"},
               imports: Imports,
               dispatch: :async
             )

    assert_receive {:pat_sync, actor_id, attrs, %{"request" => "test"}, dispatch: :async}
    assert actor_id == c.owner.id
    assert attrs.organization == "source-org"
    assert attrs.credential_source == :saved
    assert attrs.github_identity_id > 0
    assert attrs.destination_organization == %{action: :existing, id: c.org.id}
  end
end
