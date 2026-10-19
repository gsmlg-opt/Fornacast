defmodule FornacastAPI.Serializers.GitData do
  alias FornacastAPI.URL

  def render(:branch_short, branch, opts) do
    %{
      name: branch.name,
      protected: false,
      commit: %{sha: branch.oid, url: commit_url(opts, branch.oid)}
    }
  end

  def render(:branch, branch, opts) do
    base = repository_url(opts)

    %{
      name: branch.name,
      protected: false,
      commit: render(:commit_summary, branch.commit, opts),
      _links: %{
        self: base <> "/branches/" <> segment(branch.name),
        html: repository_web(opts) <> "/src/" <> segment(branch.name)
      },
      protection: %{
        enabled: false,
        required_status_checks: %{enforcement_level: "off", contexts: [], checks: []}
      },
      protection_url: base <> "/branches/" <> segment(branch.name) <> "/protection"
    }
  end

  def render(:git_ref, reference, opts) do
    %{
      ref: reference.ref,
      node_id: node("Ref", reference.ref),
      url:
        repository_url(opts) <>
          "/git/refs/" <> segment(String.replace_prefix(reference.ref, "refs/", "")),
      object: %{
        sha: reference.oid,
        type: reference.kind,
        url: repository_url(opts) <> "/git/" <> reference.kind <> "s/" <> reference.oid
      }
    }
  end

  def render(resource, commit, opts) when resource in [:commit_summary, :commit_detail] do
    value = %{
      sha: commit.oid,
      node_id: node("Commit", commit.oid),
      url: commit_url(opts, commit.oid),
      html_url: repository_web(opts) <> "/commit/" <> commit.oid,
      comments_url: commit_url(opts, commit.oid) <> "/comments",
      author: nil,
      committer: nil,
      commit: %{
        author: signature(commit.author),
        committer: signature(commit.committer),
        message: commit.message,
        tree: %{
          sha: commit.tree_oid,
          url: repository_url(opts) <> "/git/trees/" <> commit.tree_oid
        },
        url: repository_url(opts) <> "/git/commits/" <> commit.oid,
        comment_count: 0,
        verification: verification()
      },
      parents: Enum.map(commit.parents, &parent(&1, opts))
    }

    case Map.get(commit, :diff) do
      nil ->
        value

      diff ->
        Map.merge(value, %{
          stats: %{
            total: diff.additions + diff.deletions,
            additions: diff.additions,
            deletions: diff.deletions
          },
          files: Enum.map(diff.files, &file(&1, commit.oid, opts))
        })
    end
  end

  def render(:content_commit, commit, opts) do
    %{
      sha: commit.oid,
      node_id: node("Commit", commit.oid),
      url: repository_url(opts) <> "/git/commits/" <> commit.oid,
      html_url: repository_web(opts) <> "/commit/" <> commit.oid,
      message: commit.message,
      author: signature(commit.author),
      committer: signature(commit.committer),
      tree: %{sha: commit.tree_oid, url: repository_url(opts) <> "/git/trees/" <> commit.tree_oid},
      parents: Enum.map(commit.parents, &parent(&1, opts)),
      verification: verification()
    }
  end

  def render(resource, entry, opts) when resource in [:content_entry, :content_file] do
    ref = Keyword.get(opts, :ref, "main")

    url =
      repository_url(opts) <>
        "/contents/" <> path(entry.path) <> "?" <> URI.encode_query(%{"ref" => ref}, :rfc3986)

    html = repository_web(opts) <> "/src/" <> segment(ref) <> "/" <> path(entry.path)

    git =
      repository_url(opts) <>
        "/git/" <> if(entry.type == "dir", do: "trees/", else: "blobs/") <> entry.oid

    download =
      if entry.type in ["file", "symlink"],
        do: repository_web(opts) <> "/raw/" <> segment(ref) <> "/" <> path(entry.path),
        else: nil

    value = %{
      type: entry.type,
      name: entry.name,
      path: entry.path,
      sha: entry.oid,
      size: entry.size,
      url: url,
      html_url: html,
      git_url: git,
      download_url: download,
      _links: %{self: url, git: git, html: html}
    }

    cond do
      entry.type == "symlink" ->
        Map.put(value, :target, entry.content || "")

      entry.type == "submodule" ->
        Map.put(value, :submodule_git_url, nil)

      resource == :content_file ->
        Map.merge(value, %{content: Base.encode64(entry.content || ""), encoding: "base64"})

      true ->
        value
    end
  end

  defp file(file, oid, opts) do
    raw = repository_web(opts) <> "/raw/" <> oid <> "/" <> path(file.path)

    %{
      sha: file.new_oid || file.old_oid,
      filename: file.path,
      status: Atom.to_string(file.status),
      additions: file.additions,
      deletions: file.deletions,
      changes: file.additions + file.deletions,
      blob_url: repository_web(opts) <> "/src/" <> oid <> "/" <> path(file.path),
      raw_url: raw,
      contents_url: repository_url(opts) <> "/contents/" <> path(file.path) <> "?ref=" <> oid
    }
  end

  defp signature(value),
    do: %{
      name: value.name,
      email: value.email,
      date: DateTime.from_unix!(value.seconds) |> DateTime.to_iso8601()
    }

  defp parent(oid, opts),
    do: %{
      sha: oid,
      url: commit_url(opts, oid),
      html_url: repository_web(opts) <> "/commit/" <> oid
    }

  defp verification,
    do: %{verified: false, reason: "unsigned", signature: nil, payload: nil, verified_at: nil}

  defp commit_url(opts, oid), do: repository_url(opts) <> "/commits/" <> oid

  defp repository_url(opts),
    do: URL.repository(Keyword.fetch!(opts, :owner), Keyword.fetch!(opts, :repo))

  defp repository_web(opts),
    do: URL.repository_web(Keyword.fetch!(opts, :owner), Keyword.fetch!(opts, :repo))

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp path(value), do: value |> String.split("/") |> Enum.map_join("/", &segment/1)
  defp node(type, value), do: Base.url_encode64(type <> ":" <> value, padding: false)
end
