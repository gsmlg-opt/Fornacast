defmodule ForgeAccountsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias ForgeAccounts.{Organization, SSHKey, User}
  alias Fornacast.{AuditEvent, Page, Repo}

  @ed25519_public_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINUKfpNn72l8H0YnXfbkh6s4aAcrMmVsBWPfyPppa1i8 gao@mac-mini"
  @ssh_rsa_public_key "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDV1NesYIP9xVEoK4BnP7t9fTJYErDo2dz1jYLogURcVP0a0WoxcxMZf4TjBKGnC6BMvbuCAuNkRqmiKZow+GlSn2wl0hssXTz6cwwYYFM6ohTdUrAdJAilQbWWrWqscl19IBDYPG3D0bQaJG9wEqlF2CxE+2x99Rdc8uVQh4ATYRraJc1vTOJzi0mVWbzH3LIDhDRewDhL3djdtQ9vAsROYplRPzWgB0XcEXfwDXFycHGkUI+aGLI8+PnKaFGkP8jB3SyQZRTPi62XopkOCIiUEteaRMQvn7AcccAc/+LwKYWu+NDtegnBbHFlRMnAr0gInrVnHIg7R0wlGIOqhJt9 rsa@example.test"

  setup do
    reset_database!()
  end

  test "registration changeset hashes passwords" do
    changeset =
      User.registration_changeset(%User{}, %{
        username: "Alice",
        email: "Alice@example.com",
        password: "correct horse battery staple",
        role: :admin,
        state: :active
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :username) == "alice"
    password_hash = Ecto.Changeset.get_change(changeset, :password_hash)
    assert is_binary(password_hash)
    assert password_hash != "correct horse battery staple"
  end

  test "registration changeset rejects short passwords" do
    changeset =
      User.registration_changeset(%User{}, %{
        username: "alice",
        email: "alice@example.com",
        password: "short",
        role: :user,
        state: :active
      })

    refute changeset.valid?
    assert [password: {"should be at least %{count} character(s)", _meta}] = changeset.errors
  end

  test "ssh key changeset stores a SHA256 fingerprint" do
    changeset =
      SSHKey.changeset(%SSHKey{user_id: 1}, %{
        title: "laptop",
        public_key: @ed25519_public_key
      })

    assert changeset.valid?
    assert "SHA256:" <> _ = Ecto.Changeset.get_change(changeset, :fingerprint_sha256)
  end

  test "ssh key changeset accepts a standard OpenSSH RSA public key" do
    changeset =
      SSHKey.changeset(%SSHKey{user_id: 1}, %{
        title: "servers",
        public_key: @ssh_rsa_public_key
      })

    assert changeset.valid?
    assert "SHA256:" <> _ = Ecto.Changeset.get_change(changeset, :fingerprint_sha256)
  end

  test "ssh key changeset rejects RSA moduli smaller than 2048 bits" do
    for bits <- [512, 1024] do
      changeset =
        SSHKey.changeset(%SSHKey{user_id: 1}, %{
          title: "weak-#{bits}",
          public_key: rsa_public_key(bits, 65_537)
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :public_key)
    end
  end

  test "ssh key changeset rejects unsafe RSA public exponents" do
    [{{:RSAPublicKey, modulus, _exponent}, _attrs}] =
      :ssh_file.decode(@ssh_rsa_public_key, :auth_keys)

    for exponent <- [3, 65_536] do
      blob = :ssh_message.ssh2_pubkey_encode({:RSAPublicKey, modulus, exponent})

      changeset =
        SSHKey.changeset(%SSHKey{user_id: 1}, %{
          title: "unsafe-exponent-#{exponent}",
          public_key: "ssh-rsa " <> Base.encode64(blob)
        })

      refute changeset.valid?
    end
  end

  test "ssh key changeset rejects an oversized RSA public exponent" do
    [{{:RSAPublicKey, modulus, _exponent}, _attrs}] =
      :ssh_file.decode(@ssh_rsa_public_key, :auth_keys)

    blob = :ssh_message.ssh2_pubkey_encode({:RSAPublicKey, modulus, modulus + 2})

    changeset =
      SSHKey.changeset(%SSHKey{user_id: 1}, %{
        title: "oversized-exponent",
        public_key: "ssh-rsa " <> Base.encode64(blob)
      })

    refute changeset.valid?
  end

  test "ssh key changeset rejects a key whose label does not match its blob" do
    public_key = String.replace(@ed25519_public_key, "ssh-ed25519", "ssh-rsa", global: false)

    changeset =
      SSHKey.changeset(%SSHKey{user_id: 1}, %{title: "mislabeled", public_key: public_key})

    refute changeset.valid?
    assert [public_key: {"is not a valid OpenSSH public key", _meta}] = changeset.errors
  end

  test "ssh key changeset rejects malformed decoded key blobs" do
    changeset =
      SSHKey.changeset(%SSHKey{user_id: 1}, %{
        title: "malformed",
        public_key: "ssh-rsa Z2FyYmFnZQ=="
      })

    refute changeset.valid?
    assert [public_key: {"is not a valid OpenSSH public key", _meta}] = changeset.errors
  end

  test "ssh key changeset rejects unsupported algorithms" do
    public_key = String.replace(@ed25519_public_key, "ssh-ed25519", "ssh-dss", global: false)
    changeset = SSHKey.changeset(%SSHKey{user_id: 1}, %{title: "legacy", public_key: public_key})

    refute changeset.valid?

    assert [public_key: {"must use ssh-ed25519 or ssh-rsa", _meta}] =
             changeset.errors
  end

  test "first admin bootstrap refuses to create a second admin" do
    attrs = %{
      username: "alice",
      email: "alice@example.com",
      password: "correct horse battery staple"
    }

    assert {:ok, %User{role: :admin} = user} = ForgeAccounts.create_first_admin(attrs)
    assert user.password_hash != attrs.password

    assert {:error, :admin_exists} =
             ForgeAccounts.create_first_admin(%{
               username: "bob",
               email: "bob@example.com",
               password: "correct horse battery staple"
             })
  end

  test "organizations share the account namespace and grant owner membership" do
    assert {:ok, owner} =
             ForgeAccounts.create_user(%{
               username: "Alice",
               email: "alice-org-owner@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_organization(owner, %{
               username: "Acme",
               display_name: "ACME Engineering",
               description: "compiler tools"
             })

    assert organization.username == "acme"
    assert organization.display_name == "ACME Engineering"
    assert organization.kind == :organization
    assert organization.email == "organization+acme@fornacast.invalid"

    refute ForgeAccounts.get_user_by_username("acme")

    assert %{id: organization_id, kind: :organization} =
             ForgeAccounts.get_account_by_username("acme")

    assert organization_id == organization.id
    assert [^organization] = ForgeAccounts.list_user_organizations(owner)
    assert ForgeAccounts.organization_role(owner, organization) == :owner

    assert {:error, %Ecto.Changeset{} = changeset} =
             ForgeAccounts.create_organization(owner, %{
               username: "alice",
               display_name: "Duplicate"
             })

    refute changeset.valid?
  end

  test "organization profile changeset maps compatible fields without creation fallback" do
    organization = %Organization{display_name: nil, description: nil, username: "acme"}

    changeset =
      Organization.profile_changeset(organization, %{
        "name" => "  ACME Engineering  ",
        "description" => "  Compiler tools  ",
        "username" => "ignored"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :display_name) == "ACME Engineering"
    assert Ecto.Changeset.get_change(changeset, :description) == "Compiler tools"
    refute Ecto.Changeset.get_change(changeset, :username)

    no_name = Organization.profile_changeset(organization, %{"description" => nil})
    assert no_name.valid?
    assert Ecto.Changeset.get_field(no_name, :display_name) == nil
    assert Ecto.Changeset.get_change(no_name, :description) == nil

    whitespace_name = Organization.profile_changeset(organization, %{"name" => "   "})
    refute whitespace_name.valid?
    assert Keyword.has_key?(whitespace_name.errors, :display_name)

    long_name =
      Organization.profile_changeset(organization, %{"name" => String.duplicate("n", 121)})

    refute long_name.valid?
    assert Keyword.has_key?(long_name.errors, :display_name)

    long_description =
      Organization.profile_changeset(organization, %{
        "description" => String.duplicate("d", 501)
      })

    refute long_description.valid?
    assert Keyword.has_key?(long_description.errors, :description)

    nul_creation =
      Organization.changeset(%Organization{}, %{
        "username" => "safe-org",
        "display_name" => "bad\0name",
        "description" => "bad\0description"
      })

    refute nul_creation.valid?
    assert Keyword.has_key?(nul_creation.errors, :display_name)
    assert Keyword.has_key?(nul_creation.errors, :description)

    nul_profile =
      Organization.profile_changeset(organization, %{
        "name" => "bad\0name",
        "description" => "bad\0description"
      })

    refute nul_profile.valid?
    assert Keyword.has_key?(nul_profile.errors, :display_name)
    assert Keyword.has_key?(nul_profile.errors, :description)
  end

  test "organization profile changeset normalizes mixed keys with string-key precedence" do
    organization = %Organization{display_name: nil, description: nil, username: "acme"}

    changeset =
      Organization.profile_changeset(organization, %{
        "name" => "String name",
        :name => "Atom name",
        "description" => "String description",
        :description => "Atom description"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :display_name) == "String name"
    assert Ecto.Changeset.get_change(changeset, :description) == "String description"
  end

  test "ordinary users create self-owned organizations with an audit event" do
    actor = user!("alice")

    assert {:ok, %Organization{} = organization} =
             ForgeAccounts.create_api_organization(
               actor,
               %{
                 "login" => "  Acme  ",
                 "admin" => "  ALICE  ",
                 "profile_name" => "  ACME Engineering  "
               },
               %{
                 request_id: "request-1",
                 ip_address: "127.0.0.1",
                 user_agent: "ExUnit"
               }
             )

    assert organization.username == "acme"
    assert organization.display_name == "ACME Engineering"
    assert organization.kind == :organization
    assert ForgeAccounts.organization_role(actor, organization) == :owner

    assert %AuditEvent{} =
             audit =
             Repo.get_by!(AuditEvent,
               action: "organization.created",
               target_type: "organization",
               target_id: Integer.to_string(organization.id)
             )

    assert audit.actor_user_id == actor.id
    assert audit.ip_address == "127.0.0.1"
    assert audit.user_agent == "ExUnit"
    assert audit.metadata["login"] == "acme"
    assert audit.metadata["admin"] == "alice"
    assert audit.metadata["result"] == "success"
    assert audit.metadata["request_id"] == "request-1"
  end

  test "active site administrators can assign another active user as organization owner" do
    site_admin = user!("site-admin", role: :admin)
    target = user!("bob")

    assert {:ok, organization} =
             ForgeAccounts.create_api_organization(
               site_admin,
               %{"login" => "tools-team", "admin" => " BOB ", "profile_name" => nil},
               %{}
             )

    assert organization.display_name == "tools-team"
    assert ForgeAccounts.organization_role(target, organization) == :owner
    assert ForgeAccounts.organization_role(site_admin, organization) == nil

    assert %AuditEvent{actor_user_id: actor_id, metadata: metadata} =
             Repo.get_by!(AuditEvent, action: "organization.created")

    assert actor_id == site_admin.id
    assert metadata["admin"] == "bob"
  end

  test "organization creation rejects unauthorized and inactive actors and targets" do
    alice = user!("alice")
    bob = user!("bob")
    inactive_actor = user!("inactive-actor", state: :disabled)
    inactive_target = user!("inactive-target", state: :disabled)
    site_admin = user!("site-admin", role: :admin)

    assert {:error, :forbidden} =
             ForgeAccounts.create_api_organization(
               alice,
               %{"login" => "alice-tools", "admin" => bob.username},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeAccounts.create_api_organization(
               inactive_actor,
               %{"login" => "inactive-tools", "admin" => inactive_actor.username},
               %{}
             )

    assert {:error, {:validation, [%{resource: "Organization", field: "admin", code: :invalid}]}} =
             ForgeAccounts.create_api_organization(
               site_admin,
               %{"login" => "target-tools", "admin" => inactive_target.username},
               %{}
             )

    refute ForgeAccounts.get_account_by_username("alice-tools")
    refute ForgeAccounts.get_account_by_username("inactive-tools")
    refute ForgeAccounts.get_account_by_username("target-tools")
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "organization creation returns fixed pre-transaction validation errors" do
    actor = user!("alice")

    assert {:error, {:validation, errors}} =
             ForgeAccounts.create_api_organization(
               actor,
               %{"login" => " ", "admin" => nil, "profile_name" => 123},
               %{}
             )

    assert errors == [
             %{resource: "Organization", field: "login", code: :invalid},
             %{resource: "Organization", field: "admin", code: :missing_field},
             %{resource: "Organization", field: "profile_name", code: :invalid}
           ]

    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "organization creation rejects NUL bytes before lookup or insertion" do
    actor = user!("alice")

    assert {:error, {:validation, [%{resource: "Organization", field: "admin", code: :invalid}]}} =
             ForgeAccounts.create_api_organization(
               actor,
               %{"login" => "admin-nul", "admin" => "alice\0other"},
               %{}
             )

    assert {:error,
            {:validation, [%{resource: "Organization", field: "profile_name", code: :invalid}]}} =
             ForgeAccounts.create_api_organization(
               actor,
               %{
                 "login" => "profile-nul",
                 "admin" => "alice",
                 "profile_name" => "bad\0profile"
               },
               %{}
             )

    assert {:error, {:validation, [%{resource: "Organization", field: "login", code: :invalid}]}} =
             ForgeAccounts.create_api_organization(
               actor,
               %{"login" => "bad\0login", "admin" => "alice"},
               %{}
             )

    refute ForgeAccounts.get_account_by_username("admin-nul")
    refute ForgeAccounts.get_account_by_username("profile-nul")
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "organization creation maps the database uniqueness constraint to login already_exists" do
    actor = user!("alice")
    _existing = user!("taken")

    assert {:error,
            {:validation, [%{resource: "Organization", field: "login", code: :already_exists}]}} =
             ForgeAccounts.create_api_organization(
               actor,
               %{"login" => "TAKEN", "admin" => "alice"},
               %{}
             )

    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "owners and active site administrators update organization profiles atomically" do
    owner = user!("alice")
    site_admin = user!("site-admin", role: :admin)
    organization = api_organization!(owner, "acme")

    assert {:ok, owner_updated} =
             ForgeAccounts.update_organization(
               owner,
               organization,
               %{"name" => "  ACME Engineering  ", "description" => "  Compiler tools  "},
               %{request_id: "update-1"}
             )

    assert owner_updated.display_name == "ACME Engineering"
    assert owner_updated.description == "Compiler tools"

    assert {:ok, admin_updated} =
             ForgeAccounts.update_organization(
               site_admin,
               owner_updated,
               %{"name" => nil, "description" => nil},
               %{request_id: "update-2"}
             )

    assert admin_updated.display_name == nil
    assert admin_updated.description == nil

    assert [created, owner_audit, admin_audit] =
             AuditEvent
             |> order_by([event], asc: event.id)
             |> Repo.all()

    assert created.action == "organization.created"
    assert owner_audit.action == "organization.updated"
    assert owner_audit.actor_user_id == owner.id
    assert owner_audit.metadata["result"] == "success"
    assert owner_audit.metadata["request_id"] == "update-1"
    assert admin_audit.action == "organization.updated"
    assert admin_audit.actor_user_id == site_admin.id
    assert admin_audit.metadata["result"] == "success"
    assert admin_audit.metadata["request_id"] == "update-2"
  end

  test "organization updates reject members, inactive actors, and wrong account kinds" do
    owner = user!("alice")
    member = user!("bob")
    inactive_owner = user!("inactive-owner")
    organization = api_organization!(owner, "acme")
    inactive_owned = api_organization!(inactive_owner, "inactive-owned")

    inactive_owner =
      inactive_owner
      |> User.state_changeset(%{state: :disabled})
      |> Repo.update!()

    assert {:ok, _membership} = ForgeAccounts.add_organization_member(organization, member)

    assert {:error, :forbidden} =
             ForgeAccounts.update_organization(
               member,
               organization,
               %{"name" => "Member edit"},
               %{}
             )

    assert {:error, :forbidden} =
             ForgeAccounts.update_organization(
               inactive_owner,
               inactive_owned,
               %{"name" => "Inactive edit"},
               %{}
             )

    organization_as_user = Repo.get!(User, organization.id)

    assert {:error, :forbidden} =
             ForgeAccounts.update_organization(
               organization_as_user,
               organization,
               %{"name" => "Wrong kind"},
               %{}
             )

    assert Repo.get!(Organization, organization.id).display_name == "acme"
    assert Repo.get!(Organization, inactive_owned.id).display_name == "inactive-owned"
  end

  test "organization update maps display name validation errors to the compatible name field" do
    owner = user!("alice")
    organization = api_organization!(owner, "acme")

    assert {:error, {:validation, [%{resource: "Organization", field: "name", code: :invalid}]}} =
             ForgeAccounts.update_organization(
               owner,
               organization,
               %{"name" => "   "},
               %{}
             )

    assert Repo.get!(Organization, organization.id).display_name == "acme"
  end

  test "organization updates reject NUL bytes" do
    owner = user!("alice")
    organization = api_organization!(owner, "acme")

    assert {:error, {:validation, [%{resource: "Organization", field: "name", code: :invalid}]}} =
             ForgeAccounts.update_organization(
               owner,
               organization,
               %{"name" => "bad\0name"},
               %{}
             )

    assert {:error,
            {:validation, [%{resource: "Organization", field: "description", code: :invalid}]}} =
             ForgeAccounts.update_organization(
               owner,
               organization,
               %{"description" => "bad\0description"},
               %{}
             )
  end

  test "organization updates accept mixed key families" do
    owner = user!("alice")
    organization = api_organization!(owner, "acme")

    assert {:ok, updated} =
             ForgeAccounts.update_organization(
               owner,
               organization,
               %{"name" => "ACME", description: "tools"},
               %{}
             )

    assert updated.display_name == "ACME"
    assert updated.description == "tools"
  end

  test "public getters normalize login and return only active correctly typed accounts" do
    active_user = user!("alice")
    disabled_user = user!("disabled-user", state: :disabled)
    organization = api_organization!(active_user, "acme")
    disabled_organization = api_organization!(active_user, "disabled-org")

    disabled_organization
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert {:ok, %User{id: user_id}} = ForgeAccounts.get_public_user(" ALICE ")
    assert user_id == active_user.id

    assert {:ok, %Organization{id: organization_id}} =
             ForgeAccounts.get_public_organization(" ACME ")

    assert organization_id == organization.id
    assert {:error, :not_found} = ForgeAccounts.get_public_user(organization.username)
    assert {:error, :not_found} = ForgeAccounts.get_public_organization(active_user.username)
    assert {:error, :not_found} = ForgeAccounts.get_public_user(disabled_user.username)

    assert {:error, :not_found} =
             ForgeAccounts.get_public_organization(disabled_organization.username)
  end

  test "paginated organization listing is deterministic and excludes disabled organizations" do
    owner = user!("alice")
    alpha = api_organization!(owner, "alpha")
    beta = api_organization!(owner, "beta")
    charlie = api_organization!(owner, "charlie")
    disabled = api_organization!(owner, "disabled")

    disabled
    |> Ecto.Changeset.change(state: :disabled)
    |> Repo.update!()

    assert [
             %Organization{username: "alpha"},
             %Organization{username: "beta"},
             %Organization{username: "charlie"},
             %Organization{username: "disabled"}
           ] =
             ForgeAccounts.list_user_organizations(owner)

    assert {:ok,
            %Page{
              entries: [page_alpha, page_beta],
              total: 3,
              page: 1,
              per_page: 2
            }} = ForgeAccounts.list_user_organizations(owner, page: 1, per_page: 2)

    assert [page_alpha.id, page_beta.id] == [alpha.id, beta.id]

    assert {:ok, %Page{entries: [page_charlie], total: 3, page: 2, per_page: 2}} =
             ForgeAccounts.list_user_organizations(owner, page: 2, per_page: 2)

    assert page_charlie.id == charlie.id
  end

  test "organization creation rolls back the account and membership when audit metadata is invalid" do
    actor = user!("alice")

    assert {:error,
            {:validation, [%{resource: "Organization", field: "base", code: :unprocessable}]}} =
             ForgeAccounts.create_api_organization(
               actor,
               %{"login" => "rolled-back", "admin" => "alice"},
               %{ip_address: {:invalid, :ip}}
             )

    refute ForgeAccounts.get_account_by_username("rolled-back")
    assert ForgeAccounts.list_user_organizations(actor) == []
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "admin create mix task creates the first admin" do
    Mix.Task.clear()

    output =
      capture_io(fn ->
        Mix.Tasks.Fornacast.Admin.Create.run([
          "--username",
          "admin",
          "--email",
          "admin@example.com",
          "--password",
          "correct horse battery staple"
        ])
      end)

    assert output =~ "Created admin user admin"
    assert %User{role: :admin} = ForgeAccounts.get_user_by_username("admin")
  end

  test "disabled users cannot authenticate with a valid password" do
    assert {:ok, user} =
             ForgeAccounts.create_user(%{
               username: "disabled",
               email: "disabled@example.com",
               password: "correct horse battery staple"
             })

    assert {:ok, _user} =
             user
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_password("disabled", "correct horse battery staple")
  end

  defp rsa_public_key(bits, exponent) do
    {:RSAPrivateKey, _, modulus, ^exponent, _, _, _, _, _, _, _} =
      :public_key.generate_key({:rsa, bits, exponent})

    blob = :ssh_message.ssh2_pubkey_encode({:RSAPublicKey, modulus, exponent})
    "ssh-rsa " <> Base.encode64(blob)
  end

  defp user!(username, opts \\ []) do
    role = Keyword.get(opts, :role, :user)
    state = Keyword.get(opts, :state, :active)

    Repo.insert!(%User{
      username: username,
      email: "#{username}@example.test",
      password_hash: "test-password-hash",
      kind: :user,
      role: role,
      state: state
    })
  end

  defp api_organization!(owner, login, opts \\ []) do
    actor = Keyword.get(opts, :actor, owner)

    assert {:ok, organization} =
             ForgeAccounts.create_api_organization(
               actor,
               %{"login" => login, "admin" => owner.username},
               %{}
             )

    organization
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
