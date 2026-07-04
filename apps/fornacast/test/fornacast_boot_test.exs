defmodule Fornacast.BootTest do
  use ExUnit.Case, async: false

  alias Fornacast.Setup

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)
    Setup.reset!()

    on_exit(fn ->
      # Turso :auto mode does not roll back; remove rows this test inserted
      # so reruns start clean (unique username/email would otherwise clash).
      Enum.each(["audit_events", "users"], fn table ->
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

  test "prepare_boot ensures the repository storage root exists" do
    root = Fornacast.Config.repo_storage_root()
    File.rm_rf!(root)
    refute File.dir?(root)

    assert :ok = Fornacast.Application.prepare_boot()
    assert File.dir?(root)
  end
end
