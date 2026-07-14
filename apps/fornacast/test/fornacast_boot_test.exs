defmodule Fornacast.BootTest do
  use ExUnit.Case, async: false

  alias Fornacast.Setup

  setup do
    development_admin = Application.get_env(:fornacast, :development_admin)

    Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)
    Setup.reset!()

    on_exit(fn ->
      restore_development_admin!(development_admin)

      # Turso :auto mode does not roll back; remove rows this test inserted
      # so reruns start clean (unique username/email would otherwise clash).
      Enum.each(["audit_events", "organization_members", "users"], fn table ->
        Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{table}", [])
      end)

      Setup.reset!()
    end)

    :ok
  end

  test "heal_initialization self-heals when an admin already exists without the flag" do
    {:ok, _admin} =
      ForgeAccounts.create_admin(%{
        username: "root",
        email: "root@example.com",
        password: "correct horse battery staple"
      })

    refute Setup.initialized?()
    assert :ok = Fornacast.Application.heal_initialization()
    assert Setup.initialized?()
  end

  test "heal_initialization leaves a truly fresh install uninitialized" do
    assert :ok = Fornacast.Application.heal_initialization()
    refute Setup.initialized?()
  end

  test "development admin bootstrap is disabled when not configured" do
    Application.delete_env(:fornacast, :development_admin)

    assert :ok = Fornacast.Application.ensure_development_admin()
    refute ForgeAccounts.admin_exists?()
    refute Setup.initialized?()
  end

  test "development admin bootstrap creates the configured admin and initializes setup" do
    Application.put_env(:fornacast, :development_admin,
      username: "admin",
      email: "admin@fornacast.invalid",
      password: "admin"
    )

    assert :ok = Fornacast.Application.ensure_development_admin()
    assert {:ok, %{role: :admin}} = ForgeAccounts.authenticate_password("admin", "admin")
    assert Setup.initialized?()
  end

  test "development admin bootstrap repairs an existing configured admin" do
    {:ok, _admin} =
      ForgeAccounts.create_admin(%{
        username: "admin",
        email: "admin@fornacast.invalid",
        password: "correct horse battery staple"
      })

    assert {:error, :invalid_credentials} = ForgeAccounts.authenticate_password("admin", "admin")

    Application.put_env(:fornacast, :development_admin,
      username: "admin",
      email: "admin@fornacast.invalid",
      password: "admin"
    )

    assert :ok = Fornacast.Application.ensure_development_admin()
    assert {:ok, %{role: :admin}} = ForgeAccounts.authenticate_password("admin", "admin")
    assert Setup.initialized?()
  end

  test "prepare_boot ensures the repository storage root exists" do
    root = Fornacast.Config.repo_storage_root()
    File.rm_rf!(root)
    refute File.dir?(root)

    assert :ok = Fornacast.Application.prepare_boot()
    assert File.dir?(root)
  end

  defp restore_development_admin!(nil), do: Application.delete_env(:fornacast, :development_admin)

  defp restore_development_admin!(development_admin) do
    Application.put_env(:fornacast, :development_admin, development_admin)
  end
end
