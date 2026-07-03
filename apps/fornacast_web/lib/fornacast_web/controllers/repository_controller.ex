defmodule FornacastWeb.RepositoryController do
  use FornacastWeb, :controller

  alias ForgeRepos.Repository

  @inline_blob_limit 1_048_576

  def new(conn, _params) do
    page(conn, "New repository", """
    <form action="/repos" method="post">
      #{csrf_input()}
      <label>Name <input name="repository[name]"></label>
      <label>Slug <input name="repository[slug]"></label>
      <label>Description <textarea name="repository[description]" rows="3"></textarea></label>
      <label>Visibility
        <select name="repository[visibility]">
          <option value="private">Private</option>
          <option value="public">Public</option>
        </select>
      </label>
      <button type="submit">Create repository</button>
    </form>
    """)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"repository" => attrs}) do
    case ForgeRepos.create_repository(user, attrs) do
      {:ok, repo} ->
        redirect(conn, to: "/#{user.username}/#{repo.slug}")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> page("New repository", ~s(<p class="error">#{escape(inspect(changeset.errors))}</p>))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> page("New repository", ~s(<p class="error">#{escape(reason)}</p>))
    end
  end

  def show(conn, %{"owner" => owner_slug, "repo" => repo_slug}) do
    case load_readable_repository(conn, owner_slug, repo_slug) do
      {:ok, owner, repo} ->
        body =
          case ForgeRepos.empty?(repo) do
            {:ok, true} -> empty_repository_body(owner, repo)
            {:ok, false} -> repository_overview_body(owner, repo)
            {:error, reason} -> ~s(<p class="error">#{escape(reason)}</p>)
          end

        page(conn, "#{owner.username}/#{repo.slug}", body)

      {:error, conn} ->
        conn
    end
  end

  def branches(conn, %{"owner" => owner_slug, "repo" => repo_slug}) do
    case load_readable_repository(conn, owner_slug, repo_slug) do
      {:ok, owner, repo} ->
        refs =
          repo
          |> ForgeRepos.absolute_storage_path()
          |> GitCore.branches()

        page(conn, "Branches: #{owner.username}/#{repo.slug}", refs_table(refs, "Branch"))

      {:error, conn} ->
        conn
    end
  end

  def tags(conn, %{"owner" => owner_slug, "repo" => repo_slug}) do
    case load_readable_repository(conn, owner_slug, repo_slug) do
      {:ok, owner, repo} ->
        refs =
          repo
          |> ForgeRepos.absolute_storage_path()
          |> GitCore.tags()

        page(conn, "Tags: #{owner.username}/#{repo.slug}", refs_table(refs, "Tag"))

      {:error, conn} ->
        conn
    end
  end

  def commits(conn, %{"owner" => owner_slug, "repo" => repo_slug, "ref" => ref}) do
    ref = ref_param(ref)

    case load_readable_repository(conn, owner_slug, repo_slug) do
      {:ok, owner, repo} ->
        repo
        |> ForgeRepos.absolute_storage_path()
        |> GitCore.commit_history(ref)
        |> case do
          {:ok, commits} ->
            page(
              conn,
              "Commits: #{owner.username}/#{repo.slug}",
              commits_table(owner, repo, commits)
            )

          {:error, reason} ->
            conn
            |> put_status(:not_found)
            |> page("Commits not found", ~s(<p class="error">#{escape(reason)}</p>))
        end

      {:error, conn} ->
        conn
    end
  end

  def commit(conn, %{"owner" => owner_slug, "repo" => repo_slug, "sha" => sha}) do
    case load_readable_repository(conn, owner_slug, repo_slug) do
      {:ok, owner, repo} ->
        storage_path = ForgeRepos.absolute_storage_path(repo)

        case GitCore.commit(storage_path, sha) do
          {:ok, commit} ->
            diff = GitCore.diff_commit(storage_path, commit.oid)

            page(
              conn,
              "Commit #{String.slice(commit.oid, 0, 12)}",
              commit_detail(owner, repo, commit, diff)
            )

          {:error, reason} ->
            conn
            |> put_status(:not_found)
            |> page("Commit not found", ~s(<p class="error">#{escape(reason)}</p>))
        end

      {:error, conn} ->
        conn
    end
  end

  def src(conn, %{"ref" => ref} = params) do
    src(conn, Map.put(params, "segments", [ref | path_segments(params)]))
  end

  def src(conn, %{"owner" => owner_slug, "repo" => repo_slug} = params) do
    segments = path_segments(params)

    case load_readable_repository(conn, owner_slug, repo_slug) do
      {:ok, owner, repo} ->
        storage_path = ForgeRepos.absolute_storage_path(repo)

        case resolve_ref_and_path(storage_path, segments) do
          {:ok, ref, browse_path} ->
            render_src_path(conn, owner, repo, storage_path, ref, browse_path)

          {:error, reason} ->
            conn
            |> put_status(:not_found)
            |> page("Path not found", ~s(<p class="error">#{escape(reason)}</p>))
        end

      {:error, conn} ->
        conn
    end
  end

  def raw(conn, %{"ref" => ref} = params) do
    raw(conn, Map.put(params, "segments", [ref | path_segments(params)]))
  end

  def raw(conn, %{"owner" => owner_slug, "repo" => repo_slug} = params) do
    segments = path_segments(params)

    case load_readable_repository(conn, owner_slug, repo_slug) do
      {:ok, _owner, repo} ->
        storage_path = ForgeRepos.absolute_storage_path(repo)

        with {:ok, ref, blob_path} <- resolve_ref_and_path(storage_path, segments),
             {:ok, blob} <- GitCore.read_blob(storage_path, ref, blob_path, limit: 100_000_000) do
          filename = String.replace(blob.name, ~s("), "")

          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header("content-disposition", ~s(inline; filename="#{filename}"))
          |> send_resp(200, blob.data)
        else
          {:error, reason} when is_binary(reason) ->
            conn
            |> put_status(:not_found)
            |> text(reason)
        end

      {:error, conn} ->
        conn
    end
  end

  defp load_readable_repository(conn, owner_slug, repo_slug) do
    current_user = conn.assigns[:current_user]

    with owner when not is_nil(owner) <- ForgeAccounts.get_user_by_username(owner_slug),
         %Repository{} = repo <- ForgeRepos.get_repository(owner_slug, repo_slug),
         :ok <- Fornacast.Access.authorize(current_user, :repository_read, repo) do
      {:ok, owner, repo}
    else
      {:error, :unauthorized} ->
        conn =
          conn
          |> put_status(:forbidden)
          |> page(
            "Forbidden",
            ~s(<p class="error">You do not have access to this repository.</p>)
          )

        {:error, conn}

      _ ->
        conn =
          conn
          |> put_status(:not_found)
          |> page("Not found", ~s(<p class="error">Repository not found.</p>))

        {:error, conn}
    end
  end

  defp empty_repository_body(owner, repo) do
    clone_url = ForgeRepos.ssh_clone_url(repo, owner)

    """
    <p class="muted">Private #{escape(repo.visibility)} repository. Default branch: #{escape(repo.default_branch)}</p>
    <h3>Clone URL</h3>
    <pre>#{escape(clone_url)}</pre>
    <h3>Push an existing project</h3>
    <pre>git init
    git remote add origin #{escape(clone_url)}
    git branch -M #{escape(repo.default_branch)}
    git push -u origin #{escape(repo.default_branch)}</pre>
    """
  end

  defp repository_overview_body(owner, repo) do
    readme = readme_preview(repo)

    """
    <p class="muted">#{escape(repo.description || "")}</p>
    <nav>
      <a href="/#{escape(owner.username)}/#{escape(repo.slug)}/src/#{escape(repo.default_branch)}">Code</a>
      <a href="/#{escape(owner.username)}/#{escape(repo.slug)}/commits/#{escape(repo.default_branch)}">Commits</a>
      <a href="/#{escape(owner.username)}/#{escape(repo.slug)}/branches">Branches</a>
      <a href="/#{escape(owner.username)}/#{escape(repo.slug)}/tags">Tags</a>
    </nav>
    #{readme}
    """
  end

  defp refs_table({:ok, refs}, label) do
    rows =
      refs
      |> Enum.map(fn ref ->
        display_name =
          ref.name
          |> String.replace_prefix("refs/heads/", "")
          |> String.replace_prefix("refs/tags/", "")

        ~s(<tr><td>#{escape(display_name)}</td><td><code>#{escape(String.slice(ref.target, 0, 12))}</code></td></tr>)
      end)
      |> Enum.join("\n")

    """
    <table>
      <thead><tr><th>#{escape(label)}</th><th>Target</th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """
  end

  defp refs_table({:error, reason}, _label) do
    ~s(<p class="error">#{escape(reason)}</p>)
  end

  defp render_src_path(conn, owner, repo, storage_path, ref, browse_path) do
    case GitCore.read_tree(storage_path, ref, browse_path) do
      {:ok, entries} ->
        page(
          conn,
          "Source: #{owner.username}/#{repo.slug}",
          tree_view(owner, repo, ref, browse_path, entries)
        )

      {:error, _reason} ->
        case GitCore.read_blob(storage_path, ref, browse_path, limit: @inline_blob_limit) do
          {:ok, blob} ->
            page(conn, "File: #{blob.name}", blob_view(owner, repo, ref, browse_path, blob))

          {:error, reason} ->
            conn
            |> put_status(:not_found)
            |> page("Path not found", ~s(<p class="error">#{escape(reason)}</p>))
        end
    end
  end

  defp resolve_ref_and_path(_storage_path, []), do: {:error, "missing ref"}

  defp resolve_ref_and_path(storage_path, segments) do
    segments
    |> ref_path_candidates()
    |> Enum.find_value(fn {ref, path} ->
      case GitCore.read_tree(storage_path, ref, "") do
        {:ok, _entries} -> {:ok, ref, path}
        {:error, _reason} -> nil
      end
    end)
    |> case do
      nil -> {:error, "ref not found"}
      result -> result
    end
  end

  defp ref_path_candidates(segments) do
    for ref_count <- length(segments)..1//-1 do
      {ref_segments, path_segments} = Enum.split(segments, ref_count)
      {Enum.join(ref_segments, "/"), Enum.join(path_segments, "/")}
    end
  end

  defp ref_param(ref) when is_list(ref), do: Enum.join(ref, "/")
  defp ref_param(ref), do: ref

  defp path_segments(%{"segments" => segments}) when is_list(segments), do: segments
  defp path_segments(%{"path" => path}) when is_list(path), do: path
  defp path_segments(_params), do: []

  defp commits_table(owner, repo, commits) do
    rows =
      commits
      |> Enum.map(fn commit ->
        """
        <tr>
          <td><a href="/#{escape(owner.username)}/#{escape(repo.slug)}/commit/#{escape(commit.oid)}"><code>#{escape(String.slice(commit.oid, 0, 12))}</code></a></td>
          <td>#{escape(commit.title)}</td>
          <td>#{escape(commit.author_name)}</td>
          <td>#{escape(format_unix(commit.author_time))}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    """
    <table>
      <thead><tr><th>Commit</th><th>Title</th><th>Author</th><th>Date</th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """
  end

  defp commit_detail(owner, repo, commit, diff) do
    parents =
      commit.parents
      |> Enum.map(fn parent ->
        ~s(<a href="/#{escape(owner.username)}/#{escape(repo.slug)}/commit/#{escape(parent)}"><code>#{escape(String.slice(parent, 0, 12))}</code></a>)
      end)
      |> Enum.join(" ")

    """
    <p><code>#{escape(commit.oid)}</code></p>
    <pre>#{escape(commit.message)}</pre>
    <table>
      <tbody>
        <tr><th>Author</th><td>#{escape(commit.author_name)} &lt;#{escape(commit.author_email)}&gt; #{escape(format_unix(commit.author_time))}</td></tr>
        <tr><th>Committer</th><td>#{escape(commit.committer_name)} &lt;#{escape(commit.committer_email)}&gt; #{escape(format_unix(commit.committer_time))}</td></tr>
        <tr><th>Parents</th><td>#{parents}</td></tr>
      </tbody>
    </table>
    #{commit_diff(diff)}
    """
  end

  defp commit_diff({:ok, %GitCore.CommitDiff{} = diff}) do
    rows =
      diff.files
      |> Enum.map(fn file ->
        """
        <tr>
          <td>#{escape(file.status)}</td>
          <td>#{escape(file.path)}</td>
          <td>#{if file.binary, do: "Binary", else: "Text"}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    warning =
      if diff.truncated do
        ~s(<p class="muted">Diff truncated at the configured display limit.</p>)
      else
        ""
      end

    patch =
      if diff.patch == "" do
        ~s(<p class="muted">No file changes were found for this commit.</p>)
      else
        ~s(<pre>#{escape(diff.patch)}</pre>)
      end

    """
    <h3>Changed files</h3>
    <table>
      <thead><tr><th>Status</th><th>Path</th><th>Content</th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    <h3>Unified diff</h3>
    #{warning}
    #{patch}
    """
  end

  defp commit_diff({:error, reason}) do
    ~s(<p class="error">Unable to render diff: #{escape(reason)}</p>)
  end

  defp tree_view(owner, repo, ref, browse_path, entries) do
    rows =
      entries
      |> Enum.map(fn entry ->
        child_path = join_path(browse_path, entry.name)
        route = if entry.kind == :tree, do: "src", else: "src"

        """
        <tr>
          <td><a href="/#{escape(owner.username)}/#{escape(repo.slug)}/#{route}/#{escape(ref)}/#{escape(child_path)}">#{escape(entry.name)}</a></td>
          <td>#{escape(entry.kind)}</td>
          <td><code>#{escape(String.slice(entry.oid, 0, 12))}</code></td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    up_link =
      case parent_path(browse_path) do
        nil ->
          ""

        parent ->
          ~s(<p><a href="/#{escape(owner.username)}/#{escape(repo.slug)}/src/#{escape(ref)}/#{escape(parent)}">..</a></p>)
      end

    """
    <p class="muted">#{escape(ref)} / #{escape(browse_path)}</p>
    #{up_link}
    <table>
      <thead><tr><th>Name</th><th>Kind</th><th>Object</th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """
  end

  defp blob_view(owner, repo, ref, blob_path, blob) do
    raw_url =
      "/#{escape(owner.username)}/#{escape(repo.slug)}/raw/#{escape(ref)}/#{escape(blob_path)}"

    body =
      cond do
        blob.binary or not String.valid?(blob.data) ->
          ~s(<p class="muted">Binary or non-UTF-8 files are not rendered inline.</p>)

        blob.truncated ->
          """
          <p class="muted">This file is larger than #{@inline_blob_limit} bytes and was truncated.</p>
          <pre>#{escape(blob.data)}</pre>
          """

        true ->
          ~s(<pre>#{escape(blob.data)}</pre>)
      end

    """
    <p class="muted">#{escape(blob_path)} · #{blob.size} bytes · <a href="#{raw_url}">Raw</a></p>
    #{body}
    """
  end

  defp readme_preview(repo) do
    storage_path = ForgeRepos.absolute_storage_path(repo)

    ["README.md", "README", "README.txt"]
    |> Enum.find_value(fn path ->
      case GitCore.read_blob(storage_path, repo.default_branch, path, limit: @inline_blob_limit) do
        {:ok, %GitCore.Blob{binary: false} = blob} when is_binary(blob.data) ->
          if String.valid?(blob.data), do: render_readme(path, blob)

        _ ->
          nil
      end
    end)
    |> case do
      nil -> ""
      html -> html
    end
  end

  defp render_readme(path, blob) do
    content = to_string(blob.data)

    body =
      if String.ends_with?(String.downcase(path), ".md") do
        MDEx.to_html!(content, sanitize: MDEx.Document.default_sanitize_options())
      else
        ~s(<pre>#{escape(content)}</pre>)
      end

    """
    <section>
      <h3>#{escape(path)}</h3>
      #{body}
    </section>
    """
  end

  defp join_path("", child), do: child
  defp join_path(parent, child), do: parent <> "/" <> child

  defp parent_path(""), do: nil

  defp parent_path(path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> case do
      [] -> ""
      parts -> Enum.join(parts, "/")
    end
  end

  defp format_unix(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      {:error, _reason} -> Integer.to_string(seconds)
    end
  end
end
