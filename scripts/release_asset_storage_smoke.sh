#!/bin/sh
set -eu

release_root=${1:?release root is required}
phase=${2:?phase must be write or verify}
release_bin="${release_root}/bin/fornacast"

case "$phase" in
  write)
    "$release_bin" rpc '
      payload = "fornacast-release-asset-restart-smoke"
      reader = fn :start, options ->
        true = options[:length] <= 262_144
        {:ok, payload, :done}
      end

      {:ok, staged, metadata, :done} =
        ForgeReleases.AssetStorage.stage_from_reader(
          "release-restart-smoke",
          reader,
          :start,
          read_options: [length: 262_144, read_length: 262_144, read_timeout: 1_000]
        )

      {:ok, ^metadata} = ForgeReleases.AssetStorage.commit(staged)
      :ok
    '
    ;;
  verify)
    "$release_bin" rpc '
      payload = "fornacast-release-asset-restart-smoke"
      digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
      size = byte_size(payload)
      true = ForgeReleases.AssetStorage.Manager.ready?()
      {:ok, %{storage_key: ^digest, size: ^size}} = ForgeReleases.AssetStorage.stat(digest)
      :ok = ForgeReleases.AssetStorage.verify(digest)
      {:ok, source} = ForgeReleases.AssetStorage.open(digest, size, :all)
      {:ok, ^payload, source} = ForgeReleases.AssetStorage.read(source, 1_048_576)
      :eof = ForgeReleases.AssetStorage.read(source, 1)
      :ok = ForgeReleases.AssetStorage.close(source)
      :ok = ForgeReleases.AssetStorage.close(source)
    '
    ;;
  *)
    echo "phase must be write or verify" >&2
    exit 64
    ;;
esac
