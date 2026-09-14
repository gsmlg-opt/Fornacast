defmodule ForgeReleases.ImportTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ForgeReleases.Fixtures

  alias Ecto.Multi
  alias ForgeAccounts.GitHubIdentity
  alias ForgeReleases.Release
  alias Fornacast.{DomainOutboxEvent, Repo}

  setup do
    reset_database!()
    owner = user_fixture("release-import-#{System.unique_integer([:positive])}")

    repository =
      owner
      |> repository_fixture()
      |> Ecto.Changeset.change(lifecycle: :importing)
      |> Repo.update!()

    identity =
      %GitHubIdentity{}
      |> GitHubIdentity.observed_changeset(%{
        github_user_id: System.unique_integer([:positive]),
        github_node_id: "U_import_#{System.unique_integer([:positive])}",
        login: "release-importer",
        last_observed_at: ~U[2026-09-14 02:00:00Z]
      })
      |> Repo.insert!()

    %{repository: repository, identity: identity}
  end

  test "appends a validated historical release without a synchronization event", ctx do
    assert {:ok, %{release: release}} =
             Multi.new()
             |> ForgeReleases.append_import_release(
               :release,
               ctx.repository,
               import_attrs(ctx.identity.id)
             )
             |> Repo.transaction()

    assert %Release{
             repository_id: repository_id,
             tag_name: "v1.0.0",
             author_user_id: nil,
             author_github_identity_id: identity_id,
             inserted_at: ~U[2026-09-12 10:11:12Z],
             updated_at: ~U[2026-09-13 10:11:12Z]
           } = release

    assert repository_id == ctx.repository.id
    assert identity_id == ctx.identity.id
    refute Repo.exists?(from event in DomainOutboxEvent, where: event.aggregate_type == "release")
  end

  test "requires an importing repository and composes atomically", ctx do
    rollback =
      Multi.new()
      |> ForgeReleases.append_import_release(
        :release,
        ctx.repository,
        import_attrs(ctx.identity.id)
      )
      |> Multi.run(:checkpoint, fn _repo, _changes -> {:error, :injected_checkpoint_failure} end)

    assert {:error, :checkpoint, :injected_checkpoint_failure, _changes} =
             Repo.transaction(rollback)

    refute Repo.exists?(
             from release in Release, where: release.repository_id == ^ctx.repository.id
           )

    ready =
      ctx.repository
      |> Ecto.Changeset.change(lifecycle: :ready)
      |> Repo.update!()

    assert {:error, _, :invalid_import_repository, _changes} =
             Multi.new()
             |> ForgeReleases.append_import_release(
               :release,
               ready,
               import_attrs(ctx.identity.id)
             )
             |> Repo.transaction()
  end

  test "rejects a missing or non-user provider author as a composable error", ctx do
    assert {:error, {ForgeReleases, :import_author, :release}, :invalid_import_author, _changes} =
             Multi.new()
             |> ForgeReleases.append_import_release(
               :release,
               ctx.repository,
               import_attrs(ctx.identity.id + 1_000_000)
             )
             |> Repo.transaction()

    refute Repo.exists?(
             from release in Release, where: release.repository_id == ^ctx.repository.id
           )
  end

  defp import_attrs(identity_id) do
    %{
      author_github_identity_id: identity_id,
      tag_name: "v1.0.0",
      name: "Version 1",
      body: "Release notes",
      draft: false,
      prerelease: false,
      target_commitish: "main",
      published_at: ~U[2026-09-12 10:11:12Z],
      inserted_at: ~U[2026-09-12 10:11:12Z],
      updated_at: ~U[2026-09-13 10:11:12Z]
    }
  end
end
