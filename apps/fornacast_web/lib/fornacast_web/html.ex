defmodule FornacastWeb.HTML do
  @moduledoc false

  import Phoenix.HTML
  import Plug.Conn

  def page(conn, title, body) do
    current_user = conn.assigns[:current_user]

    css_path =
      DuskmoonBundler.static_path(FornacastWeb.Endpoint, "/assets/css/app.css",
        profile: :fornacast_web
      )

    js_path =
      DuskmoonBundler.static_path(FornacastWeb.Endpoint, "/assets/js/app.js",
        profile: :fornacast_web
      )

    preload_tags = preload_tags()
    escaped_title = escape(title)

    html =
      """
      <!doctype html>
      <html lang="en" data-theme="sunshine">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="csrf-token" content="#{Plug.CSRFProtection.get_csrf_token()}">
        <title>#{escaped_title} - Fornacast</title>
        #{preload_tags}
        <link rel="stylesheet" href="#{escape(css_path)}">
        <script type="module" src="#{escape(js_path)}"></script>
      </head>
      <body class="app-body bg-surface text-on-surface">
        #{app_shell(current_user, escaped_title, body)}
      </body>
      </html>
      """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(conn.status || 200, html)
  end

  def repository_page(conn, title, safe_body) do
    current_user = conn.assigns[:current_user]

    css_path =
      DuskmoonBundler.static_path(FornacastWeb.Endpoint, "/assets/css/app.css",
        profile: :fornacast_web
      )

    js_path =
      DuskmoonBundler.static_path(FornacastWeb.Endpoint, "/assets/js/app.js",
        profile: :fornacast_web
      )

    html = [
      "<!doctype html><html lang=\"en\" data-theme=\"sunshine\"><head>",
      "<meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "<meta name=\"csrf-token\" content=\"",
      escape(Plug.CSRFProtection.get_csrf_token()),
      "\">",
      "<title>",
      escape(title),
      " - Fornacast</title>",
      preload_tags(),
      "<link rel=\"stylesheet\" href=\"",
      escape(css_path),
      "\">",
      "<script type=\"module\" src=\"",
      escape(js_path),
      "\"></script>",
      "</head><body class=\"app-body bg-surface text-on-surface\">",
      repository_shell(current_user, repository_safe_iodata(safe_body)),
      "</body></html>"
    ]

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(conn.status || 200, html)
  end

  def escape(value) do
    value
    |> to_string()
    |> html_escape()
    |> safe_to_string()
  end

  def csrf_input do
    ~s(<input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}">)
  end

  defp app_shell(current_user, title, body) do
    if current_user do
      """
      <div class="app-shell">
        <header class="appbar appbar-primary appbar-sticky">
          <div class="appbar-left">
            <a class="brand-mark" href="/" aria-label="Fornacast dashboard">Fornacast</a>
            <nav class="appbar-nav" aria-label="Workspace">
              <a class="nav-link" href="/issues">Issues</a>
              <a class="nav-link" href="/pulls">Pull Requests</a>
              #{repository_menu(current_user)}
            </nav>
          </div>
          <div class="appbar-actions">
            #{create_menu()}
            #{account_menu(current_user)}
            #{theme_menu()}
          </div>
        </header>
        <main class="app-main">
          <div class="page-heading">
            <p class="eyebrow">Repository workbench</p>
            <h1>#{title}</h1>
          </div>
          <section class="content-panel">#{body}</section>
        </main>
      </div>
      """
    else
      """
      <div class="auth-shell">
        <header class="appbar auth-appbar">
          <a class="brand-mark" href="/" aria-label="Fornacast home">Fornacast</a>
          <nav class="app-nav" aria-label="Primary">
            <a class="nav-link" href="/login">Login</a>
            #{theme_menu()}
          </nav>
        </header>
        <main class="auth-main">
          <section class="content-panel auth-panel">
            <div class="page-heading">
              <p class="eyebrow">Self-hosted forge</p>
              <h1>#{title}</h1>
            </div>
            #{body}
          </section>
        </main>
      </div>
      """
    end
  end

  defp repository_shell(current_user, safe_body) do
    if current_user do
      [
        "<div class=\"app-shell repository-shell\" data-repository-shell=\"authenticated\">",
        "<header class=\"appbar appbar-primary appbar-sticky\">",
        "<div class=\"appbar-left\">",
        "<a class=\"brand-mark\" href=\"/\" aria-label=\"Fornacast dashboard\">Fornacast</a>",
        "<nav class=\"appbar-nav\" aria-label=\"Workspace\">",
        "<a class=\"nav-link\" href=\"/issues\">Issues</a>",
        "<a class=\"nav-link\" href=\"/pulls\">Pull Requests</a>",
        repository_menu(current_user),
        "</nav></div>",
        "<div class=\"appbar-actions\">",
        create_menu(),
        account_menu(current_user),
        theme_menu(),
        "</div></header>",
        "<main class=\"repository-main\" data-repository-main>",
        safe_body,
        "</main></div>"
      ]
    else
      [
        "<div class=\"repository-shell\" data-repository-shell=\"anonymous\">",
        "<header class=\"appbar appbar-primary appbar-sticky\">",
        "<a class=\"brand-mark\" href=\"/\" aria-label=\"Fornacast home\">Fornacast</a>",
        "<nav class=\"app-nav\" aria-label=\"Repository actions\">",
        "<a class=\"nav-link\" href=\"/login\">Login</a>",
        theme_menu(),
        "</nav></header>",
        "<main class=\"repository-main\" data-repository-main>",
        safe_body,
        "</main></div>"
      ]
    end
  end

  defp repository_safe_iodata({:safe, data}), do: repository_safe_iodata(data)

  defp repository_safe_iodata([]), do: []

  defp repository_safe_iodata([head | tail]),
    do: [repository_safe_iodata(head) | repository_safe_iodata(tail)]

  defp repository_safe_iodata(item) when is_binary(item), do: item
  defp repository_safe_iodata(item) when is_integer(item), do: <<item>>

  defp create_menu do
    """
    <details class="appbar-create-menu">
      <summary class="create-menu-trigger" aria-label="Create new" title="Create new">
        <span class="create-menu-plus" aria-hidden="true"></span>
        <span class="create-menu-caret" aria-hidden="true"></span>
      </summary>
      <div class="create-menu" role="menu">
        <a class="create-menu-item" href="/repos/new">
          <span class="create-menu-icon create-menu-icon-repo" aria-hidden="true"></span>
          <span>New repository</span>
        </a>
        <a class="create-menu-item" href="/repos/import">
          <span class="create-menu-icon create-menu-icon-import" aria-hidden="true"></span>
          <span>Import repository</span>
        </a>
        <a class="create-menu-item" href="/organizations/new">
          <span class="create-menu-icon create-menu-icon-org" aria-hidden="true"></span>
          <span>New organization</span>
        </a>
      </div>
    </details>
    """
  end

  defp repository_menu(current_user) do
    items =
      current_user
      |> ForgeAccounts.list_repository_owners()
      |> Enum.map(&repository_owner_menu_item/1)
      |> Enum.join("\n")

    """
    <details class="repo-menu">
      <summary class="repo-menu-trigger" aria-label="User repositories" title="User repositories">
        <span>User Repos</span>
        <span class="appbar-menu-caret" aria-hidden="true"></span>
      </summary>
      <div class="repo-menu-list" role="menu">
        #{items}
      </div>
    </details>
    """
  end

  defp repository_owner_menu_item(owner) do
    ~s(<a class="repo-menu-item" href="/#{escape(owner.username)}">#{escape(owner_label(owner))}</a>)
  end

  defp theme_menu do
    """
    <details class="theme-menu">
      <summary class="theme-menu-trigger" aria-label="Theme" title="Theme">
        <span data-theme-label>Theme</span>
        <span class="appbar-menu-caret" aria-hidden="true"></span>
      </summary>
      <div class="theme-menu-list" role="menu">
        <button type="button" class="theme-menu-item" data-theme-choice="auto" role="menuitemradio" aria-checked="false">Auto</button>
        <button type="button" class="theme-menu-item" data-theme-choice="sunshine" role="menuitemradio" aria-checked="false">Sunshine</button>
        <button type="button" class="theme-menu-item" data-theme-choice="moonlight" role="menuitemradio" aria-checked="false">Moonlight</button>
      </div>
    </details>
    """
  end

  defp account_menu(current_user) do
    """
    <details class="account-menu">
      <summary class="account-menu-trigger" aria-label="Account menu" title="Account menu">
        <span>@#{escape(account_label(current_user))}</span>
        <span class="appbar-menu-caret" aria-hidden="true"></span>
      </summary>
      <div class="account-menu-list" role="menu">
        <a class="account-menu-item" href="#{escape(account_profile_path(current_user))}">Profile</a>
        <a class="account-menu-item" href="/settings/ssh-keys">Settings</a>
        <form action="/logout" method="post" class="account-menu-logout">
          #{csrf_input()}
          <input type="hidden" name="_method" value="delete">
          <button type="submit" class="account-menu-item account-menu-button">Logout</button>
        </form>
      </div>
    </details>
    """
  end

  defp account_label(current_user) do
    current_user.display_name || current_user.username || current_user.email || "account"
  end

  defp owner_label(%{kind: :organization, display_name: display_name, username: username}) do
    display_name || username
  end

  defp owner_label(%{username: username}), do: username

  defp account_profile_path(%{username: username}) when is_binary(username) and username != "" do
    "/" <> username
  end

  defp account_profile_path(_current_user), do: "/"

  defp preload_tags do
    manifest_path =
      :fornacast_web
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("static/assets/js/manifest.json")

    if File.exists?(manifest_path) do
      DuskmoonBundler.Preload.tags(FornacastWeb.Endpoint, "/assets/js/app.js",
        profile: :fornacast_web
      )
    else
      ""
    end
  rescue
    _error -> ""
  end

  def section_header(title, subtitle, action_html \\ "") do
    """
    <section class="section-header">
      <div>
        <p class="eyebrow">Fornacast</p>
        <h2>#{escape(title)}</h2>
        <p class="muted">#{escape(subtitle)}</p>
      </div>
      <div class="section-actions">#{action_html}</div>
    </section>
    """
  end

  def primary_link(href, label),
    do: ~s(<a class="btn btn-primary" href="#{escape(href)}">#{escape(label)}</a>)

  def ghost_link(href, label),
    do: ~s(<a class="btn btn-ghost" href="#{escape(href)}">#{escape(label)}</a>)

  def badge(label, tone \\ nil) do
    variant =
      case to_string(tone) do
        "public" -> "success"
        "private" -> "secondary"
        tone when tone in ~w(primary secondary tertiary info success warning error) -> tone
        _tone -> nil
      end

    classes = if variant, do: "badge badge-#{variant}", else: "badge"
    ~s(<span class="#{classes}">#{escape(label)}</span>)
  end

  def form_panel(title, description, form_html) do
    """
    <section class="form-panel">
      <div class="panel-heading">
        <h2>#{escape(title)}</h2>
        <p class="muted">#{escape(description)}</p>
      </div>
      #{form_html}
    </section>
    """
  end

  def empty_state(title, description, action_html \\ "") do
    """
    <section class="empty-state">
      <h2>#{escape(title)}</h2>
      <p class="muted">#{escape(description)}</p>
      #{action_html}
    </section>
    """
  end

  def error_panel(message),
    do: ~s(<section class="error-panel" role="alert">#{escape(message)}</section>)

  def command_block(commands),
    do: ~s(<pre class="command-block"><code>#{escape(commands)}</code></pre>)

  def code_block(content), do: ~s(<pre class="code-block"><code>#{escape(content)}</code></pre>)
end
