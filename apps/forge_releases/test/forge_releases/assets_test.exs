defmodule ForgeReleases.AssetsTest do
  use ExUnit.Case, async: false
  import ForgeReleases.Fixtures
  import Ecto.Query
  alias ForgeReleases.{Asset, AssetBlob, AssetOperation}
  alias Fornacast.Repo

  setup do
    reset_database!()
    owner = user_fixture("asset#{System.unique_integer([:positive])}")
    repository = repository_fixture(owner, %{visibility: :public})
    put_tag(repository, "v1")

    {:ok, release} =
      ForgeReleases.create(owner, owner.username, repository.slug, %{"tag_name" => "v1"}, %{})

    %{owner: owner, repository: repository, release: release}
  end

  test "streamed uploads expose GitHub metadata, ranged bytes and completed counts", c do
    {:ok, asset, []} = upload(c, ["abc", "def"])
    assert asset.size == 6
    assert asset.sha256_digest == Base.encode16(:crypto.hash(:sha256, "abcdef"), case: :lower)
    assert asset.label == nil
    assert asset.uploader.id == c.owner.id
    {:ok, release} = ForgeReleases.get(nil, c.owner.username, c.repository.slug, c.release.id)
    assert Enum.map(release.assets, & &1.id) == [asset.id]

    {:ok, ^asset, source} =
      ForgeReleases.open_asset(c.owner, c.owner.username, c.repository.slug, asset.id, {1, 3})

    assert {:ok, "bcd", next} = ForgeReleases.read_asset_chunk(source, 100)
    assert :eof = ForgeReleases.read_asset_chunk(next, 100)
    ForgeReleases.close_asset(next)
    :ok = ForgeReleases.complete_asset_download(asset.id)
    assert Repo.get!(Asset, asset.id).download_count == 1
  end

  test "duplicate names fail before reading request bytes", c do
    assert {:ok, _asset, []} = upload(c, ["abc"])
    reader = fn _, _ -> flunk("duplicate upload consumed bytes") end

    assert {:error, {:validation, _}, :untouched} =
             ForgeReleases.upload_asset(
               c.owner,
               c.owner.username,
               c.repository.slug,
               c.release.id,
               attrs(),
               reader,
               :untouched
             )
  end

  test "logical deletion preserves shared bytes and GC reclaims only the last reference", c do
    {:ok, first, []} = upload(c, ["shared"], %{"name" => "first"})
    {:ok, second, []} = upload(c, ["shared"], %{"name" => "second"})
    :ok = ForgeReleases.delete_asset(c.owner, c.owner.username, c.repository.slug, first.id, %{})

    assert {:error, :not_found} =
             ForgeReleases.get_asset(nil, c.owner.username, c.repository.slug, first.id)

    :ok = ForgeReleases.Assets.collect_garbage()
    assert {:ok, %{size: 6}} = ForgeBlobs.stat(second.storage_key)
    :ok = ForgeReleases.delete_asset(c.owner, c.owner.username, c.repository.slug, second.id, %{})
    :ok = ForgeReleases.Assets.collect_garbage()
    assert Repo.get!(AssetBlob, second.storage_key).state == :candidate
    Repo.update_all(AssetBlob, set: [gc_after: DateTime.add(DateTime.utc_now(:second), -1)])
    :ok = ForgeReleases.Assets.collect_garbage()
    assert {:error, :not_found} = ForgeBlobs.stat(second.storage_key)
  end

  test "CAS success followed by SQL failure recovers twice without duplicate metadata", c do
    options = [test_after_commit: fn -> {:error, :injected_sql_failure} end]
    assert {:error, :injected_sql_failure, []} = upload(c, ["recover"], %{}, options)
    operation = Repo.one!(AssetOperation)
    assert operation.state == :staged
    assert Repo.get!(Asset, operation.asset_id).state == :pending

    Repo.update_all(AssetOperation,
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
    )

    :ok = ForgeReleases.Assets.recover()
    :ok = ForgeReleases.Assets.recover()
    assert Repo.get!(AssetOperation, operation.id).state == :completed
    assert Repo.get!(Asset, operation.asset_id).state == :uploaded
  end

  test "size mismatches never publish or leave a name reservation", c do
    assert {:error, :integrity_mismatch, []} = upload(c, ["abc"], %{"size" => 4})
    assert Repo.aggregate(from(a in Asset, where: a.state == :uploaded), :count) == 0
    assert {:ok, _asset, []} = upload(c, ["abc"])
  end

  test "recovery retires an interrupted upload after release deletion", c do
    assert {:error, :injected_sql_failure, []} =
             upload(c, ["retire"], %{},
               test_after_commit: fn -> {:error, :injected_sql_failure} end
             )

    operation = Repo.one!(AssetOperation)

    assert :ok =
             ForgeReleases.delete(c.owner, c.owner.username, c.repository.slug, c.release.id, %{})

    Repo.update_all(AssetOperation,
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
    )

    :ok = ForgeReleases.Assets.recover()
    assert Repo.get!(AssetOperation, operation.id).state == :failed
    :ok = ForgeReleases.Assets.collect_garbage()
    assert Repo.get!(AssetBlob, operation.storage_key).state == :candidate
  end

  test "a Git LFS inventory reference protects shared bytes from release GC", c do
    bytes = "lfs-protected-#{System.unique_integer([:positive])}"
    {:ok, asset, []} = upload(c, [bytes])
    {:ok, reservation} = GitLFS.reserve_upload(c.repository, asset.storage_key, byte_size(bytes))
    reader = fn _, _ -> {:ok, bytes, nil} end
    {:ok, staged, nil} = GitLFS.stage_upload(reservation, reader, nil)
    assert {:ok, _} = GitLFS.commit_upload(staged)

    assert :ok =
             ForgeReleases.delete_asset(
               c.owner,
               c.owner.username,
               c.repository.slug,
               asset.id,
               %{}
             )

    :ok = ForgeReleases.Assets.collect_garbage()
    assert {:ok, %{size: size}} = ForgeBlobs.stat(asset.storage_key)
    assert size == byte_size(bytes)
    refute Repo.get!(AssetBlob, asset.storage_key).state == :candidate
  end

  test "private and draft assets retain release authorization", c do
    {:ok, _} =
      ForgeRepos.update_api_repository(c.owner, c.repository, %{visibility: :private}, %{})

    {:ok, asset, []} = upload(c, ["secret"])

    assert {:error, :not_found} =
             ForgeReleases.get_asset(nil, c.owner.username, c.repository.slug, asset.id)

    assert {:error, :not_found} =
             ForgeReleases.open_asset(nil, c.owner.username, c.repository.slug, asset.id)
  end

  test "immutable published releases reject asset and metadata mutations", c do
    {:ok, asset, []} = upload(c, ["fixed"])

    Repo.update_all(from(r in ForgeReleases.Release, where: r.id == ^c.release.id),
      set: [immutable: true]
    )

    assert {:error, {:validation, _}} =
             ForgeReleases.update(
               c.owner,
               c.owner.username,
               c.repository.slug,
               c.release.id,
               %{"name" => "change"},
               %{}
             )

    assert {:error, {:validation, _}} =
             ForgeReleases.delete_asset(
               c.owner,
               c.owner.username,
               c.repository.slug,
               asset.id,
               %{}
             )

    assert {:error, {:validation, _}, _} = upload(c, ["new"], %{"name" => "other"})
  end

  defp attrs,
    do: %{"name" => "test.bin", "content_type" => "application/octet-stream", "label" => nil}

  defp upload(c, chunks, overrides \\ %{}, options \\ []) do
    reader = fn
      [chunk | rest], _opts -> {:more, chunk, rest}
      [], _opts -> {:ok, "", []}
    end

    ForgeReleases.upload_asset(
      c.owner,
      c.owner.username,
      c.repository.slug,
      c.release.id,
      Map.merge(attrs(), overrides),
      reader,
      chunks,
      options
    )
  end
end
