defmodule ForgeAccounts.NamespaceTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{Namespace, Organization, User}
  alias Fornacast.Repo

  @reserved ~w(assets health setup login logout issues pulls ssh-keys settings organizations repos imports api .well-known)

  setup do
    reset_database!()
    :ok
  end

  test "rejects reserved application namespace roots" do
    for root <- @reserved do
      assert {:error, :reserved} = Namespace.validate(root)
    end
  end

  test "normalizes valid namespace slugs" do
    assert {:ok, "acme-labs"} = Namespace.validate(" Acme-Labs ")
  end

  test "rejects invalid values and syntax" do
    for value <- [nil, :repos, "a", "-invalid", "invalid space"] do
      assert {:error, :invalid} = Namespace.validate(value)
    end
  end

  test "new user registration rejects reserved usernames" do
    changeset =
      User.registration_changeset(%User{}, %{
        username: "repos",
        email: "user@example.test",
        password: "correct horse battery staple",
        role: :user,
        state: :active
      })

    assert "is reserved" in errors_on(changeset, :username)
  end

  test "new organization changeset rejects reserved usernames" do
    changeset = Organization.changeset(%Organization{}, %{username: "repos"})

    assert "is reserved" in errors_on(changeset, :username)
  end

  test "existing persisted reserved rows remain readable" do
    user =
      Repo.insert!(%User{
        username: "repos",
        email: "legacy@example.test",
        password_hash: "test-password-hash",
        kind: :user,
        role: :user,
        state: :active
      })

    id = user.id
    assert %User{id: ^id, username: "repos"} = ForgeAccounts.get_user_by_username("repos")
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(&elem(&1, 0))
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        for table <- [
              "audit_events",
              "repository_collaborators",
              "repositories",
              "organization_members",
              "api_keys",
              "ssh_keys",
              "users"
            ] do
          Ecto.Adapters.SQL.query!(Repo, "delete from #{table}", [])
        end
    end
  end
end
