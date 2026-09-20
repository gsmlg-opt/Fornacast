defmodule ForgeRepos.RepositoryMetadataSyncTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias Fornacast.{DomainOutboxEvent, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    owner =
      Repo.insert!(%User{
        username: "metadata-sync-#{System.unique_integer([:positive])}",
        email: "metadata-sync-#{System.unique_integer([:positive])}@example.com",
        password_hash: "unused",
        kind: :user,
        state: :active
      })

    repository =
      Repo.insert!(%Repository{
        owner_user_id: owner.id,
        slug: "before",
        name: "Before",
        visibility: :private,
        storage_path: "@hashed/metadata-#{System.unique_integer([:positive])}.git",
        default_branch: "main"
      })

    %{owner: owner, repository: repository}
  end

  test "atomically applies GitHub metadata using its exact local preimage and emits no echo", c do
    assert {:ok, updated} = ForgeRepos.sync_github_repository_metadata(sync_input(c.repository))

    assert %{
             name: "Remote Name",
             slug: "remote-name",
             description: "remote description",
             visibility: :public,
             write_version: 1
           } = updated

    assert %DomainOutboxEvent{
             event_type: "repository.updated",
             origin: :github,
             causation_id: "github:repository:9",
             correlation_id: "mirror:repository:1"
           } =
             Repo.one(
               from event in DomainOutboxEvent,
                 where: event.aggregate_id == ^Integer.to_string(updated.id)
             )
  end

  test "accepts a GitHub-compatible leading-dot remote repository name", c do
    input = put_in(sync_input(c.repository), [:remote, :name], ".github")

    assert {:ok, %{name: ".github", slug: ".github"}} =
             ForgeRepos.sync_github_repository_metadata(input)
  end

  test "rejects a changed expected preimage without mutation or outbox event", c do
    input = put_in(sync_input(c.repository), [:expected, :name], "Changed locally")

    assert {:error, :stale} = ForgeRepos.sync_github_repository_metadata(input)
    assert Repo.get!(Repository, c.repository.id).name == "Before"

    assert 0 ==
             Repo.aggregate(
               from(event in DomainOutboxEvent,
                 where: event.aggregate_id == ^Integer.to_string(c.repository.id)
               ),
               :count,
               :id
             )
  end

  test "rejects non-representable provider visibility and archive state", c do
    for remote <- [
          %{remote(c.repository) | visibility: :internal},
          Map.put(remote(c.repository), :archived, true)
        ] do
      assert {:error, :unsupported_remote_metadata} =
               ForgeRepos.sync_github_repository_metadata(%{
                 sync_input(c.repository)
                 | remote: remote
               })
    end
  end

  test "applies metadata while a published repository is still synchronizing", c do
    repository =
      c.repository
      |> Ecto.Changeset.change(lifecycle: :synchronizing)
      |> Repo.update!()

    assert {:ok, updated} =
             ForgeRepos.sync_github_repository_metadata(sync_input(repository))

    assert updated.lifecycle == :synchronizing
    assert updated.name == "Remote Name"
  end

  test "surfaces a provider name that collides with the owner's normalized namespace", c do
    Repo.insert!(%Repository{
      owner_user_id: c.owner.id,
      slug: "remote-name",
      name: "Existing",
      visibility: :private,
      storage_path: "@hashed/metadata-collision-#{System.unique_integer([:positive])}.git",
      default_branch: "main"
    })

    assert {:error, :namespace_collision} =
             ForgeRepos.sync_github_repository_metadata(sync_input(c.repository))
  end

  defp sync_input(repository) do
    %{
      repository_id: repository.id,
      owner_user_id: repository.owner_user_id,
      generation: repository.generation,
      write_version: repository.write_version,
      expected: expected(repository),
      remote: remote(repository),
      causation_id: "github:repository:9",
      correlation_id: "mirror:repository:1"
    }
  end

  defp expected(repository) do
    Map.take(repository, [:name, :slug, :description, :visibility, :default_branch])
  end

  defp remote(repository) do
    %{
      name: "Remote Name",
      description: "remote description",
      visibility: :public,
      default_branch: repository.default_branch
    }
  end
end
