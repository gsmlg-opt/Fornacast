defmodule FornacastAPI.Serializers.ReleaseAsset do
  alias ForgeAccounts.{ExternalAttribution, GitHubIdentity}
  alias FornacastAPI.{Serializer, URL}

  def render(asset, opts, version) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)

    %{
      id: asset.id,
      node_id: Base.url_encode64("ReleaseAsset:#{asset.id}", padding: false),
      name: asset.name,
      label: asset.label,
      content_type: asset.content_type,
      size: asset.size,
      digest: "sha256:" <> asset.sha256_digest,
      state: "uploaded",
      download_count: asset.download_count + asset.source_download_count,
      uploader: uploader(asset.uploader, version, opts),
      created_at: DateTime.to_iso8601(asset.inserted_at),
      updated_at: DateTime.to_iso8601(asset.updated_at),
      url: URL.release_asset(owner, repo, asset.id),
      browser_download_url: URL.release_asset(owner, repo, asset.id) <> "/download"
    }
  end

  defp uploader(nil, _version, _opts), do: nil

  defp uploader(%GitHubIdentity{} = identity, version, opts),
    do: uploader(ExternalAttribution.from_identity(identity), version, opts)

  defp uploader(value, version, opts), do: Serializer.render(version, :simple_user, value, opts)
end
