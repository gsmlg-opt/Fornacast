defmodule Fornacast.AccessTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{Organization, OrganizationMember, User}
  alias ForgeRepos.{Collaborator, Repository}
  alias Fornacast.Repo

  @permissions [:repository_read, :repository_write, :repository_admin]

  setup do
    reset_database!()
  end

  test "anonymous actors can read public repositories only" do
    owner = active_user_fixture("public-owner")
    repository = personal_repository_fixture(owner, visibility: :public)

    assert_permissions(nil, repository, [:repository_read])
  end

  test "personal owners can read, write, and administer their repositories" do
    owner = active_user_fixture("personal-owner")
    repository = personal_repository_fixture(owner)

    assert_permissions(owner, repository, @permissions)
  end

  test "organization owners can read, write, and administer organization repositories" do
    owner = active_user_fixture("organization-owner")
    organization = organization_fixture("owner-org")
    organization_owner_fixture(organization, owner)
    repository = organization_repository_fixture(organization)

    assert_permissions(owner, repository, @permissions)
  end

  test "organization members can read organization repositories only" do
    owner = active_user_fixture("organization-owner")
    member = active_user_fixture("organization-member")
    organization = organization_fixture("member-org")
    organization_owner_fixture(organization, owner)
    organization_member_fixture(organization, member)
    repository = organization_repository_fixture(organization)

    assert_permissions(member, repository, [:repository_read])
  end

  test "read collaborators can read repositories only" do
    owner = active_user_fixture("read-owner")
    collaborator = active_user_fixture("read-collaborator")
    repository = personal_repository_fixture(owner)
    collaborator_fixture(repository, collaborator, :read)

    assert_permissions(collaborator, repository, [:repository_read])
  end

  test "write collaborators can read and write repositories" do
    owner = active_user_fixture("write-owner")
    collaborator = active_user_fixture("write-collaborator")
    repository = personal_repository_fixture(owner)
    collaborator_fixture(repository, collaborator, :write)

    assert_permissions(collaborator, repository, [
      :repository_read,
      :repository_write
    ])
  end

  test "admin collaborators can read, write, and administer repositories" do
    owner = active_user_fixture("admin-owner")
    collaborator = active_user_fixture("admin-collaborator")
    repository = personal_repository_fixture(owner)
    collaborator_fixture(repository, collaborator, :admin)

    assert_permissions(collaborator, repository, @permissions)
  end

  test "active site admins can read, write, and administer repositories" do
    owner = active_user_fixture("site-admin-owner")
    site_admin = active_user_fixture("site-admin", role: :admin)
    repository = personal_repository_fixture(owner)

    assert_permissions(site_admin, repository, @permissions)
  end

  test "anonymous actors cannot access private repositories" do
    owner = active_user_fixture("private-owner")
    repository = personal_repository_fixture(owner)

    assert_permissions(nil, repository, [])
  end

  test "unrelated active users cannot access personal or organization private repositories" do
    owner = active_user_fixture("unrelated-owner")
    unrelated_user = active_user_fixture("unrelated-user")
    personal_repository = personal_repository_fixture(owner)

    organization = organization_fixture("unrelated-org")
    organization_owner_fixture(organization, owner)
    organization_repository = organization_repository_fixture(organization)

    assert_permissions(unrelated_user, personal_repository, [])
    assert_permissions(unrelated_user, organization_repository, [])
  end

  test "disabled actors retain anonymous public read access only" do
    disabled_owner = disabled_user_fixture("disabled-owner")
    owned_private_repository = personal_repository_fixture(disabled_owner, slug: "private")

    owned_public_repository =
      personal_repository_fixture(disabled_owner, slug: "public", visibility: :public)

    assert_permissions(disabled_owner, owned_private_repository, [])
    assert_permissions(disabled_owner, owned_public_repository, [:repository_read])

    disabled_organization_owner = disabled_user_fixture("disabled-organization-owner")
    organization = organization_fixture("disabled-owner-org")
    organization_owner_fixture(organization, disabled_organization_owner)

    organization_private_repository =
      organization_repository_fixture(organization, slug: "private")

    organization_public_repository =
      organization_repository_fixture(organization, slug: "public", visibility: :public)

    assert_permissions(disabled_organization_owner, organization_private_repository, [])

    assert_permissions(
      disabled_organization_owner,
      organization_public_repository,
      [:repository_read]
    )

    active_owner = active_user_fixture("disabled-collaborator-owner")
    collaborator_private_repository = personal_repository_fixture(active_owner, slug: "private")

    collaborator_public_repository =
      personal_repository_fixture(active_owner, slug: "public", visibility: :public)

    disabled_collaborator = disabled_user_fixture("disabled-collaborator")
    collaborator_fixture(collaborator_private_repository, disabled_collaborator, :admin)
    collaborator_fixture(collaborator_public_repository, disabled_collaborator, :admin)

    assert_permissions(disabled_collaborator, collaborator_private_repository, [])
    assert_permissions(disabled_collaborator, collaborator_public_repository, [:repository_read])

    disabled_site_admin = disabled_user_fixture("disabled-site-admin", role: :admin)
    assert_permissions(disabled_site_admin, collaborator_private_repository, [])
    assert_permissions(disabled_site_admin, collaborator_public_repository, [:repository_read])
  end

  test "authorized fetch masks private repositories and distinguishes visible forbidden writes" do
    owner = active_user_fixture("fetch-owner")
    unrelated = active_user_fixture("fetch-unrelated")
    private_repository = personal_repository_fixture(owner, slug: "private")
    public_repository = personal_repository_fixture(owner, slug: "public", visibility: :public)

    assert {:ok, %Repository{id: private_id}} =
             ForgeRepos.fetch_authorized_repository(
               owner,
               owner.username,
               private_repository.slug,
               :repository_read
             )

    assert private_id == private_repository.id

    assert {:error, :not_found} =
             ForgeRepos.fetch_authorized_repository(
               unrelated,
               owner.username,
               private_repository.slug,
               :repository_read
             )

    assert {:error, :not_found} =
             ForgeRepos.fetch_authorized_repository(
               nil,
               owner.username,
               private_repository.slug,
               :repository_read
             )

    assert {:error, :forbidden} =
             ForgeRepos.fetch_authorized_repository(
               unrelated,
               owner.username,
               public_repository.slug,
               :repository_write
             )

    assert {:error, :forbidden} =
             ForgeRepos.fetch_authorized_repository(
               nil,
               owner.username,
               public_repository.slug,
               :repository_admin
             )
  end

  test "authorized fetch reloads stale actors and preserves anonymous public access" do
    owner = active_user_fixture("stale-fetch-owner")
    collaborator = active_user_fixture("stale-fetch-collaborator")
    private_repository = personal_repository_fixture(owner, slug: "private")
    public_repository = personal_repository_fixture(owner, slug: "public", visibility: :public)
    collaborator_fixture(private_repository, collaborator, :admin)
    collaborator_fixture(public_repository, collaborator, :admin)

    collaborator
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert {:error, :not_found} =
             ForgeRepos.fetch_authorized_repository(
               collaborator,
               owner.username,
               private_repository.slug,
               :repository_read
             )

    for actor <- [collaborator, :invalid_actor] do
      assert {:ok, %Repository{id: public_id}} =
               ForgeRepos.fetch_authorized_repository(
                 actor,
                 owner.username,
                 public_repository.slug,
                 :repository_read
               )

      assert public_id == public_repository.id

      assert {:error, :forbidden} =
               ForgeRepos.fetch_authorized_repository(
                 actor,
                 owner.username,
                 public_repository.slug,
                 :repository_write
               )
    end
  end

  test "authorized fetch rejects deleted rows and unsupported permissions before storage access" do
    owner = active_user_fixture("deleted-owner")
    repository = personal_repository_fixture(owner, visibility: :public)

    live_repository =
      personal_repository_fixture(owner, slug: "live", visibility: :public)

    repository
    |> Ecto.Changeset.change(deleted_at: ~U[2026-07-21 12:00:00Z])
    |> Repo.update!()

    assert {:error, :not_found} =
             ForgeRepos.fetch_authorized_repository(
               owner,
               owner.username,
               repository.slug,
               :repository_read
             )

    assert {:error, :forbidden} =
             ForgeRepos.fetch_authorized_repository(
               owner,
               owner.username,
               live_repository.slug,
               :unsupported_permission
             )

    assert {:error, :not_found} =
             ForgeRepos.fetch_authorized_repository(
               owner,
               owner.username <> <<0>>,
               live_repository.slug,
               :repository_read
             )

    assert {:error, :not_found} =
             ForgeRepos.fetch_authorized_repository(
               owner,
               owner.username,
               live_repository.slug <> <<0>>,
               :repository_read
             )
  end

  test "authorized fetch by id uses the transaction repo and canonical active records" do
    owner = active_user_fixture("id-fetch-owner")
    collaborator = active_user_fixture("id-fetch-collaborator")
    repository = personal_repository_fixture(owner)
    collaborator_fixture(repository, collaborator, :read)

    assert {:ok, {:ok, %Repository{id: repository_id}}} =
             Repo.transaction(fn ->
               ForgeRepos.fetch_authorized_repository_by_id(
                 collaborator,
                 repository.id,
                 :repository_read
               )
             end)

    assert repository_id == repository.id

    collaborator
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert {:ok, {:error, :not_found}} =
             Repo.transaction(fn ->
               ForgeRepos.fetch_authorized_repository_by_id(
                 collaborator,
                 repository.id,
                 :repository_read
               )
             end)
  end

  test "authorized fetch by id accepts active organization owners and masks inactive rows" do
    organization_owner = active_user_fixture("id-fetch-organization-owner")
    organization = organization_fixture("id-fetch-organization")
    organization_owner_fixture(organization, organization_owner)
    organization_repository = organization_repository_fixture(organization)

    assert {:ok, %Repository{id: organization_repository_id}} =
             ForgeRepos.fetch_authorized_repository_by_id(
               organization_owner,
               organization_repository.id,
               :repository_read
             )

    assert organization_repository_id == organization_repository.id

    public_repository =
      personal_repository_fixture(organization_owner,
        slug: "public-by-id",
        visibility: :public
      )

    assert {:ok, %Repository{id: public_repository_id}} =
             ForgeRepos.fetch_authorized_repository_by_id(
               nil,
               public_repository.id,
               :repository_read
             )

    assert public_repository_id == public_repository.id

    organization
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    public_repository
    |> Ecto.Changeset.change(deleted_at: ~U[2026-08-06 12:00:00Z])
    |> Repo.update!()

    assert {:error, :not_found} =
             ForgeRepos.fetch_authorized_repository_by_id(
               organization_owner,
               organization_repository.id,
               :repository_read
             )

    assert {:error, :not_found} =
             ForgeRepos.fetch_authorized_repository_by_id(
               nil,
               public_repository.id,
               :repository_read
             )
  end

  test "non-ready and deleted repository structs are rejected before every authorization role" do
    owner = active_user_fixture("hidden-owner")
    collaborator = active_user_fixture("hidden-collaborator")
    site_admin = active_user_fixture("hidden-site-admin", role: :admin)

    organization = organization_fixture("hidden-organization")
    organization_owner_fixture(organization, owner)
    organization_member = active_user_fixture("hidden-organization-member")
    organization_member_fixture(organization, organization_member)

    hidden_personal = [
      personal_repository_fixture(owner, slug: "importing", visibility: :public)
      |> hide_repository(:importing),
      personal_repository_fixture(owner, slug: "tombstoned", visibility: :public)
      |> hide_repository(:tombstoned),
      personal_repository_fixture(owner, slug: "ready-deleted", visibility: :public)
      |> hide_repository(:ready, ~U[2026-08-26 00:00:00Z])
    ]

    Enum.each(hidden_personal, &collaborator_fixture(&1, collaborator, :admin))

    for repository <- hidden_personal,
        actor <- [nil, owner, collaborator, site_admin],
        permission <- @permissions do
      refute Fornacast.Access.allowed?(actor, permission, repository)
      assert {:error, :unauthorized} = Fornacast.Access.authorize(actor, permission, repository)

      assert {:error, :not_found} =
               ForgeRepos.fetch_authorized_repository(
                 actor,
                 owner.username,
                 repository.slug,
                 permission
               )

      assert {:error, :not_found} =
               ForgeRepos.fetch_authorized_repository_by_id(actor, repository.id, permission)
    end

    hidden_organization =
      organization_repository_fixture(organization, slug: "organization-importing")
      |> hide_repository(:importing)

    for actor <- [owner, organization_member, site_admin], permission <- @permissions do
      refute Fornacast.Access.allowed?(actor, permission, hidden_organization)

      assert {:error, :unauthorized} =
               Fornacast.Access.authorize(actor, permission, hidden_organization)
    end
  end

  defp active_user_fixture(username, attrs \\ []) do
    user_fixture(username, Keyword.put_new(attrs, :state, :active))
  end

  defp disabled_user_fixture(username, attrs \\ []) do
    user_fixture(username, Keyword.put(attrs, :state, :disabled))
  end

  defp user_fixture(username, attrs) do
    %User{
      username: username,
      email: "#{username}@example.com",
      password_hash: "unused-in-access-tests",
      kind: :user,
      role: Keyword.get(attrs, :role, :user),
      state: Keyword.fetch!(attrs, :state)
    }
    |> Repo.insert!()
  end

  defp organization_fixture(username) do
    %Organization{
      username: username,
      email: "organization+#{username}@example.com",
      display_name: username,
      password_hash: "organization-account",
      kind: :organization,
      state: :active
    }
    |> Repo.insert!()
  end

  defp personal_repository_fixture(%User{} = owner, attrs \\ []) do
    repository_fixture(owner.id, attrs)
  end

  defp organization_repository_fixture(%Organization{} = organization, attrs \\ []) do
    repository_fixture(organization.id, attrs)
  end

  defp repository_fixture(owner_user_id, attrs) do
    slug = Keyword.get(attrs, :slug, "repository")

    %Repository{
      owner_user_id: owner_user_id,
      storage_path: "@test/#{owner_user_id}/#{slug}.git"
    }
    |> Repository.create_changeset(%{
      name: slug,
      slug: slug,
      visibility: Keyword.get(attrs, :visibility, :private),
      default_branch: "main"
    })
    |> Repo.insert!()
  end

  defp hide_repository(repository, lifecycle, deleted_at \\ nil) do
    repository
    |> Ecto.Changeset.change(lifecycle: lifecycle, deleted_at: deleted_at)
    |> Repo.update!()
  end

  defp organization_owner_fixture(%Organization{} = organization, %User{} = user) do
    organization_membership_fixture(organization, user, :owner)
  end

  defp organization_member_fixture(%Organization{} = organization, %User{} = user) do
    organization_membership_fixture(organization, user, :member)
  end

  defp organization_membership_fixture(organization, user, role) do
    %OrganizationMember{}
    |> OrganizationMember.changeset(%{
      organization_id: organization.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp collaborator_fixture(%Repository{} = repository, %User{} = user, role) do
    %Collaborator{}
    |> Collaborator.changeset(%{
      repository_id: repository.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert!()
  end

  defp assert_permissions(actor, repository, allowed_permissions) do
    Enum.each(@permissions, fn permission ->
      expected = if permission in allowed_permissions, do: :ok, else: {:error, :unauthorized}

      assert Fornacast.Access.authorize(actor, permission, repository) == expected
    end)
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(reset_tables(), &Ecto.Adapters.SQL.query!(Repo, "delete from #{&1}", []))
    end
  end

  defp reset_tables do
    [
      "audit_events",
      "repository_collaborators",
      "repositories",
      "organization_members",
      "api_keys",
      "ssh_keys",
      "users"
    ]
  end
end
