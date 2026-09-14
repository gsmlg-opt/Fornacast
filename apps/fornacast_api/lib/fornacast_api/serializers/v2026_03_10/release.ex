defmodule FornacastAPI.Serializers.V2026_03_10.Release do
  alias ForgeAccounts.{ExternalAttribution, GitHubIdentity}
  alias FornacastAPI.{Serializer, URL}

  @version "2026-03-10"

  def render(release, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    url = URL.release(owner, repo, release.id)

    %{
      assets: [],
      assets_url: URL.release_assets(owner, repo, release.id),
      author: Serializer.render(@version, :simple_user, author(release.author), opts),
      body: release.body,
      created_at: timestamp(release.inserted_at),
      draft: release.draft,
      html_url: URL.release_web(owner, repo, release.tag_name),
      id: release.id,
      immutable: false,
      name: release.name,
      node_id: Base.url_encode64("Release:#{release.id}", padding: false),
      prerelease: release.prerelease,
      published_at: timestamp(release.published_at),
      tag_name: release.tag_name,
      target_commitish: release.target_commitish,
      tarball_url: nil,
      upload_url: URL.release_upload_template(owner, repo, release.id),
      url: url,
      zipball_url: nil
    }
  end

  defp author(%GitHubIdentity{} = identity), do: ExternalAttribution.from_identity(identity)
  defp author(author), do: author

  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)
end
