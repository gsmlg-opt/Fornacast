defmodule FornacastWeb.HTML do
  @moduledoc false

  import Phoenix.HTML
  import Plug.Conn

  def page(conn, title, body) do
    current_user = conn.assigns[:current_user]
    css_path = FornacastWeb.Endpoint.static_path("/assets/app.css")
    js_path = FornacastWeb.Endpoint.static_path("/assets/app.js")

    content =
      if current_user,
        do: app_shell(conn, current_user, title, body),
        else: auth_shell(title, body)

    html =
      """
      <!doctype html>
      <html lang="en" data-theme="sunshine">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="csrf-token" content="#{Plug.CSRFProtection.get_csrf_token()}">
        <title>#{escape(title)} - Fornacast</title>
        <link rel="stylesheet" href="#{escape(css_path)}">
        <script defer type="text/javascript" src="#{escape(js_path)}"></script>
      </head>
      <body class="app-body bg-surface text-on-surface">
        #{content}
      </body>
      </html>
      """

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

  defp auth_shell(title, body) do
    """
    <div class="auth-shell">
      <header class="auth-brand">
        <a class="brand-mark" href="/">Fornacast</a>
        <button class="theme-toggle" type="button" data-theme-toggle aria-label="Toggle theme">Theme</button>
      </header>
      <main class="auth-main" aria-labelledby="page-title">
        <p class="eyebrow">Self-hosted Git forge</p>
        <h1 id="page-title">#{escape(title)}</h1>
        #{body}
      </main>
    </div>
    """
  end

  defp app_shell(conn, current_user, title, body) do
    active = active_section(conn.request_path)

    """
    <div class="app-shell">
      #{appbar(current_user)}
      <div class="app-frame">
        #{rail(active, current_user)}
        <main class="app-main" aria-labelledby="page-title">
          <h1 id="page-title" class="sr-only">#{escape(title)}</h1>
          #{body}
        </main>
      </div>
    </div>
    """
  end

  defp appbar(current_user) do
    """
    <header class="appbar appbar-primary appbar-sticky">
      <a class="brand-mark" href="/">Fornacast</a>
      <div class="appbar-actions">
        <span class="user-chip">#{escape(current_user.username)}</span>
        <button class="theme-toggle" type="button" data-theme-toggle aria-label="Toggle theme">Theme</button>
        <form action="/logout" method="post" class="inline">
          #{csrf_input()}
          <input type="hidden" name="_method" value="delete">
          <button class="btn btn-ghost" type="submit">Logout</button>
        </form>
      </div>
    </header>
    """
  end

  defp rail(active, _current_user) do
    """
    <aside class="app-rail" aria-label="Main navigation">
      <nav class="rail-nav">
        #{rail_link("/", "Dashboard", active == :dashboard)}
        #{rail_link("/repos/new", "New repository", active == :new_repository)}
        #{rail_link("/ssh-keys", "SSH keys", active == :ssh_keys)}
      </nav>
      <div class="rail-status">
        <strong>Local instance</strong>
        <span>Git over SSH and smart HTTP</span>
      </div>
    </aside>
    """
  end

  defp rail_link(href, label, active?) do
    active_class = if active?, do: " is-active", else: ""
    ~s(<a class="rail-link#{active_class}" href="#{href}">#{escape(label)}</a>)
  end

  defp active_section("/"), do: :dashboard
  defp active_section("/repos/new"), do: :new_repository
  defp active_section("/ssh-keys"), do: :ssh_keys
  defp active_section(_path), do: :repository

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

  def badge(label, tone \\ "neutral"),
    do: ~s(<span class="badge badge-#{escape(tone)}">#{escape(label)}</span>)

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
