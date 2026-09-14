defmodule ForgeGitHub.ReleaseSyncProjectionTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.ReleaseSyncProjection

  test "canonicalizes a local release projection without provider-only data" do
    assert {:ok, projection} = ReleaseSyncProjection.from_local(local_projection())

    assert projection == %{
             presence: :present,
             resource_kind: :release,
             local_resource_id: 7,
             local_resource_type: "ForgeReleases.Release",
             local_version: 3,
             snapshot: fields()
           }
  end

  test "canonicalizes remote metadata and carries only bounded asset reporting" do
    assert {:ok, projection} = ReleaseSyncProjection.from_remote(remote_release())

    assert projection.github_object_id == 41
    assert projection.github_node_id == "RE_41"
    assert projection.remote_created_at == ~U[2030-01-01 00:00:00Z]
    assert projection.remote_updated_at == ~U[2030-01-03 00:00:00Z]
    assert projection.snapshot == fields()
    assert projection.asset_count == 2
    assert projection.unsupported_fields == ["discussion_url", "html_url"]
    assert projection.raw_author == %{"id" => 99, "node_id" => "U_99", "login" => "octocat"}
    refute Map.has_key?(projection, :assets)
    refute inspect(projection) =~ "browser_download_url"
  end

  test "builds the exact supported outbound provider attributes" do
    assert {:ok, attrs} = ReleaseSyncProjection.remote_attrs(fields())

    assert attrs == %{
             "tag_name" => "release/v1.0",
             "name" => "Version 1.0",
             "body" => "Release notes",
             "draft" => false,
             "prerelease" => false,
             "target_commitish" => "main"
           }

    refute Map.has_key?(attrs, "published_at")
  end

  test "rejects malformed local, remote, and outbound projections" do
    assert {:error, :invalid_projection} =
             ReleaseSyncProjection.from_local(put_in(local_projection(), [:fields, "draft"], nil))

    assert {:error, :invalid_projection} =
             ReleaseSyncProjection.from_local(%{local_projection() | deleted: true})

    assert {:error, :invalid_projection} =
             ReleaseSyncProjection.from_remote(%{remote_release() | "asset_count" => 513})

    assert {:error, :invalid_projection} =
             ReleaseSyncProjection.from_remote(%{
               remote_release()
               | "unsupported_fields" => ["html_url", "credential-leak"]
             })

    assert {:error, :invalid_projection} =
             ReleaseSyncProjection.from_remote(
               put_in(remote_release(), ["author", "login"], "bad login")
             )

    assert {:error, :invalid_projection} =
             ReleaseSyncProjection.remote_attrs(%{fields() | "published_at" => nil})

    assert {:error, :invalid_projection} =
             ReleaseSyncProjection.from_remote(%{
               remote_release()
               | "tag_name" => "refs/tags/release/v1.0"
             })

    assert {:error, :invalid_projection} =
             ReleaseSyncProjection.from_local(
               put_in(local_projection(), [:fields, "tag_name"], "refs/tags/release/v1.0")
             )
  end

  defp local_projection do
    %{
      repository_id: 5,
      resource_kind: :release,
      local_resource_id: 7,
      local_resource_type: "ForgeReleases.Release",
      local_version: 3,
      deleted: false,
      fields: fields()
    }
  end

  defp fields do
    %{
      "tag_name" => "release/v1.0",
      "name" => "Version 1.0",
      "body" => "Release notes",
      "draft" => false,
      "prerelease" => false,
      "target_commitish" => "main",
      "published_at" => ~U[2030-01-02 00:00:00Z]
    }
  end

  defp remote_release do
    %{
      "id" => 41,
      "node_id" => "RE_41",
      "tag_name" => "release/v1.0",
      "name" => "Version 1.0",
      "body" => "Release notes",
      "draft" => false,
      "prerelease" => false,
      "target_commitish" => "main",
      "published_at" => "2030-01-02T00:00:00Z",
      "created_at" => "2030-01-01T00:00:00Z",
      "updated_at" => "2030-01-03T00:00:00Z",
      "author" => %{"id" => 99, "node_id" => "U_99", "login" => "octocat"},
      "asset_count" => 2,
      "unsupported_fields" => ["discussion_url", "html_url"]
    }
  end
end
