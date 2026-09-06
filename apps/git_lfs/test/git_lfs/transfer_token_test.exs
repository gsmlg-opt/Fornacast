defmodule GitLFS.TransferTokenTest do
  use ExUnit.Case, async: false

  alias ForgeAccounts.User
  alias ForgeRepos.{Collaborator, Repository}
  alias GitLFS.{Principal, TransferToken}
  alias Fornacast.Repo

  @oid "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393"
  @ed25519_public_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINUKfpNn72l8H0YnXfbkh6s4aAcrMmVsBWPfyPppa1i8 lfs@example.test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    username = "lfs-token-#{System.unique_integer([:positive])}"

    assert {:ok, actor} =
             ForgeAccounts.create_user(%{
               username: username,
               email: "#{username}@example.test",
               password: "correct horse battery staple"
             })

    assert {:ok, repository} =
             ForgeRepos.create_repository(actor, %{name: "Token repository", slug: "tokens"})

    %{actor: actor, repository: repository}
  end

  test "an object token is exact to actor, repository generation, OID, action, and expiry", %{
    actor: actor,
    repository: repository
  } do
    now = ~U[2026-09-05 00:00:00Z]
    principal = Principal.password(actor)

    assert {:ok, token, 60} =
             TransferToken.issue(principal, repository, :object, :download, @oid,
               now: now,
               ttl_seconds: 60,
               object_size: 42
             )

    assert {:ok, verified, %Repository{id: repository_id}} =
             TransferToken.verify(token, :object, :download, @oid,
               now: DateTime.add(now, 59, :second)
             )

    assert verified.actor.id == actor.id
    assert repository_id == repository.id

    assert {:ok, _verified, _repository} =
             TransferToken.verify(token, :object, :download, @oid,
               now: DateTime.add(now, 59, :second),
               object_size: 42
             )

    assert {:error, :size_mismatch} =
             TransferToken.verify(token, :object, :download, @oid,
               now: now,
               object_size: 41
             )

    for {scope, action, oid} <- [
          {:batch, :download, nil},
          {:object, :upload, @oid},
          {:object, :verify, @oid},
          {:object, :download, String.duplicate("a", 64)}
        ] do
      expected_error =
        if scope == :object and action == :download, do: :not_found, else: :invalid_credentials

      assert {:error, ^expected_error} = TransferToken.verify(token, scope, action, oid, now: now)
    end

    assert {:error, :invalid_credentials} =
             TransferToken.verify(token, :object, :download, @oid,
               now: DateTime.add(now, 60, :second)
             )

    changed_repository =
      repository
      |> Ecto.Changeset.change(generation: repository.generation + 1)
      |> Repo.update!()

    assert changed_repository.generation == repository.generation + 1

    assert {:error, :not_found} =
             TransferToken.verify(token, :object, :download, @oid, now: now)
  end

  test "synchronizing repositories reject new and previously issued transfer tokens", %{
    actor: actor,
    repository: repository
  } do
    principal = Principal.password(actor)

    assert {:ok, token, _ttl} =
             TransferToken.issue(principal, repository, :object, :download, @oid, object_size: 42)

    repository
    |> Ecto.Changeset.change(lifecycle: :synchronizing)
    |> Repo.update!()

    assert {:error, :not_found} =
             TransferToken.issue(principal, repository, :object, :download, @oid, object_size: 42)

    assert {:error, :not_found} = TransferToken.verify(token, :object, :download, @oid)
  end

  test "upload and verify tokens require their signed object size", %{
    actor: actor,
    repository: repository
  } do
    now = DateTime.utc_now(:second)

    for action <- [:upload, :verify] do
      assert {:ok, token, _ttl} =
               TransferToken.issue(
                 Principal.password(actor),
                 repository,
                 :object,
                 action,
                 @oid,
                 now: now,
                 object_size: 42
               )

      assert {:error, :invalid_credentials} =
               TransferToken.verify(token, :object, action, @oid, now: now)

      assert {:error, :size_mismatch} =
               TransferToken.verify(token, :object, action, @oid,
                 now: now,
                 object_size: 41
               )

      assert {:ok, _principal, _repository} =
               TransferToken.verify(token, :object, action, @oid,
                 now: now,
                 object_size: 42
               )
    end
  end

  test "object tokens stop working when repository access is removed", %{
    repository: repository
  } do
    username = "lfs-collaborator-#{System.unique_integer([:positive])}"

    assert {:ok, collaborator} =
             ForgeAccounts.create_user(%{
               username: username,
               email: "#{username}@example.test",
               password: "correct horse battery staple"
             })

    mapping =
      %Collaborator{}
      |> Collaborator.changeset(%{
        repository_id: repository.id,
        user_id: collaborator.id,
        role: :read
      })
      |> Repo.insert!()

    now = DateTime.utc_now(:second)

    assert {:ok, token, _ttl} =
             TransferToken.issue(
               Principal.password(collaborator),
               repository,
               :object,
               :download,
               @oid,
               now: now,
               object_size: 42
             )

    assert {:ok, _principal, _repository} =
             TransferToken.verify(token, :object, :download, @oid,
               now: now,
               object_size: 42
             )

    Repo.delete!(mapping)

    assert {:error, :not_found} =
             TransferToken.verify(token, :object, :download, @oid,
               now: now,
               object_size: 42
             )
  end

  test "SSH-derived tokens stop working when the actor's key set changes", %{
    actor: actor,
    repository: repository
  } do
    assert {:ok, ssh_key} =
             ForgeAccounts.create_ssh_key(actor, %{
               title: "LFS transfer",
               public_key: @ed25519_public_key
             })

    now = DateTime.utc_now(:second)

    assert {:ok, token, _ttl} =
             TransferToken.issue(
               Principal.ssh(actor),
               repository,
               :object,
               :download,
               @oid,
               now: now,
               object_size: 42
             )

    assert {:ok, _principal, _repository} =
             TransferToken.verify(token, :object, :download, @oid,
               now: now,
               object_size: 42
             )

    assert {:ok, _deleted} = ForgeAccounts.delete_ssh_key(actor, ssh_key.id)

    assert {:error, :invalid_credentials} =
             TransferToken.verify(token, :object, :download, @oid,
               now: now,
               object_size: 42
             )
  end

  test "API-key tokens stop working when their source credential is revoked", %{
    actor: actor,
    repository: repository
  } do
    assert {:ok, api_key, _secret} =
             ForgeAccounts.create_api_key(actor, %{name: "LFS", scopes: ["repo"]})

    now = DateTime.utc_now(:second)

    assert {:ok, token, _ttl} =
             TransferToken.issue(
               Principal.api_key(actor, api_key),
               repository,
               :object,
               :upload,
               @oid,
               now: now,
               object_size: 42
             )

    assert {:ok, _principal, _repository} =
             TransferToken.verify(token, :object, :upload, @oid, now: now, object_size: 42)

    assert {:ok, _revoked} = ForgeAccounts.revoke_api_key(actor, api_key.id)

    assert {:error, :invalid_credentials} =
             TransferToken.verify(token, :object, :upload, @oid, now: now, object_size: 42)
  end

  test "password generation, disabled actors, tampering, and malformed tokens fail closed", %{
    actor: actor,
    repository: repository
  } do
    now = DateTime.utc_now(:second)

    assert {:ok, token, _ttl} =
             TransferToken.issue(
               Principal.password(actor),
               repository,
               :batch,
               :download,
               nil,
               now: now
             )

    assert {:error, :invalid_credentials} =
             token
             |> tamper()
             |> TransferToken.verify(:batch, :download, nil, now: now)

    assert {:error, :invalid_credentials} =
             TransferToken.verify("not-a-token", :batch, :download, nil, now: now)

    actor
    |> User.state_changeset(%{state: :disabled})
    |> Repo.update!()

    assert {:error, :invalid_credentials} =
             TransferToken.verify(token, :batch, :download, nil, now: now)
  end

  test "anonymous transfer tokens can only read public repositories", %{
    repository: private_repository
  } do
    now = DateTime.utc_now(:second)

    public_repository =
      private_repository
      |> Ecto.Changeset.change(visibility: :public)
      |> Repo.update!()

    assert {:ok, token, _ttl} =
             TransferToken.issue(
               Principal.anonymous(),
               public_repository,
               :object,
               :download,
               @oid,
               now: now,
               object_size: 42
             )

    assert {:ok, %Principal{actor: nil}, _repository} =
             TransferToken.verify(token, :object, :download, @oid, now: now)

    public_repository
    |> Ecto.Changeset.change(visibility: :private)
    |> Repo.update!()

    assert {:error, :not_found} =
             TransferToken.verify(token, :object, :download, @oid, now: now)
  end

  defp tamper(token) do
    last = binary_part(token, byte_size(token) - 1, 1)
    replacement = if last == "A", do: "B", else: "A"
    binary_part(token, 0, byte_size(token) - 1) <> replacement
  end
end
