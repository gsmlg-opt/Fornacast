defmodule ForgeReleasesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ForgeReleases.Release
  alias ForgeRepos.Collaborator
  alias Fornacast.{AuditEvent, Page, Repo}

  import ForgeReleases.Fixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    reset_database!()
    previous_root = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)
    on_exit(fn -> Application.put_env(:fornacast, :repo_storage_root, previous_root) end)

    owner = user_fixture("release-owner-#{System.unique_integer([:positive])}")
    repository = repository_fixture(owner)
    put_tag(repository, "v1.0.0")

    %{owner: owner, repository: repository}
  end

  test "CRUD remains repository-scoped, audited, and soft deleted", context do
    %{owner: owner, repository: repository} = context

    assert {:ok, %Release{} = release} =
             ForgeReleases.create(
               owner,
               owner.username,
               repository.slug,
               %{
                 "tag_name" => "v1.0.0",
                 "name" => "Version 1",
                 "body" => "Initial notes",
                 "draft" => false,
                 "prerelease" => false
               },
               request_metadata("create")
             )

    assert release.repository_id == repository.id
    assert release.author == owner
    assert release.author_user_id == owner.id
    assert release.target_commitish == "main"
    assert %DateTime{} = release.published_at

    assert {:ok, %Page{entries: [%Release{id: release_id}], total: 1}} =
             ForgeReleases.list(owner, owner.username, repository.slug, %{page: 1, per_page: 30})

    assert release_id == release.id

    assert {:ok, %Release{id: ^release_id}} =
             ForgeReleases.get(owner, owner.username, repository.slug, release.id)

    assert {:ok, %Release{id: ^release_id}} =
             ForgeReleases.get_by_tag(owner, owner.username, repository.slug, "v1.0.0")

    assert {:ok, %Release{id: ^release_id}} =
             ForgeReleases.latest(owner, owner.username, repository.slug)

    assert {:ok, %Release{} = updated} =
             ForgeReleases.update(
               owner,
               owner.username,
               repository.slug,
               release.id,
               %{"name" => "Version One", "body" => "Revised", "prerelease" => true},
               request_metadata("update")
             )

    assert updated.name == "Version One"
    assert updated.body == "Revised"
    assert updated.prerelease
    assert {:error, :not_found} = ForgeReleases.latest(owner, owner.username, repository.slug)

    assert :ok =
             ForgeReleases.delete(
               owner,
               owner.username,
               repository.slug,
               release.id,
               request_metadata("delete")
             )

    assert {:error, :not_found} =
             ForgeReleases.get(owner, owner.username, repository.slug, release.id)

    assert %Release{deleted_at: %DateTime{}} = Repo.get!(Release, release.id)

    assert ["release.created", "release.updated", "release.deleted"] ==
             AuditEvent
             |> where(
               [audit],
               audit.target_type == "release" and audit.target_id == ^"#{release.id}"
             )
             |> order_by([audit], asc: audit.id)
             |> select([audit], audit.action)
             |> Repo.all()
  end

  test "active tags are unique and a tag may be released again after soft deletion", context do
    %{owner: owner, repository: repository} = context
    attrs = %{"tag_name" => "v1.0.0", "name" => "Version 1", "draft" => true}

    assert {:ok, first} =
             ForgeReleases.create(
               owner,
               owner.username,
               repository.slug,
               attrs,
               request_metadata("first")
             )

    assert {:error, {:validation, errors}} =
             ForgeReleases.create(
               owner,
               owner.username,
               repository.slug,
               attrs,
               request_metadata("duplicate")
             )

    assert Enum.any?(errors, &(&1.field == "tag_name" and &1.code == :unprocessable))

    assert :ok =
             ForgeReleases.delete(
               owner,
               owner.username,
               repository.slug,
               first.id,
               request_metadata("delete")
             )

    assert {:ok, second} =
             ForgeReleases.create(
               owner,
               owner.username,
               repository.slug,
               attrs,
               request_metadata("second")
             )

    assert second.id != first.id
  end

  test "tag existence is required and rechecked before metadata changes", context do
    %{owner: owner, repository: repository} = context

    assert {:error, {:validation, [%{resource: "Release", field: "tag_name", code: :missing}]}} =
             ForgeReleases.create(
               owner,
               owner.username,
               repository.slug,
               %{"tag_name" => "missing", "name" => "Missing"},
               request_metadata("missing")
             )

    assert Repo.aggregate(Release, :count, :id) == 0

    assert {:ok, release} =
             ForgeReleases.create(
               owner,
               owner.username,
               repository.slug,
               %{"tag_name" => "v1.0.0", "name" => "Version 1"},
               request_metadata("create")
             )

    delete_tag(repository, "v1.0.0")

    assert {:error, {:validation, [%{resource: "Release", field: "tag_name", code: :missing}]}} =
             ForgeReleases.update(
               owner,
               owner.username,
               repository.slug,
               release.id,
               %{"name" => "Must not update"},
               request_metadata("stale-tag")
             )

    assert Repo.get!(Release, release.id).name == "Version 1"
  end

  test "draft visibility follows repository write authorization", context do
    %{owner: owner, repository: repository} = context
    reader = user_fixture("release-reader-#{System.unique_integer([:positive])}")
    writer = user_fixture("release-writer-#{System.unique_integer([:positive])}")
    outsider = user_fixture("release-outsider-#{System.unique_integer([:positive])}")
    grant(repository, reader, :read)
    grant(repository, writer, :write)

    assert {:ok, draft} =
             ForgeReleases.create(
               owner,
               owner.username,
               repository.slug,
               %{"tag_name" => "v1.0.0", "name" => "Draft", "draft" => true},
               request_metadata("draft")
             )

    assert {:ok, %Page{entries: []}} =
             ForgeReleases.list(reader, owner.username, repository.slug, %{
               page: 1,
               per_page: 30
             })

    assert {:error, :not_found} =
             ForgeReleases.get(reader, owner.username, repository.slug, draft.id)

    assert {:ok, %Page{entries: [%Release{id: draft_id}]}} =
             ForgeReleases.list(writer, owner.username, repository.slug, %{
               page: 1,
               per_page: 30
             })

    assert draft_id == draft.id

    assert {:error, :forbidden} =
             ForgeReleases.update(
               reader,
               owner.username,
               repository.slug,
               draft.id,
               %{"name" => "Denied"},
               request_metadata("denied")
             )

    assert {:error, :not_found} =
             ForgeReleases.list(outsider, owner.username, repository.slug, %{
               page: 1,
               per_page: 30
             })
  end

  test "mutation authorization is revalidated inside the transaction", context do
    %{repository: repository} = context
    writer = user_fixture("release-stale-writer-#{System.unique_integer([:positive])}")
    collaborator = grant(repository, writer, :write)

    multi =
      ForgeReleases.create_multi(
        writer,
        repository,
        %{"tag_name" => "v1.0.0", "name" => "Stale writer"},
        request_metadata("stale")
      )

    Repo.delete!(collaborator)

    assert {:error, :authorization, :forbidden, %{}} = ForgeReleases.transaction(multi)
    assert Repo.aggregate(Release, :count, :id) == 0
    assert Repo.aggregate(AuditEvent, :count, :id) == 0
  end

  test "delete requires repository write authorization", context do
    %{owner: owner, repository: repository} = context
    reader = user_fixture("release-delete-reader-#{System.unique_integer([:positive])}")
    grant(repository, reader, :read)

    assert {:ok, release} =
             ForgeReleases.create(
               owner,
               owner.username,
               repository.slug,
               %{"tag_name" => "v1.0.0", "name" => "Version 1"},
               request_metadata("create")
             )

    assert {:error, :forbidden} =
             ForgeReleases.delete(
               reader,
               owner.username,
               repository.slug,
               release.id,
               request_metadata("denied-delete")
             )

    assert %Release{deleted_at: nil} = Repo.get!(Release, release.id)
  end

  test "tag removal before the fenced mutation prevents release creation", context do
    %{owner: owner, repository: repository} = context

    result =
      ForgeReleases.with_test_fence_hook(
        fn -> delete_tag(repository, "v1.0.0") end,
        fn ->
          ForgeReleases.create(
            owner,
            owner.username,
            repository.slug,
            %{"tag_name" => "v1.0.0", "name" => "Version 1"},
            request_metadata("tag-race")
          )
        end
      )

    assert {:error, {:validation, [%{resource: "Release", field: "tag_name", code: :missing}]}} =
             result

    assert Repo.aggregate(Release, :count, :id) == 0
  end

  test "database rejects releases without exactly one author", context do
    %{repository: repository} = context

    changeset =
      %Release{}
      |> Ecto.Changeset.change(persisted_attrs(repository, author_user_id: nil))
      |> Ecto.Changeset.check_constraint(:author_user_id,
        name: :releases_author_identity_check
      )

    assert {:error, changeset} = Repo.insert(changeset)
    assert {"is invalid", _opts} = changeset.errors[:author_user_id]
  end

  test "database rejects incoherent draft publication state", context do
    %{owner: owner, repository: repository} = context

    changeset =
      %Release{}
      |> Ecto.Changeset.change(
        persisted_attrs(repository,
          author_user_id: owner.id,
          draft: true,
          published_at: ~U[2026-09-05 08:00:00Z]
        )
      )
      |> Ecto.Changeset.check_constraint(:published_at,
        name: :releases_publication_state_check
      )

    assert {:error, changeset} = Repo.insert(changeset)
    assert {"is invalid", _opts} = changeset.errors[:published_at]
  end

  defp grant(repository, user, role) do
    %Collaborator{}
    |> Collaborator.changeset(%{repository_id: repository.id, user_id: user.id, role: role})
    |> Repo.insert!()
  end

  defp request_metadata(suffix) do
    %{
      request_id: "release-request-#{suffix}",
      ip_address: "127.0.0.1",
      user_agent: "forge-releases-test/1.0"
    }
  end

  defp persisted_attrs(repository, overrides) do
    Keyword.merge(
      [
        repository_id: repository.id,
        tag_name: "v1.0.0",
        name: "Version 1",
        body: "Release notes",
        draft: false,
        prerelease: false,
        target_commitish: "main",
        published_at: ~U[2026-09-05 08:00:00Z],
        author_user_id: nil,
        author_github_identity_id: nil
      ],
      overrides
    )
  end
end
