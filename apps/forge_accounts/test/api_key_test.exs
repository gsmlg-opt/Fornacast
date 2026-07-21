defmodule ForgeAccounts.APIKeyTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.{APIKey, APIScope, User}
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
    assert APIKey.classic_scopes() == ["repo", "public_repo", "read:org", "write:org"]
    assert APIKey.legacy_scopes() == ["repo:read", "repo:write"]

    assert {:ok, %APIKey{} = api_key, "fc_pat_" <> _ = secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "workstation",
               "scopes" => ["repo", "write:org"]
             })

    assert api_key.name == "workstation"
    assert api_key.scopes == %{"repo" => true, "write:org" => true}
    assert api_key.token_prefix == String.slice(secret, 0, 15)
    refute api_key.token_hash == secret

    persisted_key = Repo.reload!(api_key)
    expected_hash = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

    assert persisted_key.token_hash == expected_hash
    refute persisted_key.token_hash == secret
    refute persisted_key.token_prefix == secret
    refute inspect(persisted_key) =~ secret

    assert [%APIKey{id: id, name: "workstation", token_hash: nil}] =
             ForgeAccounts.list_user_api_keys(user)

    assert id == api_key.id
  end

  test "normalizes atom-key scope attributes", %{user: user} do
    assert {:ok, %APIKey{scopes: %{"public_repo" => true}}, _secret} =
             ForgeAccounts.create_api_key(user, %{name: "automation", scopes: ["public_repo"]})
  end

  test "authenticates a classic key without a username and authorizes its scopes", %{user: user} do
    assert {:ok, key, "fc_pat_" <> _ = secret} =
             ForgeAccounts.create_api_key(user, %{
               name: "automation",
               scopes: ["repo", "write:org"]
             })

    assert {:ok, authenticated_user, authenticated_key} =
             ForgeAccounts.authenticate_api_key(secret)

    assert authenticated_user.id == user.id
    assert authenticated_key.id == key.id
    assert authenticated_key.last_used_at
    assert :ok = APIScope.authorize(key, :identity_read, nil)
    assert :ok = APIScope.authorize(key, :repository_read, :private)
    assert :ok = APIScope.authorize(key, :repository_mutation, :public)
    assert :ok = APIScope.authorize(key, :organization_read, nil)
    assert :ok = APIScope.authorize(key, :organization_mutation, nil)
  end

  test "uses the complete classic and legacy scope decision table", %{user: user} do
    assert {:ok, public_key, _secret} =
             ForgeAccounts.create_api_key(user, %{
               name: "public repositories",
               scopes: ["public_repo"]
             })

    legacy_read_key = insert_api_key!(user, "fc_pat_legacy_read", %{"repo:read" => true})
    legacy_write_key = insert_api_key!(user, "fc_pat_legacy_write", %{"repo:write" => true})

    assert APIScope.accepted_scopes(:identity_read, nil) == [
             "repo",
             "public_repo",
             "read:org",
             "write:org",
             "repo:read",
             "repo:write"
           ]

    assert APIScope.accepted_scopes(:organization_read, nil) == ["read:org", "write:org"]
    assert APIScope.accepted_scopes(:organization_mutation, nil) == ["write:org"]

    assert APIScope.accepted_scopes(:repository_read, :public) == [
             "public_repo",
             "repo",
             "repo:read",
             "repo:write"
           ]

    assert APIScope.accepted_scopes(:repository_read, :private) == [
             "repo",
             "repo:read",
             "repo:write"
           ]

    assert APIScope.accepted_scopes(:repository_mutation, :public) == ["public_repo", "repo"]
    assert APIScope.accepted_scopes(:repository_mutation, :private) == ["repo"]

    assert APIScope.accepted_scopes(:git_read, :public) == [
             "public_repo",
             "repo",
             "repo:read",
             "repo:write"
           ]

    assert APIScope.accepted_scopes(:git_read, :private) == ["repo", "repo:read", "repo:write"]
    assert APIScope.accepted_scopes(:git_write, :public) == ["public_repo", "repo", "repo:write"]
    assert APIScope.accepted_scopes(:git_write, :private) == ["repo", "repo:write"]

    assert :ok = APIScope.authorize(public_key, :repository_read, :public)
    assert :ok = APIScope.authorize(public_key, :repository_mutation, :public)
    assert :ok = APIScope.authorize(public_key, :git_read, :public)
    assert :ok = APIScope.authorize(public_key, :git_write, :public)

    assert {:error, :insufficient_scope} =
             APIScope.authorize(public_key, :repository_read, :private)

    assert :ok = APIScope.authorize(legacy_read_key, :repository_read, :private)
    assert :ok = APIScope.authorize(legacy_read_key, :git_read, :private)

    assert {:error, :insufficient_scope} =
             APIScope.authorize(legacy_read_key, :git_write, :private)

    assert :ok = APIScope.authorize(legacy_write_key, :repository_read, :private)
    assert :ok = APIScope.authorize(legacy_write_key, :git_write, :private)

    assert {:error, :insufficient_scope} =
             APIScope.authorize(legacy_write_key, :repository_mutation, :private)
  end

  test "rejects legacy scopes for new keys while stored migration keys authenticate", %{
    user: user
  } do
    for scope <- APIKey.legacy_scopes() do
      assert {:error, changeset} =
               ForgeAccounts.create_api_key(user, %{name: "new legacy key", scopes: [scope]})

      assert %{scopes: [_ | _]} = errors_on(changeset)
    end

    secret = "fc_pat_stored_legacy"
    key = insert_api_key!(user, secret, %{"repo:write" => true})

    assert {:ok, authenticated_user, authenticated_key} =
             ForgeAccounts.authenticate_api_key(secret)

    assert authenticated_user.id == user.id
    assert authenticated_key.id == key.id
  end

  test "checks every duplicate-prefix candidate across users", %{user: user} do
    {:ok, bob} =
      ForgeAccounts.create_user(%{
        username: "bob",
        email: "bob@example.com",
        password: "correct horse battery staple"
      })

    alice_secret = "fc_pat_shared_prefix_alice"
    bob_secret = "fc_pat_shared_prefix_bob"
    malformed_secret = "fc_pat_shared_prefix_malformed"

    assert String.slice(alice_secret, 0, 15) == String.slice(bob_secret, 0, 15)
    assert String.slice(alice_secret, 0, 15) == String.slice(malformed_secret, 0, 15)

    _alice_key = insert_api_key!(user, alice_secret, %{"repo" => true})

    _malformed_key =
      insert_api_key!(user, malformed_secret, %{"repo" => true}, %{token_hash: "short"})

    bob_key = insert_api_key!(bob, bob_secret, %{"repo" => true})

    assert {:ok, authenticated_user, authenticated_key} =
             ForgeAccounts.authenticate_api_key(bob_secret)

    assert authenticated_user.id == bob.id
    assert authenticated_key.id == bob_key.id
    assert authenticated_key.last_used_at
  end

  test "username authentication normalizes identity before recording use", %{user: user} do
    assert {:ok, key, secret} =
             ForgeAccounts.create_api_key(user, %{name: "git", scopes: ["repo"]})

    assert {:error, :invalid_credentials} = ForgeAccounts.authenticate_api_key("bob", secret)
    assert is_nil(Repo.reload!(key).last_used_at)

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key("fc_pat_invalid")

    assert {:error, :invalid_credentials} = ForgeAccounts.authenticate_api_key("wrong_prefix")

    assert {:ok, authenticated_user, authenticated_key} =
             ForgeAccounts.authenticate_api_key(" ALICE ", secret)

    assert authenticated_user.id == user.id
    assert authenticated_key.id == key.id
    assert authenticated_key.last_used_at

    assert {:ok, ^authenticated_user, _authenticated_key} =
             ForgeAccounts.authenticate_api_key("alice", secret, "repo:read")
  end

  test "rejects expired and revoked keys and protects ownership", %{user: user} do
    assert {:ok, expired_key, expired_secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "expired",
               "scopes" => ["repo"],
               "expires_at" => DateTime.add(DateTime.utc_now(), -60, :second)
             })

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key(expired_secret)

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
               "scopes" => ["repo"]
             })

    assert {:ok, revoked_key} = ForgeAccounts.revoke_api_key(user, api_key.id)
    assert is_nil(revoked_key.last_used_at)

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key(secret)

    assert is_nil(Repo.reload!(api_key).last_used_at)
  end

  test "accepts future expiry and rejects the expiry boundary", %{user: user} do
    future = DateTime.add(DateTime.utc_now(:second), 60, :second)

    assert {:ok, _future_key, future_secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "future",
               "scopes" => ["repo"],
               "expires_at" => future
             })

    assert {:ok, _user, _key} =
             ForgeAccounts.authenticate_api_key(future_secret)

    boundary = DateTime.utc_now(:second)

    assert {:ok, boundary_key, boundary_secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "boundary",
               "scopes" => ["repo"],
               "expires_at" => boundary
             })

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key(boundary_secret)

    assert is_nil(Repo.reload!(boundary_key).last_used_at)
  end

  test "keys stop authenticating when their user is disabled", %{user: user} do
    assert {:ok, api_key, secret} =
             ForgeAccounts.create_api_key(user, %{
               "name" => "disabled owner",
               "scopes" => ["repo"]
             })

    assert {:ok, _disabled_user} =
             user
             |> User.state_changeset(%{state: :disabled})
             |> Repo.update()

    assert {:error, :invalid_credentials} =
             ForgeAccounts.authenticate_api_key(secret)

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
               "scopes" => ["repo"]
             })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp insert_api_key!(user, secret, scopes, overrides \\ %{}) do
    %APIKey{
      user_id: user.id,
      name: "stored migration key",
      token_prefix: String.slice(secret, 0, 15),
      token_hash: APIKey.hash(secret),
      scopes: scopes
    }
    |> struct(overrides)
    |> Repo.insert!()
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
