defmodule FornacastAPI.Serializers.V2022_11_28.Release do
  alias ForgeAccounts.{ExternalAttribution, GitHubIdentity}
  alias FornacastAPI.{Serializer, URL}

  @version "2022-11-28"

  def render(release, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    url = URL.release(owner, repo, release.id)

    %{
      assets:
        Enum.map(
          release.assets || [],
          &FornacastAPI.Serializers.ReleaseAsset.render(&1, opts, @version)
        ),
      assets_url: URL.release_assets(owner, repo, release.id),
      author: Serializer.render(@version, :simple_user, author(release.author), opts),
      body: release.body,
      body_html: source(release, "body_html", ForgeReleases.Notes.body_html(release.body)),
      body_text: source(release, "body_text", ForgeReleases.Notes.body_text(release.body)),
      mentions_count: source(release, "mentions_count", 0),
      reactions: source(release, "reactions", nil),
      discussion_url: source(release, "discussion_url", nil),
      created_at: timestamp(release.inserted_at),
      draft: release.draft,
      html_url: URL.release_web(owner, repo, release.tag_name),
      id: release.id,
      immutable: release.immutable,
      name: release.name,
      node_id: Base.url_encode64("Release:#{release.id}", padding: false),
      prerelease: release.prerelease,
      published_at: timestamp(release.published_at),
      tag_name: release.tag_name,
      target_commitish: release.target_commitish,
      tarball_url: URL.release_archive(owner, repo, release.id, "tar"),
      upload_url: URL.release_upload_template(owner, repo, release.id),
      url: url,
      zipball_url: URL.release_archive(owner, repo, release.id, "zip"),
      updated_at: timestamp(release.updated_at)
    }
    |> Map.reject(fn {key, value} -> key in [:reactions, :discussion_url] and is_nil(value) end)
  end

  defp author(%GitHubIdentity{} = identity), do: ExternalAttribution.from_identity(identity)
  defp author(author), do: author

  defp source(release, key, fallback),
    do: Map.get(release.source_metadata || %{}, key) || fallback

  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)
end
