defmodule FornacastWeb.RepositoryPaths do
  @moduledoc "Canonical repository destinations and ref selection for the Web adapter."
  alias FornacastWeb.RepositoryPage

  def code_path(chrome) do
    case selected_full_ref(chrome) do
      nil -> repository_base(chrome)
      ref -> repository_base(chrome) <> "?ref=" <> URI.encode_www_form(ref)
    end
  end

  def commits_path(chrome) do
    ref = selected_or_default_full_ref(chrome)
    repository_base(chrome) <> "/commits/" <> encode_repository_path(ref)
  end

  def refs_path(chrome, :branch), do: repository_base(chrome) <> "/branches"
  def refs_path(chrome, :tag), do: repository_base(chrome) <> "/tags"
  def releases_path(chrome), do: repository_base(chrome) <> "/releases"
  def issues_path(chrome), do: repository_base(chrome) <> "/issues"
  def new_issue_path(chrome), do: issues_path(chrome) <> "/new"
  def issue_path(chrome, number), do: issues_path(chrome) <> "/" <> encode_segment(number)
  def edit_issue_path(chrome, number), do: issue_path(chrome, number) <> "/edit"
  def issue_comments_path(chrome, number), do: issue_path(chrome, number) <> "/comments"

  def issue_comment_path(chrome, number, comment_id),
    do: issue_comments_path(chrome, number) <> "/" <> encode_segment(comment_id)

  def issue_state_path(chrome, number), do: issue_path(chrome, number) <> "/state"
  def pulls_path(chrome), do: repository_base(chrome) <> "/pulls"
  def new_pull_path(chrome), do: pulls_path(chrome) <> "/new"
  def pull_path(chrome, number), do: pulls_path(chrome) <> "/" <> encode_segment(number)
  def pull_commits_path(chrome, number), do: pull_path(chrome, number) <> "/commits"
  def pull_files_path(chrome, number), do: pull_path(chrome, number) <> "/files"
  def pull_state_path(chrome, number), do: pull_path(chrome, number) <> "/state"
  def pull_merge_path(chrome, number), do: pull_path(chrome, number) <> "/merge"

  def ref_code_path(chrome, full_ref) do
    repository_base(chrome) <> "?ref=" <> URI.encode_www_form(full_ref)
  end

  def commit_path(chrome, oid) do
    path = repository_base(chrome) <> "/commit/" <> encode_segment(oid)

    case selected_full_ref(chrome) do
      nil -> path
      ref -> path <> "?ref=" <> URI.encode_www_form(ref)
    end
  end

  def source_path(chrome, path \\ "") do
    ref = selected_full_ref(chrome)
    base = repository_base(chrome) <> "/src/" <> encode_repository_path(ref || "")

    if path in [nil, ""] do
      base
    else
      base <> "/" <> encode_repository_path(path)
    end
  end

  def raw_path(chrome, path) do
    ref = selected_full_ref(chrome)

    repository_base(chrome) <>
      "/raw/" <> encode_repository_path(ref || "") <> "/" <> encode_repository_path(path)
  end

  def search_path(chrome), do: repository_base(chrome) <> "/search"

  def search_path(chrome, :path) do
    repository_base(chrome) <>
      "/search?ref=" <>
      URI.encode_www_form(selected_or_default_full_ref(chrome)) <> "&scope=path"
  end

  def selected_full_ref(%RepositoryPage.Result{chrome: chrome}), do: selected_full_ref(chrome)
  def selected_full_ref(%RepositoryPage.Chrome{snapshot: nil}), do: nil
  def selected_full_ref(%RepositoryPage.Chrome{snapshot: snapshot}), do: snapshot.ref

  def selected_or_default_full_ref(%RepositoryPage.Result{chrome: chrome}),
    do: selected_or_default_full_ref(chrome)

  def selected_or_default_full_ref(%RepositoryPage.Chrome{} = chrome) do
    selected_full_ref(chrome) || canonical_default_ref(chrome.repository.default_branch)
  end

  def repository_base(%RepositoryPage.Chrome{owner: owner, repository: repository}) do
    "/" <> encode_segment(owner.username) <> "/" <> encode_segment(repository.slug)
  end

  defp canonical_default_ref("refs/" <> _rest = ref), do: ref
  defp canonical_default_ref(ref) when is_binary(ref), do: "refs/heads/" <> ref

  def breadcrumb_items(chrome, path) do
    root = [{chrome.repository.name || chrome.repository.slug, source_path(chrome), path == ""}]
    segments = String.split(path, "/", trim: true)

    {crumbs, _parts} =
      Enum.map_reduce(segments, [], fn segment, prior ->
        parts = prior ++ [segment]
        current_path = Enum.join(parts, "/")
        {{segment, source_path(chrome, current_path), current_path == path}, parts}
      end)

    root ++ crumbs
  end

  def page_href(base_href, page) do
    separator = if String.contains?(base_href, "?"), do: "&", else: "?"
    base_href <> separator <> "page=#{page}"
  end

  defp encode_repository_path(path) do
    path
    |> to_string()
    |> String.split("/", trim: false)
    |> Enum.map_join("/", &encode_segment/1)
  end

  defp encode_segment(segment), do: URI.encode(to_string(segment), &URI.char_unreserved?/1)
  def owner_path(%RepositoryPage.Chrome{owner: owner}), do: "/" <> encode_segment(owner.username)
end
