defmodule ForgeAccounts.UserAppearanceTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias ForgeAccounts.User
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{user: user_fixture("appearance")}
  end

  test "new users default to auto", %{user: user} do
    assert %User{theme_preference: "auto"} = user
    assert %User{theme_preference: "auto"} = Repo.reload!(user)
  end

  test "the database supplies auto when no preference is inserted" do
    username = unique("default")

    assert {1, [%{theme_preference: "auto"}]} =
             Repo.insert_all(
               "users",
               [
                 %{
                   username: username,
                   email: "#{username}@example.test",
                   password_hash: "test-password-hash",
                   inserted_at: DateTime.utc_now(:second),
                   updated_at: DateTime.utc_now(:second)
                 }
               ],
               returning: [:theme_preference]
             )
  end

  test "saves every supported preference including the current value", %{user: user} do
    for theme <- ["auto", "sunshine", "moonlight", "auto"] do
      assert {:ok, %User{theme_preference: ^theme}} =
               ForgeAccounts.update_user_appearance(user, %{"theme_preference" => theme})

      assert %User{theme_preference: ^theme} = Repo.reload!(user)
    end

    assert {:ok, %User{theme_preference: "sunshine"}} =
             ForgeAccounts.update_user_appearance(user, %{theme_preference: "sunshine"})
  end

  test "invalid and missing values fail without changing the saved theme", %{user: user} do
    assert {:ok, user} =
             ForgeAccounts.update_user_appearance(user, %{theme_preference: "moonlight"})

    for attrs <- [
          %{},
          %{username: "ignored"},
          %{theme_preference: nil},
          %{theme_preference: ""},
          %{theme_preference: "   "},
          %{theme_preference: "dark"},
          %{theme_preference: " moonlight "},
          %{theme_preference: 123},
          %{"theme_preference" => ["sunshine"]}
        ] do
      assert {:error, %Changeset{} = changeset} =
               ForgeAccounts.update_user_appearance(user, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :theme_preference)
      assert %User{theme_preference: "moonlight"} = Repo.reload!(user)
    end
  end

  test "appearance updates ignore identity and privilege fields", %{user: user} do
    assert {:ok, updated} =
             ForgeAccounts.update_user_appearance(user, %{
               theme_preference: "sunshine",
               id: user.id + 1,
               username: "changed",
               email: "changed@example.test",
               password: "changed password",
               password_hash: "changed hash",
               kind: :organization,
               role: :admin,
               state: :disabled,
               display_name: "Changed",
               description: "Changed"
             })

    assert Map.drop(Map.from_struct(updated), [:theme_preference, :updated_at]) ==
             Map.drop(Map.from_struct(user), [:theme_preference, :updated_at])

    assert %User{theme_preference: "sunshine"} = Repo.reload!(user)
  end

  test "an appearance update only affects its actor", %{user: user} do
    other_user = user_fixture("other")

    assert {:ok, %User{id: id, theme_preference: "moonlight"}} =
             ForgeAccounts.update_user_appearance(user, %{
               theme_preference: "moonlight",
               user_id: other_user.id,
               id: other_user.id
             })

    assert id == user.id
    assert %User{theme_preference: "auto"} = Repo.reload!(other_user)
  end

  test "inactive and missing actors are rejected using persisted identity", %{user: user} do
    Repo.update!(User.state_changeset(user, %{state: :disabled}))

    for actor <- [user, %{user | role: :admin}, %User{id: 2_147_483_647}, nil] do
      assert {:error, :forbidden} =
               ForgeAccounts.update_user_appearance(actor, %{theme_preference: "sunshine"})
    end

    assert %User{theme_preference: "auto"} = Repo.reload!(user)
  end

  test "session identity retains user fields while excluding saved configuration and secrets",
       %{user: user} do
    assert {:ok, user} =
             ForgeAccounts.update_user_appearance(user, %{theme_preference: "moonlight"})

    session_user = ForgeAccounts.get_session_user(user.id)

    assert %User{theme_preference: "auto", password_hash: nil, password: nil} = session_user

    assert Map.drop(Map.from_struct(session_user), [:theme_preference, :password_hash]) ==
             Map.drop(Map.from_struct(user), [:theme_preference, :password_hash])

    assert nil == ForgeAccounts.get_session_user(2_147_483_647)

    Repo.update!(User.state_changeset(user, %{state: :disabled}))
    assert %User{state: :disabled} = ForgeAccounts.get_session_user(user.id)

    assert {:ok, organization} =
             ForgeAccounts.create_organization(user_fixture("owner"), %{
               username: unique("organization")
             })

    assert nil == ForgeAccounts.get_session_user(organization.id)
  end

  test "the database check rejects unsupported themes", %{user: user} do
    changeset =
      user
      |> Changeset.change(theme_preference: "unsupported")
      |> Changeset.check_constraint(:theme_preference, name: :users_theme_preference_check)

    assert {:error, %Changeset{} = rejected} = Repo.update(changeset, mode: :savepoint)
    assert Keyword.has_key?(rejected.errors, :theme_preference)
    assert %User{theme_preference: "auto"} = Repo.reload!(user)
  end

  defp user_fixture(prefix) do
    username = unique(prefix)

    Repo.insert!(%User{
      username: username,
      email: "#{username}@example.test",
      password_hash: "test-password-hash"
    })
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
