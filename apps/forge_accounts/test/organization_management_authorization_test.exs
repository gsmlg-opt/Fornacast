defmodule ForgeAccounts.OrganizationManagementAuthorizationTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{Organization, User}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    owner = user_fixture("owner")
    admin = user_fixture("admin", :admin)
    member = user_fixture("member")
    outsider = user_fixture("outsider")

    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_organization(owner, %{
               username: unique("manageable-org"),
               display_name: "Manageable organization"
             })

    assert {:ok, _membership} = ForgeAccounts.add_organization_member(organization, member)

    %{owner: owner, admin: admin, member: member, outsider: outsider, organization: organization}
  end

  test "active owner and site admin receive the canonical manageable organization", context do
    assert {:ok, %Organization{} = owner_organization} =
             ForgeAccounts.fetch_manageable_organization(
               context.owner,
               context.organization.id
             )

    assert owner_organization.id == context.organization.id

    assert {:ok, %Organization{} = admin_organization} =
             ForgeAccounts.fetch_manageable_organization(
               context.admin,
               context.organization.id
             )

    assert admin_organization.id == context.organization.id
  end

  test "owner and site admin may fetch a manageable organization by normalized slug", context do
    normalized_input = "  #{String.upcase(context.organization.username)}  "

    assert {:ok, %Organization{} = owner_organization} =
             ForgeAccounts.fetch_manageable_organization_by_slug(
               context.owner,
               normalized_input
             )

    assert owner_organization.id == context.organization.id

    assert {:ok, %Organization{} = admin_organization} =
             ForgeAccounts.fetch_manageable_organization_by_slug(
               context.admin,
               normalized_input
             )

    assert admin_organization.id == context.organization.id
  end

  test "slug lookup forbids members outsiders inactive and forged actors", context do
    slug = context.organization.username

    assert {:error, :forbidden} =
             ForgeAccounts.fetch_manageable_organization_by_slug(context.member, slug)

    assert {:error, :forbidden} =
             ForgeAccounts.fetch_manageable_organization_by_slug(context.outsider, slug)

    assert {:ok, disabled} =
             context.owner
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :forbidden} =
             ForgeAccounts.fetch_manageable_organization_by_slug(
               %{disabled | state: :active, role: :admin},
               slug
             )

    assert {:error, :forbidden} =
             ForgeAccounts.fetch_manageable_organization_by_slug(
               %{context.member | role: :admin},
               slug
             )
  end

  test "slug lookup masks missing and disabled organizations as not found", context do
    assert {:error, :not_found} =
             ForgeAccounts.fetch_manageable_organization_by_slug(
               context.owner,
               unique("missing-org")
             )

    assert {:ok, disabled} =
             context.organization
             |> Organization.changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :not_found} =
             ForgeAccounts.fetch_manageable_organization_by_slug(
               context.admin,
               disabled.username
             )
  end

  test "member outsider inactive and forged actors are forbidden", context do
    assert {:error, :forbidden} =
             ForgeAccounts.fetch_manageable_organization(
               context.member,
               context.organization.id
             )

    assert {:error, :forbidden} =
             ForgeAccounts.fetch_manageable_organization(
               context.outsider,
               context.organization.id
             )

    assert {:ok, disabled} =
             context.owner
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :forbidden} =
             ForgeAccounts.fetch_manageable_organization(
               %{disabled | state: :active, role: :admin},
               context.organization.id
             )

    assert {:error, :forbidden} =
             ForgeAccounts.fetch_manageable_organization(
               %{context.member | role: :admin},
               context.organization.id
             )
  end

  test "missing and disabled organizations are masked as not found", context do
    assert {:error, :not_found} =
             ForgeAccounts.fetch_manageable_organization(context.owner, 2_147_483_647)

    assert {:ok, disabled} =
             context.organization
             |> Organization.changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :not_found} =
             ForgeAccounts.fetch_manageable_organization(context.admin, disabled.id)
  end

  defp user_fixture(prefix, role \\ :user) do
    result =
      case role do
        :admin -> ForgeAccounts.create_admin(user_attrs(prefix))
        :user -> ForgeAccounts.create_user(user_attrs(prefix))
      end

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
