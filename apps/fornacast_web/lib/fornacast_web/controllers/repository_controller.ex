defmodule FornacastWeb.RepositoryController do
  use FornacastWeb, :controller

  require Logger

  alias ForgeRepos.Repository
  alias FornacastWeb.{RepositoryHTML, RepositoryPage, RepositoryRaw}

  def new(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    page(
      conn,
      "New repository",
      section_header("New repository", "Create a local Git repository.", "") <>
        repository_form(user)
    )
  end

  def import_new(conn, _params) do
    page(conn, "Import repository", """
    <p class="muted">Import an existing Git repository into this Fornacast demo.</p>
    <form>
      <label>Clone URL <input name="import[url]" placeholder="https://example.com/owner/repository.git"></label>
      <label>Owner
        <select name="import[owner]">
          #{owner_options(conn.assigns.current_user)}
        </select>
      </label>
      <label>Name <input name="import[name]"></label>
      <button type="button" disabled>Import repository</button>
    </form>
    """)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"repository" => attrs}) do
    owner_slug = Map.get(attrs, "owner") || user.username

    with {:ok, owner} <- ForgeAccounts.repository_owner_by_slug_for(user, owner_slug),
         {:ok, repo} <- ForgeRepos.create_repository(owner, attrs) do
      redirect(conn, to: "/#{owner.username}/#{repo.slug}")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> page(
          "New repository",
          error_panel(inspect(changeset.errors)) <> repository_form(user, attrs)
        )

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> page("New repository", ~s(<p class="error">You cannot create repositories there.</p>))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> page("New repository", error_panel(reason) <> repository_form(user, attrs))
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> page("New repository", ~s(<p class="error">Repository parameters are required.</p>))
  end

  def show(conn, %{"owner" => owner_slug, "repo" => repo_slug} = params) do
    with_readable_repository(conn, owner_slug, repo_slug, fn owner, repository, viewer ->
      case ref_selector(params["ref"]) do
        {:ok, selector} ->
          repository_page_module(conn)
          |> apply(:code, [repository, owner, viewer, selector])
          |> handle_page_result(conn, repository, :code)

        :error ->
          repository_content_not_found(conn, repository, "Repository content not found")
      end
    end)
  end

  def branches(conn, %{"owner" => owner_slug, "repo" => repo_slug} = params) do
    with {:ok, page_number} <- positive_page(params["page"]) do
      with_readable_repository(conn, owner_slug, repo_slug, fn owner, repository, viewer ->
        repository_page_module(conn)
        |> apply(:refs, [repository, owner, viewer, :branch, page_number])
        |> handle_page_result(conn, repository, {:refs, page_number})
      end)
    else
      :error -> invalid_page(conn)
    end
  end

  def tags(conn, %{"owner" => owner_slug, "repo" => repo_slug} = params) do
    with {:ok, page_number} <- positive_page(params["page"]) do
      with_readable_repository(conn, owner_slug, repo_slug, fn owner, repository, viewer ->
        repository_page_module(conn)
        |> apply(:refs, [repository, owner, viewer, :tag, page_number])
        |> handle_page_result(conn, repository, {:refs, page_number})
      end)
    else
      :error -> invalid_page(conn)
    end
  end

  def commits(conn, %{"owner" => owner_slug, "repo" => repo_slug, "ref" => ref} = params) do
    with {:ok, page_number} <- positive_page(params["page"]) do
      route = route_segments(ref)

      with_readable_repository(conn, owner_slug, repo_slug, fn owner, repository, viewer ->
        repository_page_module(conn)
        |> apply(:commits, [repository, owner, viewer, route, page_number])
        |> handle_page_result(conn, repository, :commits)
      end)
    else
      :error -> invalid_page(conn)
    end
  end

  def commit(
        conn,
        %{"owner" => owner_slug, "repo" => repo_slug, "sha" => sha} = params
      ) do
    with_readable_repository(conn, owner_slug, repo_slug, fn owner, repository, viewer ->
      case ref_selector(params["ref"]) do
        {:ok, selector} ->
          repository_page_module(conn)
          |> apply(:commit, [repository, owner, viewer, sha, selector])
          |> handle_page_result(conn, repository, :commit)

        :error ->
          repository_content_not_found(conn, repository, "Repository content not found")
      end
    end)
  end

  def src(conn, %{"owner" => owner_slug, "repo" => repo_slug} = params) do
    with {:ok, page_number} <- positive_page(params["page"]) do
      route = repository_route_segments(params)

      with_readable_repository(conn, owner_slug, repo_slug, fn owner, repository, viewer ->
        if route == [] do
          repository_content_not_found(conn, repository, "Repository content not found")
        else
          repository_page_module(conn)
          |> apply(:tree, [repository, owner, viewer, route, page_number])
          |> handle_page_result(conn, repository, :tree)
        end
      end)
    else
      :error -> invalid_page(conn)
    end
  end

  def search(conn, %{"owner" => owner_slug, "repo" => repo_slug} = params) do
    with_readable_repository(conn, owner_slug, repo_slug, fn owner, repository, viewer ->
      case ref_selector(params["ref"]) do
        {:ok, selector} ->
          {query, validation_error} = search_query(params)
          {scope, scope_error} = search_scope(params["scope"])
          validation_error = validation_error || scope_error
          opts = if validation_error, do: [validation_error: validation_error], else: []

          conn =
            if validation_error do
              put_status(conn, :unprocessable_entity)
            else
              conn
            end

          repository_page_module(conn)
          |> apply(:search, [repository, owner, viewer, selector, query, scope, opts])
          |> handle_page_result(conn, repository, :search)

        :error ->
          repository_content_not_found(conn, repository, "Repository content not found")
      end
    end)
  end

  def raw(conn, %{"owner" => owner_slug, "repo" => repo_slug} = params) do
    route = repository_route_segments(params)

    with_readable_repository(conn, owner_slug, repo_slug, fn owner, repository, viewer ->
      if route == [] do
        repository_content_not_found(conn, repository, "Repository content not found")
      else
        repository_page_module(conn)
        |> apply(:raw, [repository, owner, viewer, route])
        |> handle_raw_result(conn, repository)
      end
    end)
  end

  defp handle_page_result({:ok, %RepositoryPage.Result{} = result}, conn, repository, context) do
    page_module = repository_page_module(conn)

    try do
      cond do
        empty_commit?(result, context) ->
          repository_content_not_found(conn, repository, "Repository content not found")

        out_of_range?(result, context) ->
          repository_content_not_found(conn, repository, "Page not found")

        true ->
          rendered =
            repository_html_module(conn).repository(%{result: result, __changed__: nil})

          conn
          |> put_private_cache_headers()
          |> FornacastWeb.HTML.repository_page(
            repository_title(result),
            Phoenix.HTML.Safe.to_iodata(rendered)
          )
      end
    after
      page_module.release(result)
    end
  end

  defp handle_page_result(
         {:error, %GitCore.Error{} = error},
         conn,
         repository,
         context
       ) do
    handle_git_error(conn, repository, error, context)
  end

  defp handle_raw_result(
         {:ok, %RepositoryPage.Result{kind: :raw} = result},
         conn,
         _repository
       ) do
    page_module = repository_page_module(conn)
    blob = result.content.blob

    try do
      if blob.truncated do
        repository_error_page(conn, :request_entity_too_large, "File is too large")
      else
        conn
        |> put_private_cache_headers()
        |> put_raw_headers(RepositoryRaw.headers(blob.name))
        |> send_resp(:ok, blob.data)
      end
    after
      page_module.release(result)
    end
  end

  defp handle_raw_result(
         {:error, %GitCore.Error{} = error},
         conn,
         repository
       ) do
    handle_git_error(conn, repository, error, :raw)
  end

  defp handle_git_error(conn, repository, %GitCore.Error{} = error, context) do
    log_git_error(conn, repository, error)

    case {context, error.kind} do
      {:raw, :blob_too_large} ->
        repository_error_page(conn, :request_entity_too_large, "File is too large")

      {:raw, :blob_busy} ->
        busy_page(conn)

      {:search, :scan_busy} ->
        busy_page(conn)

      {_context, kind} when kind in [:ref_not_found, :commit_not_found, :path_not_found] ->
        repository_content_not_found(conn, repository, "Repository content not found")

      {_context, :blob_too_large} ->
        repository_error_page(conn, :request_entity_too_large, "File is too large")

      {_context, kind}
      when kind in [:storage_unavailable, :invalid_repository, :corrupt_repository] ->
        repository_error_page(conn, :service_unavailable, "Repository data unavailable")

      {_context, kind} when kind in [:blob_busy, :scan_busy, :scan_timeout] ->
        repository_error_page(
          conn,
          :service_unavailable,
          "Repository temporarily unavailable"
        )

      {_context, _kind} ->
        repository_error_page(
          conn,
          :service_unavailable,
          "Repository temporarily unavailable"
        )
    end
  end

  defp with_readable_repository(conn, owner_slug, repo_slug, fun) do
    viewer = conn.assigns[:current_user]

    with %Repository{} = repository <- ForgeRepos.get_repository(owner_slug, repo_slug),
         :ok <- Fornacast.Access.authorize(viewer, :repository_read, repository),
         owner when not is_nil(owner) <- ForgeAccounts.get_account_by_username(owner_slug) do
      fun.(owner, repository, viewer)
    else
      _reason -> repository_not_found(conn)
    end
  end

  defp out_of_range?(%RepositoryPage.Result{kind: :empty}, {:refs, requested_page}),
    do: requested_page > 1

  defp out_of_range?(
         %RepositoryPage.Result{
           content: %RepositoryPage.Refs{page: page}
         },
         _context
       ),
       do: page.page > page.total_pages

  defp out_of_range?(
         %RepositoryPage.Result{
           content: %RepositoryPage.Commits{page: page}
         },
         _context
       ),
       do: page.page > page.total_pages

  defp out_of_range?(
         %RepositoryPage.Result{
           content: %RepositoryPage.Tree{tree: page}
         },
         _context
       ),
       do: page.page > page.total_pages

  defp out_of_range?(_result, _context), do: false

  defp empty_commit?(%RepositoryPage.Result{kind: :empty}, :commit), do: true
  defp empty_commit?(_result, _context), do: false

  defp positive_page(nil), do: {:ok, 1}

  defp positive_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> :error
    end
  end

  defp positive_page(_page), do: :error

  defp ref_selector(nil), do: {:ok, nil}

  defp ref_selector("refs/heads/" <> name = full_name) when name != "" do
    {:ok, %GitCore.RefSelector{kind: :branch, full_name: full_name}}
  end

  defp ref_selector("refs/tags/" <> name = full_name) when name != "" do
    {:ok, %GitCore.RefSelector{kind: :tag, full_name: full_name}}
  end

  defp ref_selector(ref) when is_binary(ref) do
    {:ok, %GitCore.RefSelector{kind: :legacy, full_name: ref}}
  end

  defp ref_selector(_ref), do: :error

  defp search_query(%{"q" => query}) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" -> {query, :query_required}
      String.length(query) > 200 -> {query, :query_too_long}
      true -> {query, nil}
    end
  end

  defp search_query(%{"q" => _query}), do: {"", :query_required}
  defp search_query(_params), do: {nil, nil}

  defp search_scope(nil), do: {:path, nil}
  defp search_scope("path"), do: {:path, nil}
  defp search_scope("content"), do: {:content, nil}
  defp search_scope(_scope), do: {:path, :invalid_scope}

  defp repository_route_segments(%{"segments" => segments}) when is_list(segments),
    do: segments

  defp repository_route_segments(%{"ref" => ref} = params) do
    route_segments(ref) ++ route_segments(params["path"] || [])
  end

  defp repository_route_segments(_params), do: []

  defp route_segments(segments) when is_list(segments), do: segments
  defp route_segments(segment) when is_binary(segment), do: [segment]
  defp route_segments(_segment), do: []

  defp repository_not_found(conn) do
    css_path =
      DuskmoonBundler.static_path(FornacastWeb.Endpoint, "/assets/css/app.css",
        profile: :fornacast_web
      )

    js_path =
      DuskmoonBundler.static_path(FornacastWeb.Endpoint, "/assets/js/app.js",
        profile: :fornacast_web
      )

    body = [
      "<!doctype html><html lang=\"en\" data-theme=\"sunshine\"><head>",
      "<meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "<title>Repository not found - Fornacast</title>",
      "<link rel=\"stylesheet\" href=\"",
      FornacastWeb.HTML.escape(css_path),
      "\">",
      "<script type=\"module\" src=\"",
      FornacastWeb.HTML.escape(js_path),
      "\"></script></head>",
      "<body class=\"app-body bg-surface text-on-surface\">",
      "<div class=\"repository-shell\" data-repository-shell=\"not-found\">",
      "<header class=\"appbar appbar-primary appbar-sticky\">",
      "<a class=\"brand-mark\" href=\"/\" aria-label=\"Fornacast home\">Fornacast</a>",
      "</header><main class=\"repository-main\" data-repository-main>",
      "<article class=\"repository-page repository-not-found\" ",
      "data-repository-kind=\"not-found\">",
      "<section class=\"repository-optional-panel repository-optional-panel--empty\">",
      "<h1>Repository not found</h1>",
      "<p>The repository could not be found.</p>",
      "</section></article></main></div></body></html>"
    ]

    conn
    |> put_private_cache_headers()
    |> put_status(:not_found)
    |> put_resp_content_type("text/html")
    |> send_resp(:not_found, body)
  end

  defp repository_content_not_found(conn, repository, message) do
    href = repository_href(repository)

    conn
    |> put_private_cache_headers()
    |> put_status(:not_found)
    |> FornacastWeb.HTML.repository_page(
      message,
      [
        "<article class=\"repository-page repository-content-not-found\" ",
        "data-repository-kind=\"content-not-found\">",
        "<section class=\"repository-optional-panel repository-optional-panel--empty\">",
        "<h1>",
        FornacastWeb.HTML.escape(message),
        "</h1><p>The requested repository content could not be found.</p>",
        "<a href=\"",
        FornacastWeb.HTML.escape(href),
        "\">Return to Code</a>",
        "</section></article>"
      ]
    )
  end

  defp invalid_page(conn) do
    repository_error_page(conn, :unprocessable_entity, "Page must be a positive integer")
  end

  defp busy_page(conn) do
    conn
    |> put_resp_header("retry-after", "1")
    |> repository_error_page(:too_many_requests, "Repository is busy")
  end

  defp repository_error_page(conn, status, message) do
    conn
    |> put_private_cache_headers()
    |> put_status(status)
    |> FornacastWeb.HTML.repository_page(
      message,
      [
        "<article class=\"repository-page repository-error\" data-repository-kind=\"error\">",
        "<section class=\"repository-optional-panel repository-optional-panel--warning\">",
        "<h1>",
        FornacastWeb.HTML.escape(message),
        "</h1><p>Please try again later.</p>",
        "</section></article>"
      ]
    )
  end

  defp put_private_cache_headers(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp put_raw_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end

  defp repository_href(repository) do
    owner = ForgeRepos.repository_owner(repository)

    "/" <>
      URI.encode(owner.username, &URI.char_unreserved?/1) <>
      "/" <> URI.encode(repository.slug, &URI.char_unreserved?/1)
  end

  defp repository_title(result) do
    "#{result.chrome.owner.username}/#{result.chrome.repository.slug}"
  end

  defp log_git_error(conn, repository, %GitCore.Error{
         kind: kind,
         operation: operation
       }) do
    request_id =
      conn
      |> get_resp_header("x-request-id")
      |> List.first()
      |> case do
        nil -> "unknown"
        value -> value
      end

    Logger.warning(
      "repository read failed kind=#{kind} operation=#{operation} " <>
        "repository_id=#{repository.id} request_id=#{request_id}"
    )
  end

  defp repository_page_module(conn),
    do: conn.private[:repository_page] || RepositoryPage

  defp repository_html_module(conn),
    do: conn.private[:repository_html] || RepositoryHTML

  defp repository_form(user, attrs \\ %{}) do
    selected_owner = Map.get(attrs, "owner") || user.username
    selected_visibility = Map.get(attrs, "visibility") || "private"

    form_panel(
      "Repository details",
      "Choose a short slug and default visibility for the repository.",
      """
      <form action="/repos" method="post">
        #{csrf_input()}
        <label>Owner
          <select name="repository[owner]">
            #{owner_options(user, selected_owner)}
          </select>
        </label>
        <label>Name <input name="repository[name]" value="#{escape(Map.get(attrs, "name"))}"></label>
        <label>Slug <input name="repository[slug]" value="#{escape(Map.get(attrs, "slug"))}"></label>
        <label>Description <textarea name="repository[description]" rows="3">#{escape(Map.get(attrs, "description"))}</textarea></label>
        <label>Visibility
          <select name="repository[visibility]">
            <option value="private"#{selected_attr(selected_visibility, "private")}>Private</option>
            <option value="public"#{selected_attr(selected_visibility, "public")}>Public</option>
          </select>
        </label>
        <button class="btn btn-primary" type="submit">Create repository</button>
      </form>
      """
    )
  end

  defp owner_options(user, selected_owner \\ nil) do
    user
    |> ForgeAccounts.list_repository_owners()
    |> Enum.map(fn owner ->
      label = "#{owner_label(owner)} (#{owner.username})"
      selected = selected_attr(owner.username, selected_owner)
      ~s(<option value="#{escape(owner.username)}"#{selected}>#{escape(label)}</option>)
    end)
    |> Enum.join("\n")
  end

  defp selected_attr(value, value), do: " selected"
  defp selected_attr(_value, _selected), do: ""

  defp owner_label(%{kind: :organization, display_name: display_name, username: username}) do
    display_name || username
  end

  defp owner_label(%{username: username}), do: username
end
