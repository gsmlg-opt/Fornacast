defmodule ForgeAccountsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ForgeAccounts.{Organization, SSHKey, User}
  alias Fornacast.Repo

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
      "ssh_keys",
      "users"
    ]
  end
end
