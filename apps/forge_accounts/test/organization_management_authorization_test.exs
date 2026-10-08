defmodule ForgeAccounts.OrganizationManagementAuthorizationTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{Organization, OrganizationMember, User}
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

  test "selected GitHub owner authorization avoids enumerating owner account views", context do
    other_owner = user_fixture("other-owner")

    assert {:ok, _} =
             ForgeAccounts.add_organization_member(context.organization, other_owner, :owner)

    {result, queries} =
      collect_queries(fn ->
        ForgeAccounts.organization_github_owner(
          context.owner,
          context.organization.id,
          context.owner.id
        )
      end)

    assert {:ok, selected} = result
    assert selected.id == context.owner.id
    assert length(queries) == 4
    refute Enum.any?(queries, &String.contains?(&1, "github_"))
  end

  test "site administrators still must select an active organization owner", context do
    assert {:ok, selected} =
             ForgeAccounts.organization_github_owner(
               context.admin,
               context.organization.id,
               context.owner.id
             )

    assert selected.id == context.owner.id

    for owner_id <- [
          context.admin.id,
          context.member.id,
          context.outsider.id,
          context.organization.id
        ] do
      assert {:error, :forbidden} =
               ForgeAccounts.organization_github_owner(
                 context.admin,
                 context.organization.id,
                 owner_id
               )
    end

    membership =
      Repo.get_by!(OrganizationMember,
        organization_id: context.organization.id,
        user_id: context.owner.id
      )

    Repo.update!(Ecto.Changeset.change(membership, role: :member))

    assert {:error, :forbidden} =
             ForgeAccounts.organization_github_owner(
               context.admin,
               context.organization.id,
               context.owner.id
             )
  end

  test "selected-owner authorization reloads actor owner and organization authority", context do
    assert {:error, :forbidden} =
             ForgeAccounts.organization_github_owner(
               %{context.member | role: :admin},
               context.organization.id,
               context.owner.id
             )

    Repo.update!(User.state_changeset(context.owner, %{state: :disabled}))

    assert {:error, :forbidden} =
             ForgeAccounts.organization_github_owner(
               context.admin,
               context.organization.id,
               context.owner.id
             )

    Repo.update!(User.state_changeset(context.owner, %{state: :active}))
    Repo.update!(User.state_changeset(context.admin, %{state: :disabled}))

    assert {:error, :forbidden} =
             ForgeAccounts.organization_github_owner(
               context.admin,
               context.organization.id,
               context.owner.id
             )

    Repo.update!(User.state_changeset(context.admin, %{state: :active}))
    Repo.update!(Organization.changeset(context.organization, %{state: :disabled}))

    assert {:error, :forbidden} =
             ForgeAccounts.organization_github_owner(
               context.admin,
               context.organization.id,
               context.owner.id
             )
  end

  test "invalid selected owner IDs preserve forbidden results", context do
    for owner_id <- [nil, false, "#{context.owner.id}", 0, -1, 1.0, 9_223_372_036_854_775_808] do
      assert {:error, :forbidden} =
               ForgeAccounts.organization_github_owner(
                 context.admin,
                 context.organization.id,
                 owner_id
               )
    end

    assert {:error, :forbidden} =
             ForgeAccounts.organization_github_owner(
               context.admin,
               2_147_483_647,
               context.owner.id
             )
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

  defp collect_queries(fun) do
    reference = make_ref()
    handler = {__MODULE__, reference}
    caller = self()
    prefix = Repo.config()[:telemetry_prefix] || [:fornacast, :repo]

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:query],
        fn _, _, metadata, _ ->
          if self() == caller, do: send(caller, {reference, metadata.query})
        end,
        nil
      )

    try do
      result = fun.()
      {result, receive_queries(reference)}
    after
      :telemetry.detach(handler)
    end
  end

  defp receive_queries(reference) do
    receive do
      {^reference, query} -> [query | receive_queries(reference)]
    after
      0 -> []
    end
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
