defmodule ForgeMirrors.AuthorizationTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures, only: [repository_fixture: 1]

  alias ForgeAccounts.{Organization, User}
  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorConflict, OrganizationMirror, RepositoryMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    owner = user_fixture("owner")
    admin = user_fixture("admin", :admin)
    member = user_fixture("member")
    outsider = user_fixture("outsider")
    organization = organization_fixture(owner, "managed")
    assert {:ok, _membership} = ForgeAccounts.add_organization_member(organization, member)

    %{
      owner: owner,
      admin: admin,
      member: member,
      outsider: outsider,
      organization: organization
    }
  end

  test "owner mutations authorize at the domain boundary and resolve as the actor", context do
    assert {:ok, mirror} = create_mirror(context.owner, context.organization)

    assert {:ok, updated} =
             ForgeMirrors.update_organization_mirror(context.owner, mirror, %{
               policy: %{"repositories" => "all"}
             })

    assert {:ok, ready} =
             ForgeMirrors.transition_organization_mirror(
               context.owner,
               updated,
               :ready_to_bootstrap
             )

    assert {:ok, paused} = ForgeMirrors.pause(context.owner, ready)
    assert {:ok, resumed} = ForgeMirrors.resume(context.owner, paused)

    repository_id = repository_fixture(context.organization.id)

    assert {:ok, repository_mirror} =
             ForgeMirrors.bind_repository(context.owner, %{
               organization_mirror_id: resumed.id,
               repository_id: repository_id,
               github_repository_id: System.unique_integer([:positive, :monotonic])
             })

    assert {:ok, repository_mirror} =
             ForgeMirrors.update_repository_mirror(context.owner, repository_mirror, %{
               github_node_id: "R_owner_authorized"
             })

    assert {:ok, active_repository} =
             ForgeMirrors.transition_repository_mirror(
               context.owner,
               repository_mirror,
               :active
             )

    now = DateTime.utc_now(:second)

    assert {:ok, operation} =
             ForgeMirrors.schedule_reconciliation(context.owner, resumed, now)

    assert operation.organization_mirror_id == resumed.id

    assert {:ok, %MirrorConflict{} = conflict} =
             ForgeMirrors.record_conflict(%{
               organization_mirror_id: resumed.id,
               repository_mirror_id: active_repository.id,
               resource_kind: "repository",
               resource_identity: "repository:#{active_repository.id}",
               conflict_kind: "namespace_collision",
               baseline_snapshot: %{},
               local_snapshot: %{},
               remote_snapshot: %{}
             })

    assert {:ok, resolved} =
             ForgeMirrors.resolve_conflict(
               context.owner,
               conflict,
               %{"choice" => "local"},
               now
             )

    assert resolved.resolved_by_user_id == context.owner.id
  end

  test "site admin may manage an organization mirror without membership", context do
    assert {:ok, mirror} = create_mirror(context.admin, context.organization)

    assert {:ok, updated} =
             ForgeMirrors.update_organization_mirror(context.admin, mirror, %{
               capabilities: %{"installation" => true}
             })

    assert updated.capabilities == %{"installation" => true}
  end

  test "every owner-facing mutation rejects an active non-owner", context do
    assert {:ok, mirror} = create_mirror(context.owner, context.organization)

    assert {:ok, ready} =
             ForgeMirrors.transition_organization_mirror(
               context.owner,
               mirror,
               :ready_to_bootstrap
             )

    assert {:ok, paused} = ForgeMirrors.pause(context.owner, ready)
    repository_id = repository_fixture(context.organization.id)

    assert {:ok, repository_mirror} =
             ForgeMirrors.bind_repository(context.owner, %{
               organization_mirror_id: paused.id,
               repository_id: repository_id,
               github_repository_id: System.unique_integer([:positive, :monotonic])
             })

    assert {:ok, conflict} =
             ForgeMirrors.record_conflict(%{
               organization_mirror_id: paused.id,
               repository_mirror_id: repository_mirror.id,
               resource_kind: "repository",
               resource_identity: "repository:#{repository_mirror.id}",
               conflict_kind: "namespace_collision",
               baseline_snapshot: %{},
               local_snapshot: %{},
               remote_snapshot: %{}
             })

    now = DateTime.utc_now(:second)
    actor = context.outsider

    assert {:error, :forbidden} =
             ForgeMirrors.create_organization_mirror(actor, %{
               organization_id: context.organization.id,
               provider: "github"
             })

    assert {:error, :forbidden} =
             ForgeMirrors.update_organization_mirror(actor, paused, %{policy: %{}})

    assert {:error, :forbidden} =
             ForgeMirrors.transition_organization_mirror(actor, paused, :revoked)

    assert {:error, :forbidden} = ForgeMirrors.pause(actor, ready)
    assert {:error, :forbidden} = ForgeMirrors.resume(actor, paused)

    assert {:error, :forbidden} =
             ForgeMirrors.bind_repository(actor, %{
               organization_mirror_id: paused.id,
               repository_id: repository_fixture(context.organization.id)
             })

    other_organization = organization_fixture(context.outsider, "other-binding")

    assert {:error, :forbidden} =
             ForgeMirrors.bind_repository(actor, %{
               organization_mirror_id: paused.id,
               repository_id: repository_fixture(other_organization.id)
             })

    assert {:error, :forbidden} =
             ForgeMirrors.update_repository_mirror(actor, repository_mirror, %{
               github_node_id: "R_forbidden"
             })

    assert {:error, :forbidden} =
             ForgeMirrors.transition_repository_mirror(actor, repository_mirror, :active)

    assert {:error, :forbidden} =
             ForgeMirrors.schedule_reconciliation(actor, paused, now)

    assert {:error, :forbidden} =
             ForgeMirrors.resolve_conflict(actor, conflict, %{"choice" => "local"}, now)
  end

  test "persisted organization scope defeats forged mirror and conflict structs", context do
    attacker_organization = organization_fixture(context.outsider, "attacker")
    assert {:ok, attacker_mirror} = create_mirror(context.outsider, attacker_organization)

    assert {:ok, %OrganizationMirror{} = victim_mirror} =
             create_mirror(context.owner, context.organization)

    forged_mirror = %OrganizationMirror{
      victim_mirror
      | organization_id: attacker_organization.id
    }

    assert {:error, :forbidden} =
             ForgeMirrors.update_organization_mirror(
               context.outsider,
               forged_mirror,
               %{policy: %{"forged" => true}}
             )

    repository_id = repository_fixture(context.organization.id)

    assert {:ok, %RepositoryMirror{} = victim_repository} =
             ForgeMirrors.bind_repository(context.owner, %{
               organization_mirror_id: victim_mirror.id,
               repository_id: repository_id,
               github_repository_id: System.unique_integer([:positive, :monotonic])
             })

    forged_repository = %RepositoryMirror{
      victim_repository
      | organization_mirror_id: attacker_mirror.id
    }

    assert {:error, :forbidden} =
             ForgeMirrors.transition_repository_mirror(
               context.outsider,
               forged_repository,
               :active
             )

    assert {:ok, %MirrorConflict{} = conflict} =
             ForgeMirrors.record_conflict(%{
               organization_mirror_id: victim_mirror.id,
               resource_kind: "organization",
               resource_identity: "organization:#{victim_mirror.id}",
               conflict_kind: "namespace_collision",
               baseline_snapshot: %{},
               local_snapshot: %{},
               remote_snapshot: %{}
             })

    forged_conflict = %MirrorConflict{
      conflict
      | organization_mirror_id: attacker_mirror.id
    }

    assert {:error, :forbidden} =
             ForgeMirrors.resolve_conflict(
               context.outsider,
               forged_conflict,
               %{"choice" => "remote"},
               DateTime.utc_now(:second)
             )
  end

  test "inactive and forged-role actors remain forbidden", context do
    assert {:ok, mirror} = create_mirror(context.owner, context.organization)

    assert {:ok, disabled} =
             context.member
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :forbidden} =
             ForgeMirrors.update_organization_mirror(
               %{disabled | state: :active, role: :admin},
               mirror,
               %{policy: %{}}
             )

    assert {:error, :forbidden} =
             ForgeMirrors.update_organization_mirror(
               %{context.member | role: :admin},
               mirror,
               %{policy: %{}}
             )
  end

  defp create_mirror(actor, %Organization{} = organization) do
    ForgeMirrors.create_organization_mirror(actor, %{
      organization_id: organization.id,
      provider: "github",
      github_installation_id: System.unique_integer([:positive, :monotonic]),
      github_account_id: System.unique_integer([:positive, :monotonic])
    })
  end

  defp organization_fixture(owner, prefix) do
    assert {:ok, organization} =
             ForgeAccounts.create_organization(owner, %{
               username: unique("#{prefix}-org"),
               display_name: "#{prefix} organization"
             })

    organization
  end

  defp user_fixture(prefix, role \\ :user) do
    attrs = user_attrs(prefix)

    result =
      if role == :admin,
        do: ForgeAccounts.create_admin(attrs),
        else: ForgeAccounts.create_user(attrs)

    assert {:ok, user} = result
    user
  end

  defp user_attrs(prefix) do
    value = unique(prefix)

    %{
      username: value,
      email: "#{value}@example.test",
      password: "correct horse battery staple"
    }
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
