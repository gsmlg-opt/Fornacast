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
    operation_count = Repo.aggregate(ForgeMirrors.MirrorOperation, :count)

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
    assert Repo.aggregate(ForgeMirrors.MirrorOperation, :count) == operation_count
  end

  test "sync admits a durable all-repository job and reuses it on repeated clicks", c do
    assert {:ok, job} =
             OrganizationPatSettings.sync(c.owner, c.org.id, c.version, %{}, dispatch: :manual)

    assert %{organization_id: organization_id, state: "queued", import_run_id: nil} = job
    assert organization_id == c.org.id

    assert {:ok, same} =
             OrganizationPatSettings.sync(c.owner, c.org.id, c.version, %{}, dispatch: :manual)

    assert same.id == job.id
    assert {:ok, %{config: %{last_sync_status: "running"}}} = PatSettings.view(c.owner, c.org.id)
  end

  test "a source change admits a new job immediately and fences the old source", c do
    assert {:ok, old} =
             OrganizationPatSettings.sync(c.owner, c.org.id, c.version, %{}, dispatch: :manual)

    assert {:ok, config} =
             PatSettings.save(
               c.owner,
               c.org.id,
               %{"github_organization" => "another-source", "lock_version" => c.version},
               %{}
             )

    assert {:ok, new} =
             OrganizationPatSettings.sync(c.owner, c.org.id, to_string(config.lock_version), %{},
               dispatch: :manual
             )

    assert new.id != old.id
    assert new.github_organization == "another-source"

    assert %{state: "failed", error: "configuration_changed", lease_owner: nil} =
             Repo.get!(ForgeImports.PatSyncRun, old.id)
  end

  test "disabled and paused sync requests do not create import tasks", c do
    assert {:ok, _} = PatSettings.set_paused(c.owner, c.org.id, true, %{})

    assert {:error, :paused} =
             OrganizationPatSettings.sync(c.owner, c.org.id, c.version, %{}, dispatch: :manual)
  end

  test "a queued synchronization continues without another click and records discovery failures",
       c do
    assert {:ok, job} =
             OrganizationPatSettings.sync(c.owner, c.org.id, c.version, %{}, dispatch: :manual)

    assert {:error, :not_found} =
             apply(ForgeImports.PatSyncWorker, :perform, [
               job.id,
               [create_discovery: fn _owner, _attrs, _metadata -> {:error, :not_found} end]
             ])

    assert %{state: "failed", finished_at: finished_at} =
             Fornacast.Repo.get!(ForgeImports.PatSyncRun, job.id)

    refute is_nil(finished_at)
    assert {:ok, %{config: %{last_sync_status: "failed"}}} = PatSettings.view(c.owner, c.org.id)
  end

  test "a source change fences already queued synchronization before provider access", c do
    assert {:ok, job} =
             OrganizationPatSettings.sync(c.owner, c.org.id, c.version, %{}, dispatch: :manual)

    assert {:ok, _} =
             PatSettings.save(
               c.owner,
               c.org.id,
               %{"github_organization" => "another-source", "lock_version" => c.version},
               %{}
             )

    assert {:error, :configuration_changed} =
             apply(ForgeImports.PatSyncWorker, :perform, [
               job.id,
               [create_discovery: fn _, _, _ -> flunk("provider must not be called") end]
             ])
  end
end
