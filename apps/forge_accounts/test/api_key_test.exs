defmodule ForgeAccounts.APIKeyTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{APIKey, User}
  alias Fornacast.Repo

  setup do
    reset_database!()

    {:ok, user} =
      ForgeAccounts.create_user(%{
        username: "alice",
        email: "alice@example.com",
        password: "correct horse battery staple"
      })

    %{user: user}
  end

  test "creates a named key and returns its secret only once", %{user: user} do
    assert {:ok, %APIKey{} = api_key, "fc_pat_" <> _ = secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "workstation",
               "scopes" => ["repo:read", "repo:write"]
             })

    assert api_key.name == "workstation"
    assert api_key.scopes == %{"repo:read" => true, "repo:write" => true}
    assert api_key.token_prefix == String.slice(secret, 0, 15)
    refute api_key.token_hash == secret

    persisted_key = Repo.reload!(api_key)
    expected_hash = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

    assert persisted_key.token_hash == expected_hash
    refute persisted_key.token_hash == secret
    refute persisted_key.token_prefix == secret
    refute inspect(persisted_key) =~ secret

    assert [%APIKey{id: id, name: "workstation"}] = ForgeAccounts.list_user_api_keys(user)
    assert id == api_key.id
  end

  test "authenticates allowed scopes and records successful use", %{user: user} do
    assert {:ok, write_key, write_secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "writer",
               "scopes" => ["repo:write"]
             })

    assert {:ok, authenticated_user, authenticated_key} =
             ForgeAccounts.authenticate_api_key("alice", write_secret, "repo:read")

    assert authenticated_user.id == user.id
    assert authenticated_key.id == write_key.id
    assert authenticated_key.last_used_at

    assert {:ok, _read_key, read_secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "reader",
               "scopes" => ["repo:read"]
             })

    assert {:error, :insufficient_scope} =
             ForgeAccounts.authenticate_api_key("alice", read_secret, "repo:write")

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key("alice", "fc_pat_invalid", "repo:read")

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key("bob", write_secret, "repo:read")
  end

  test "rejects expired and revoked keys and protects ownership", %{user: user} do
    assert {:ok, expired_key, expired_secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "expired",
               "scopes" => ["repo:read"],
               "expires_at" => DateTime.add(DateTime.utc_now(), -60, :second)
             })

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key("alice", expired_secret, "repo:read")

    assert is_nil(Repo.reload!(expired_key).last_used_at)

    {:ok, bob} =
      ForgeAccounts.create_user(%{
        username: "bob",
        email: "bob@example.com",
        password: "correct horse battery staple"
      })

    assert {:error, :not_found} = ForgeAccounts.revoke_api_key(bob, expired_key.id)
    assert {:ok, revoked_key} = ForgeAccounts.revoke_api_key(user, expired_key.id)
    assert revoked_key.revoked_at
    assert {:error, :not_found} = ForgeAccounts.revoke_api_key(user, expired_key.id)
  end

  test "revoked keys cannot authenticate and do not record use", %{user: user} do
    assert {:ok, api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "revoked",
               "scopes" => ["repo:write"]
             })

    assert {:ok, revoked_key} = ForgeAccounts.revoke_api_key(user, api_key.id)
    assert is_nil(revoked_key.last_used_at)

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key("alice", secret, "repo:read")

    assert is_nil(Repo.reload!(api_key).last_used_at)
  end

  test "keys stop authenticating when their user is disabled", %{user: user} do
    assert {:ok, api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "disabled owner",
               "scopes" => ["repo:read"]
             })

    assert {:ok, _disabled_user} =
             user
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key("alice", secret, "repo:read")

    assert is_nil(Repo.reload!(api_key).last_used_at)
  end

  test "requires active users and valid creation scopes", %{user: user} do
    assert {:error, changeset} =
             ForgeAccounts.create_api_key(user, %{"name" => "bad", "scopes" => ["admin"]})

    assert %{scopes: [_ | _]} = errors_on(changeset)

    assert {:ok, disabled_user} =
             user
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :unauthorized} =
             ForgeAccounts.create_api_key(disabled_user, %{
               "name" => "blocked",
               "scopes" => ["repo:read"]
             })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(["api_keys", "users"], &Ecto.Adapters.SQL.query!(Repo, "delete from #{&1}", []))
    end
  end
end
