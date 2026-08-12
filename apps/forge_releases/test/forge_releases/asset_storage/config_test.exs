defmodule ForgeReleases.AssetStorage.ConfigTest do
  use ExUnit.Case, async: true

  alias ExStorageService.InstanceConfig
  alias Fornacast.Config

  @workers [
    :multipart_gc,
    :content_gc,
    :cas_gc,
    :packer,
    :lifecycle,
    :cross_cluster_replication,
    :repair,
    :scrub
  ]

  test "test environment has one exact, listener-free LocalCAS instance" do
    root = Config.release_asset_storage_root()

    assert Path.type(root) == :absolute
    assert root == Path.expand("../../../../../tmp/test/release-assets", __DIR__)
    assert Config.release_asset_max_bytes() == 2_147_483_648
    assert Config.release_asset_gc_grace_seconds() == 86_400

    assert {:ok, instance} = InstanceConfig.from_application_env()
    assert instance.instance == :fornacast_release_assets
    assert instance.mode == :standalone
    assert instance.node_role == :data
    refute instance.auto_start
    refute instance.web_enabled
    refute instance.public_s3_enabled
    refute instance.cluster_data_plane_enabled
    assert Enum.all?(@workers, &(instance.workers[&1] == false))

    assert instance.data_root == root
    assert instance.blob_root == Path.join(root, "cas")
    assert instance.tmp_root == Path.join(root, "tmp")
    assert instance.ra_root == Path.join(root, "ra")
    assert instance.metadata_root == Path.join(root, "concord")
  end

  test "Concord uses the singleton VSR while retaining Turso ConfigStore" do
    concord = Application.fetch_env!(:concord, :vsr)

    assert Application.fetch_env!(:concord, :cluster_enabled)

    assert Application.fetch_env!(:concord, :data_dir) ==
             Path.join(Config.release_asset_storage_root(), "concord")

    assert concord == [
             group_id: :ex_storage_service_metadata,
             replica_id: node(),
             members: [%{id: node(), endpoint: node()}],
             storage: :file,
             bootstrap: false
           ]

    assert Application.fetch_env!(:concord, :turso)[:enabled]
  end
end
