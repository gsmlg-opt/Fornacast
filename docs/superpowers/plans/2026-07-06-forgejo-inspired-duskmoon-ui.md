# Forgejo-Inspired DuskMoon UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the full current Fornacast web UI into a compact Forgejo-inspired DuskMoon workbench without changing routes, auth behavior, repository behavior, or first-release scope.

**Architecture:** Keep the existing Phoenix controller-rendered HTML flow, but move repeated shell and view primitives into `FornacastWeb.HTML`. Controllers keep owning page-specific data and body composition. CSS becomes token-driven DuskMoon-compatible styling, with one small JS theme toggle hook for the app shell.

**Tech Stack:** Phoenix controllers, ExUnit/Phoenix.ConnTest, DuskMoon/Tailwind v4 CSS tokens, Bun asset build, Chrome DevTools visual verification.

---

## File Structure

- Modify `apps/fornacast_web/lib/fornacast_web/html.ex`: shared page shell, appbar, authenticated rail, buttons, badges, panels, tables, repo tabs, command/code blocks, form/error helpers.
- Modify `apps/fornacast_web/assets/css/app.css`: remove hardcoded colors, define DuskMoon token-based Workbench Forge styling, responsive shell, tables, forms, code, repo tabs, hover/focus states, and reduced-motion behavior.
- Modify `apps/fornacast_web/assets/js/app.js`: keep DuskMoon element registration and add a small `data-theme-toggle` handler.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/session_controller.ex`: login page utility layout and invalid-login error state.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex`: setup page utility layout and validation error state.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/dashboard_controller.ex`: Forgejo-style repository list, empty state, and primary action.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex`: settings-style add-key panel and dense key table.
- Modify `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`: repository header, tabs, empty repo quickstart, source/file views, refs tables, commit detail, README surface.
- Modify `apps/fornacast_web/test/fornacast_web_test.exs`: add UI contract tests for the shell and refreshed pages while preserving existing behavior checks.
- Modify `apps/fornacast_web/test/setup_wizard_test.exs`: add setup/login utility-page contract checks.

## Task 1: Add UI Contract Tests

**Files:**
- Modify: `apps/fornacast_web/test/fornacast_web_test.exs`
- Modify: `apps/fornacast_web/test/setup_wizard_test.exs`

- [ ] **Step 1: Add shell and utility assertions to `FornacastWebTest`**

Insert this test after `test "HTML escaping protects repository content in inline pages"`:

```elixir
test "authenticated pages render the DuskMoon workbench shell" do
  reset_database!()

  assert {:ok, user} =
           ForgeAccounts.create_user(%{
             username: "alice",
             email: "alice-shell@example.com",
             password: "correct horse battery staple"
           })

  conn =
    build_conn()
    |> Plug.Test.init_test_session(user_id: user.id)
    |> get("/")

  body = html_response(conn, 200)

  assert body =~ ~s(<body class="app-body bg-surface text-on-surface")
  assert body =~ ~s(class="appbar appbar-primary appbar-sticky")
  assert body =~ ~s(class="app-rail bg-secondary text-secondary-content")
  assert body =~ "Dashboard"
  assert body =~ "New repository"
  assert body =~ "SSH keys"
  assert body =~ ~s(data-theme-toggle)
end
```

- [ ] **Step 2: Add page contract assertions to the existing browser-flow test**

In `test "login, SSH key, repository creation, empty state, and private access policy"`, add these assertions after `assert html_response(login_form, 200) =~ "Login"`:

```elixir
assert html_response(login_form, 200) =~ ~s(class="auth-shell")
assert html_response(login_form, 200) =~ ~s(class="form-panel")
```

Add these assertions after `assert html_response(empty, 200) =~ "ssh://alice@"`:

```elixir
assert html_response(empty, 200) =~ ~s(class="repo-header")
assert html_response(empty, 200) =~ ~s(class="repo-tabs")
assert html_response(empty, 200) =~ "Quick setup"
assert html_response(empty, 200) =~ ~s(class="command-block")
```

- [ ] **Step 3: Add repository browser contract assertions**

In `test "repository browser renders README, source, raw file, and commit metadata"`, replace:

```elixir
assert html_response(overview, 200) =~ "<h1>Demo</h1>"
```

with:

```elixir
assert html_response(overview, 200) =~ ~s(class="repo-header")
assert html_response(overview, 200) =~ "alice / demo"
assert html_response(overview, 200) =~ ~s(class="repo-tabs")
assert html_response(overview, 200) =~ ~s(class="readme-panel")
```

After `assert html_response(source, 200) =~ "guide.txt"`, add:

```elixir
assert html_response(source, 200) =~ ~s(class="path-bar")
assert html_response(source, 200) =~ ~s(class="data-table source-table")
```

After `assert html_response(file, 200) =~ "hello"`, add:

```elixir
assert html_response(file, 200) =~ ~s(class="file-panel")
assert html_response(file, 200) =~ ~s(class="code-block")
```

- [ ] **Step 4: Add setup wizard page contract assertions**

In `apps/fornacast_web/test/setup_wizard_test.exs`, inside `test "GET /setup renders the admin form"`, add:

```elixir
assert body =~ ~s(class="auth-shell")
assert body =~ ~s(class="form-panel")
assert body =~ "First administrator"
```

- [ ] **Step 5: Run focused tests and verify expected failures**

Run:

```bash
mix test apps/fornacast_web/test
```

Expected: tests fail because the new shell, panel, tabs, and table classes do not exist yet. The existing behavior assertions should continue to compile.

- [ ] **Step 6: Commit tests**

Run:

```bash
git add apps/fornacast_web/test/fornacast_web_test.exs apps/fornacast_web/test/setup_wizard_test.exs
git commit -m "test(ui): describe Forgejo-inspired web shell"
```

## Task 2: Build Shared HTML Primitives

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/html.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Replace the page shell and add shared helpers**

In `apps/fornacast_web/lib/fornacast_web/html.ex`, replace `page/3` and add the helpers below `csrf_input/0`. Keep `escape/1` unchanged.

```elixir
def page(conn, title, body) do
  current_user = conn.assigns[:current_user]
  css_path = FornacastWeb.Endpoint.static_path("/assets/app.css")
  js_path = FornacastWeb.Endpoint.static_path("/assets/app.js")
  active = active_section(conn.request_path)

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
      #{app_shell(current_user, title, active, body)}
    </body>
    </html>
    """

  conn
  |> put_resp_content_type("text/html")
  |> send_resp(conn.status || 200, html)
end

def section_header(title, subtitle, action_html \\ "") do
  """
  <div class="section-header">
    <div>
      <p class="eyebrow">Fornacast</p>
      <h2>#{escape(title)}</h2>
      <p class="muted">#{escape(subtitle)}</p>
    </div>
    <div class="section-actions">#{action_html}</div>
  </div>
  """
end

def primary_link(label, href) do
  ~s(<a class="btn btn-primary" href="#{escape(href)}">#{escape(label)}</a>)
end

def ghost_link(label, href) do
  ~s(<a class="btn btn-ghost" href="#{escape(href)}">#{escape(label)}</a>)
end

def badge(label, variant \\ "primary") do
  ~s(<span class="badge badge-#{escape(variant)}">#{escape(label)}</span>)
end

def form_panel(title, subtitle, form_html) do
  """
  <section class="form-panel">
    <div class="panel-heading">
      <h3>#{escape(title)}</h3>
      <p class="muted">#{escape(subtitle)}</p>
    </div>
    #{form_html}
  </section>
  """
end

def empty_state(title, message, action_html \\ "") do
  """
  <section class="empty-state">
    <h3>#{escape(title)}</h3>
    <p class="muted">#{escape(message)}</p>
    <div class="empty-actions">#{action_html}</div>
  </section>
  """
end

def error_panel(message) do
  ~s(<section class="error-panel"><p>#{escape(message)}</p></section>)
end

def command_block(command) do
  ~s(<pre class="command-block"><code>#{escape(command)}</code></pre>)
end

def code_block(content) do
  ~s(<pre class="code-block"><code>#{escape(content)}</code></pre>)
end
```

Add private helpers at the bottom of the module:

```elixir
defp app_shell(nil, title, _active, body) do
  """
  <div class="auth-shell">
    #{appbar(title, nil)}
    <main class="auth-main">
      #{body}
    </main>
  </div>
  """
end

defp app_shell(current_user, title, active, body) do
  """
  <div class="app-shell">
    #{appbar(title, current_user)}
    <div class="app-frame">
      #{rail(active)}
      <main class="app-main">
        #{body}
      </main>
    </div>
  </div>
  """
end

defp appbar(title, current_user) do
  account =
    case current_user do
      nil ->
        ~s(<a class="appbar-link" href="/login">Login</a>)

      user ->
        """
        <span class="appbar-user">#{escape(user.username)}</span>
        <form action="/logout" method="post" class="inline">
          #{csrf_input()}
          <input type="hidden" name="_method" value="delete">
          <button class="btn btn-ghost btn-compact" type="submit">Logout</button>
        </form>
        """
    end

  """
  <header class="appbar appbar-primary appbar-sticky">
    <a class="brand-mark" href="/">
      <span class="brand-glyph">F</span>
      <span class="brand-copy"><strong>Fornacast</strong><small>Self-hosted forge</small></span>
    </a>
    <div class="appbar-context">#{escape(title)}</div>
    <nav class="appbar-actions" aria-label="Account">
      <button class="theme-toggle" type="button" data-theme-toggle>Theme</button>
      #{account}
    </nav>
  </header>
  """
end

defp rail(active) do
  """
  <aside class="app-rail bg-secondary text-secondary-content">
    <nav class="rail-nav" aria-label="Main navigation">
      #{rail_link("Dashboard", "/", active == :dashboard)}
      #{rail_link("New repository", "/repos/new", active == :new_repo)}
      #{rail_link("SSH keys", "/ssh-keys", active == :ssh_keys)}
    </nav>
    <div class="rail-status">
      <span class="status-dot"></span>
      <div>
        <strong>Local forge</strong>
        <small>Git SSH + web browser</small>
      </div>
    </div>
  </aside>
  """
end

defp rail_link(label, href, active?) do
  class = if active?, do: "rail-link is-active", else: "rail-link"
  ~s(<a class="#{class}" href="#{escape(href)}">#{escape(label)}</a>)
end

defp active_section("/"), do: :dashboard
defp active_section("/repos/new"), do: :new_repo
defp active_section("/ssh-keys"), do: :ssh_keys
defp active_section(_path), do: :repository
```

- [ ] **Step 2: Run focused tests and verify shell test passes**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs
```

Expected: shell assertions pass. Page-specific assertions for repo tabs, tables, form panels, and file panels still fail until controller tasks are complete.

- [ ] **Step 3: Commit shared helpers**

Run:

```bash
git add apps/fornacast_web/lib/fornacast_web/html.ex
git commit -m "feat(ui): add DuskMoon workbench shell helpers"
```

## Task 3: Replace Hardcoded CSS With DuskMoon Token Styling

**Files:**
- Modify: `apps/fornacast_web/assets/css/app.css`
- Modify: `apps/fornacast_web/assets/js/app.js`

- [ ] **Step 1: Replace `app.css` with token-based Workbench Forge CSS**

Use this structure and keep every color token-based:

```css
@import "tailwindcss";
@plugin "@duskmoon-dev/core/plugin";
@import "@duskmoon-dev/core/themes/sunshine";
@import "@duskmoon-dev/core/themes/moonlight";
@import "@duskmoon-dev/core/components";
@import "@duskmoon-dev/css-art";

@layer base {
  :root {
    --font-display: "Alegreya", "Iowan Old Style", "Palatino Linotype", serif;
    --font-body: "IBM Plex Sans", "Aptos", "Segoe UI", sans-serif;
    --font-mono: "JetBrains Mono", "Fira Code", "SFMono-Regular", monospace;
  }

  * {
    box-sizing: border-box;
  }

  body {
    @apply bg-surface text-on-surface;
    font-family: var(--font-body);
    line-height: 1.5;
    margin: 0;
  }

  h1,
  h2,
  h3 {
    font-family: var(--font-display);
    letter-spacing: 0;
  }

  a {
    @apply text-primary;
    text-decoration: none;
  }

  a:hover {
    text-decoration: underline;
  }

  input,
  textarea,
  select {
    @apply bg-surface-container-low text-on-surface border border-outline;
    border-radius: 0.375rem;
    display: block;
    font: inherit;
    margin-top: 0.35rem;
    padding: 0.65rem 0.75rem;
    width: 100%;
  }

  label {
    display: block;
    font-weight: 650;
    margin-bottom: 0.9rem;
  }

  code,
  pre {
    font-family: var(--font-mono);
  }

  table {
    border-collapse: collapse;
    width: 100%;
  }
}

@layer components {
  .appbar {
    @apply bg-primary text-primary-content border-b border-outline-variant;
    align-items: center;
    display: grid;
    gap: 1rem;
    grid-template-columns: auto 1fr auto;
    min-height: 4rem;
    padding: 0.6rem 1rem;
    z-index: 10;
  }

  .appbar-sticky {
    position: sticky;
    top: 0;
  }

  .brand-mark,
  .appbar-actions,
  .appbar-user,
  .rail-status,
  .section-header,
  .repo-meta,
  .path-bar {
    align-items: center;
    display: flex;
  }

  .brand-mark {
    color: currentcolor;
    gap: 0.65rem;
  }

  .brand-glyph {
    @apply bg-primary-container text-on-primary-container;
    border-radius: 0.35rem;
    display: grid;
    font-family: var(--font-display);
    font-size: 1.35rem;
    font-weight: 800;
    height: 2.25rem;
    place-items: center;
    width: 2.25rem;
  }

  .brand-copy {
    display: grid;
    line-height: 1.05;
  }

  .brand-copy small,
  .appbar-context,
  .muted,
  .eyebrow,
  .caption {
    @apply text-on-surface-variant;
  }

  .appbar-actions {
    gap: 0.5rem;
    justify-content: flex-end;
  }

  .app-frame {
    display: grid;
    grid-template-columns: minmax(12rem, 15rem) minmax(0, 1fr);
    min-height: calc(100vh - 4rem);
  }

  .app-rail {
    border-right: 1px solid var(--color-outline-variant);
    display: flex;
    flex-direction: column;
    gap: 1rem;
    padding: 1rem;
  }

  .rail-nav {
    display: grid;
    gap: 0.35rem;
  }

  .rail-link {
    color: currentcolor;
    border-radius: 0.375rem;
    padding: 0.65rem 0.75rem;
  }

  .rail-link.is-active {
    @apply bg-primary-container text-on-primary-container;
    font-weight: 750;
  }

  .rail-status {
    border-top: 1px solid var(--color-outline-variant);
    gap: 0.6rem;
    margin-top: auto;
    padding-top: 1rem;
  }

  .status-dot {
    @apply bg-primary;
    border-radius: 999px;
    height: 0.65rem;
    width: 0.65rem;
  }

  .app-main,
  .auth-main {
    margin: 0 auto;
    max-width: 76rem;
    padding: 1.5rem;
    width: 100%;
  }

  .auth-shell {
    min-height: 100vh;
  }

  .auth-main {
    max-width: 38rem;
    padding-top: 3rem;
  }

  .section-header {
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 1rem;
  }

  .section-header h2,
  .repo-title h2 {
    font-size: 1.875rem;
    line-height: 1.15;
    margin: 0;
  }

  .eyebrow {
    font-size: 0.75rem;
    font-weight: 750;
    letter-spacing: 0.08em;
    margin: 0 0 0.2rem;
    text-transform: uppercase;
  }

  .btn,
  button {
    border: 0;
    border-radius: 0.375rem;
    cursor: pointer;
    display: inline-flex;
    font: inherit;
    font-weight: 750;
    justify-content: center;
    padding: 0.6rem 0.85rem;
  }

  .btn-primary {
    @apply bg-primary text-primary-content;
  }

  .btn-ghost {
    background: transparent;
    color: currentcolor;
  }

  .btn-outline {
    @apply border border-outline text-on-surface;
    background: transparent;
  }

  .btn-danger {
    @apply bg-error text-error-content;
  }

  .btn-compact {
    padding: 0.35rem 0.55rem;
  }

  .theme-toggle {
    @apply bg-primary-container text-on-primary-container;
  }

  .form-panel,
  .content-panel,
  .readme-panel,
  .file-panel,
  .empty-state,
  .error-panel,
  .repo-header {
    @apply bg-surface-container text-on-surface border border-outline-variant;
    border-radius: 0.5rem;
    padding: 1rem;
  }

  .panel-heading {
    margin-bottom: 1rem;
  }

  .panel-heading h3 {
    font-size: 1.25rem;
    margin: 0;
  }

  .data-table th,
  .data-table td {
    border-bottom: 1px solid var(--color-outline-variant);
    padding: 0.65rem 0.75rem;
    text-align: left;
    vertical-align: top;
  }

  .data-table th {
    @apply text-on-surface-variant;
    font-size: 0.78rem;
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .data-table tbody tr:hover {
    @apply bg-surface-container-high;
  }

  .repo-header {
    margin-bottom: 0.75rem;
  }

  .repo-title {
    display: grid;
    gap: 0.25rem;
  }

  .repo-meta {
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 0.75rem;
  }

  .repo-tabs {
    @apply bg-surface-container-high border border-outline-variant;
    border-radius: 0.5rem;
    display: flex;
    gap: 0.25rem;
    margin-bottom: 1rem;
    padding: 0.35rem;
  }

  .repo-tab {
    border-radius: 0.35rem;
    padding: 0.55rem 0.75rem;
  }

  .repo-tab.is-active {
    @apply bg-primary text-primary-content;
  }

  .badge {
    border-radius: 999px;
    display: inline-flex;
    font-size: 0.76rem;
    font-weight: 750;
    padding: 0.2rem 0.55rem;
  }

  .badge-primary {
    @apply bg-primary-container text-on-primary-container;
  }

  .badge-secondary {
    @apply bg-secondary text-secondary-content;
  }

  .badge-tertiary {
    @apply bg-tertiary text-tertiary-content;
  }

  .command-block,
  .code-block {
    @apply bg-inverse-surface text-inverse-on-surface;
    border-radius: 0.5rem;
    overflow-x: auto;
    padding: 0.9rem;
  }

  .path-bar {
    @apply bg-surface-container-high text-on-surface border border-outline-variant;
    border-radius: 0.5rem;
    gap: 0.5rem;
    margin-bottom: 0.75rem;
    overflow-x: auto;
    padding: 0.65rem 0.75rem;
  }

  .error-panel {
    @apply bg-error-container text-on-error-container border-error;
  }

  form.inline {
    display: inline;
  }
}

@layer utilities {
  .interactive-card {
    transition: transform 0.15s ease, box-shadow 0.15s ease;
  }

  .interactive-card:hover {
    transform: translateY(-2px);
  }

  @media (max-width: 760px) {
    .app-frame {
      display: block;
    }

    .app-rail {
      border-right: 0;
      border-bottom: 1px solid var(--color-outline-variant);
    }

    .rail-nav {
      grid-template-columns: repeat(3, minmax(0, 1fr));
    }

    .section-header {
      align-items: flex-start;
      flex-direction: column;
    }

    .appbar {
      grid-template-columns: 1fr;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    * {
      animation: none !important;
      transition: none !important;
    }
  }
}
```

- [ ] **Step 2: Add the theme toggle handler**

Append this to `apps/fornacast_web/assets/js/app.js` after the DuskMoon registrations:

```javascript
document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-theme-toggle]");
  if (!button) return;

  const root = document.documentElement;
  const nextTheme = root.dataset.theme === "moonlight" ? "sunshine" : "moonlight";
  root.dataset.theme = nextTheme;
  window.localStorage.setItem("fornacast-theme", nextTheme);
});

const savedTheme = window.localStorage.getItem("fornacast-theme");
if (savedTheme === "moonlight" || savedTheme === "sunshine") {
  document.documentElement.dataset.theme = savedTheme;
}
```

- [ ] **Step 3: Verify assets compile**

Run:

```bash
MIX_ENV=prod FORNACAST_DATABASE_ADAPTER=turso mix assets.deploy
```

Expected: Tailwind and Bun complete, and `apps/fornacast_web/priv/static/cache_manifest.json` is regenerated.

- [ ] **Step 4: Commit CSS and JS**

Run:

```bash
git add apps/fornacast_web/assets/css/app.css apps/fornacast_web/assets/js/app.js
git commit -m "feat(ui): style DuskMoon workbench surfaces"
```

## Task 4: Refresh Login And Setup Utility Pages

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/session_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex`
- Test: `apps/fornacast_web/test/setup_wizard_test.exs`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Update `SessionController.new/2`**

Replace the current body with:

```elixir
page(conn, "Login", """
#{form_panel(
  "Sign in",
  "Access your repositories, SSH keys, and source browser.",
  """
  <form action="/login" method="post">
    #{csrf_input()}
    <label>Username <input name="session[username]" autocomplete="username"></label>
    <label>Password <input name="session[password]" type="password" autocomplete="current-password"></label>
    <button class="btn btn-primary" type="submit">Login</button>
  </form>
  """
)}
""")
```

- [ ] **Step 2: Update invalid login rendering**

Replace the invalid-credentials branch body with:

```elixir
conn
|> put_status(:unauthorized)
|> page(
  "Login",
  error_panel("Invalid username or password.") <>
    form_panel(
      "Sign in",
      "Access your repositories, SSH keys, and source browser.",
      """
      <form action="/login" method="post">
        #{csrf_input()}
        <label>Username <input name="session[username]" autocomplete="username"></label>
        <label>Password <input name="session[password]" type="password" autocomplete="current-password"></label>
        <button class="btn btn-primary" type="submit">Login</button>
      </form>
      """
    )
)
```

- [ ] **Step 3: Update `SetupController.form_body/0`**

Replace `form_body/0` with:

```elixir
defp form_body do
  form_panel(
    "First administrator",
    "Create the first administrator account to finish setting up this Fornacast instance.",
    """
    <form action="/setup" method="post">
      #{csrf_input()}
      <label>Username <input name="admin[username]" autocomplete="username"></label>
      <label>Email <input name="admin[email]" type="email" autocomplete="email"></label>
      <label>Password <input name="admin[password]" type="password" autocomplete="new-password"></label>
      <button class="btn btn-primary" type="submit">Create admin</button>
    </form>
    """
  )
end
```

- [ ] **Step 4: Update setup error rendering**

Replace `error_body/1` with:

```elixir
defp error_body(changeset) do
  error_panel("Could not create administrator: #{inspect(changeset.errors)}") <> form_body()
end
```

- [ ] **Step 5: Run utility page tests**

Run:

```bash
mix test apps/fornacast_web/test/setup_wizard_test.exs apps/fornacast_web/test/fornacast_web_test.exs
```

Expected: login/setup contract assertions pass. Dashboard and repository-specific assertions still fail until later tasks are complete.

- [ ] **Step 6: Commit utility pages**

Run:

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/session_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/setup_controller.ex apps/fornacast_web/test/setup_wizard_test.exs apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(ui): refresh login and setup pages"
```

## Task 5: Refresh Dashboard, Repository Form, And SSH Keys

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/dashboard_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Update dashboard body composition**

Replace `DashboardController.index/2` body construction with:

```elixir
rows =
  repos
  |> Enum.map(fn repo ->
    """
    <tr>
      <td><a href="/#{escape(user.username)}/#{escape(repo.slug)}"><strong>#{escape(repo.name)}</strong></a></td>
      <td>#{badge(repo.visibility, if(repo.visibility == :public, do: "tertiary", else: "primary"))}</td>
      <td><code>#{escape(repo.default_branch)}</code></td>
    </tr>
    """
  end)
  |> Enum.join("\n")

content =
  if repos == [] do
    empty_state(
      "No repositories yet",
      "Create your first Fornacast repository and push over SSH.",
      primary_link("New repository", "/repos/new")
    )
  else
    """
    <section class="content-panel">
      <table class="data-table repo-table">
        <thead><tr><th>Repository</th><th>Visibility</th><th>Default branch</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </section>
    """
  end

body =
  section_header(
    "Dashboard",
    "#{length(repos)} repositories owned by #{user.username}",
    primary_link("New repository", "/repos/new")
  ) <> content

page(conn, "Dashboard", body)
```

- [ ] **Step 2: Update `RepositoryController.new/2`**

Replace the body with:

```elixir
page(conn, "New repository", """
#{section_header("New repository", "Create a private or public repository for Git over SSH.")}
#{form_panel(
  "Repository details",
  "Names are normalized into URL-safe repository slugs.",
  """
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
    <button class="btn btn-primary" type="submit">Create repository</button>
  </form>
  """
)}
""")
```

- [ ] **Step 3: Update repository create errors**

Replace both create error branches with `error_panel/1` plus the same form panel from Step 2. Use this exact error branch for changesets:

```elixir
{:error, %Ecto.Changeset{} = changeset} ->
  conn
  |> put_status(:unprocessable_entity)
  |> page("New repository", error_panel("Could not create repository: #{inspect(changeset.errors)}"))
```

Use this exact branch for string reasons:

```elixir
{:error, reason} ->
  conn
  |> put_status(:unprocessable_entity)
  |> page("New repository", error_panel(reason))
```

- [ ] **Step 4: Update SSH keys page**

Replace `SSHKeyController.index/2` body construction with:

```elixir
rows =
  keys
  |> Enum.map(fn key ->
    """
    <tr>
      <td><strong>#{escape(key.title)}</strong></td>
      <td><code>#{escape(key.fingerprint_sha256)}</code></td>
      <td>
        <form action="/ssh-keys/#{key.id}" method="post">
          #{csrf_input()}
          <input type="hidden" name="_method" value="delete">
          <button class="btn btn-danger btn-compact" type="submit">Delete</button>
        </form>
      </td>
    </tr>
    """
  end)
  |> Enum.join("\n")

keys_table =
  if keys == [] do
    empty_state("No SSH keys", "Add a public key before pushing over SSH.")
  else
    """
    <section class="content-panel">
      <table class="data-table key-table">
        <thead><tr><th>Title</th><th>Fingerprint</th><th></th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </section>
    """
  end

page(conn, "SSH keys", """
#{section_header("SSH keys", "Manage public keys used for Git-over-SSH authentication.")}
#{form_panel(
  "Add public key",
  "Paste an OpenSSH public key from a trusted workstation.",
  """
  <form action="/ssh-keys" method="post">
    #{csrf_input()}
    <label>Title <input name="ssh_key[title]"></label>
    <label>Public key <textarea name="ssh_key[public_key]" rows="5"></textarea></label>
    <button class="btn btn-primary" type="submit">Add key</button>
  </form>
  """
)}
#{keys_table}
""")
```

- [ ] **Step 5: Run focused flow tests**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs --trace
```

Expected: dashboard, repository creation, SSH key, and existing access-policy assertions pass. Repository browser assertions still fail until Task 6.

- [ ] **Step 6: Commit dashboard and settings pages**

Run:

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/dashboard_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex apps/fornacast_web/lib/fornacast_web/controllers/ssh_key_controller.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(ui): refresh dashboard and settings views"
```

## Task 6: Refresh Repository Pages

**Files:**
- Modify: `apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex`
- Test: `apps/fornacast_web/test/fornacast_web_test.exs`

- [ ] **Step 1: Add repository header and tab helpers**

Add these private helpers before `empty_repository_body/2`:

```elixir
defp repo_header(owner, repo) do
  """
  <section class="repo-header">
    <div class="repo-title">
      <p class="eyebrow">Repository</p>
      <h2>#{escape(owner.username)} / #{escape(repo.slug)}</h2>
      <p class="muted">#{escape(repo.description || "No description provided.")}</p>
    </div>
    <div class="repo-meta">
      #{badge(repo.visibility, if(repo.visibility == :public, do: "tertiary", else: "primary"))}
      #{badge("default: #{repo.default_branch}", "secondary")}
    </div>
  </section>
  """
end

defp repo_tabs(owner, repo, active) do
  base = "/#{escape(owner.username)}/#{escape(repo.slug)}"

  [
    {"Code", base, :code},
    {"Commits", "#{base}/commits/#{escape(repo.default_branch)}", :commits},
    {"Branches", "#{base}/branches", :branches},
    {"Tags", "#{base}/tags", :tags}
  ]
  |> Enum.map(fn {label, href, key} ->
    class = if active == key, do: "repo-tab is-active", else: "repo-tab"
    ~s(<a class="#{class}" href="#{href}">#{label}</a>)
  end)
  |> Enum.join("\n")
  |> then(fn tabs -> ~s(<nav class="repo-tabs" aria-label="Repository">#{tabs}</nav>) end)
end
```

- [ ] **Step 2: Wrap repository overview, branches, tags, commits, source, and file pages**

For `show/2`, change the successful body to:

```elixir
body =
  repo_header(owner, repo) <>
    repo_tabs(owner, repo, :code) <>
    case ForgeRepos.empty?(repo) do
      {:ok, true} -> empty_repository_body(owner, repo)
      {:ok, false} -> repository_overview_body(owner, repo)
      {:error, reason} -> error_panel(reason)
    end

page(conn, "#{owner.username}/#{repo.slug}", body)
```

For `branches/2`, wrap the table:

```elixir
page(
  conn,
  "Branches: #{owner.username}/#{repo.slug}",
  repo_header(owner, repo) <> repo_tabs(owner, repo, :branches) <> refs_table(refs, "Branch")
)
```

For `tags/2`, use `repo_tabs(owner, repo, :tags)`. For `commits/2`, use `repo_tabs(owner, repo, :commits)`. For `render_src_path/5`, include `repo_header(owner, repo) <> repo_tabs(owner, repo, :code)` before `tree_view/5` or `blob_view/5`.

- [ ] **Step 3: Update empty repository body**

Replace `empty_repository_body/2` with:

```elixir
defp empty_repository_body(owner, repo) do
  clone_url = ForgeRepos.ssh_clone_url(repo, owner)

  empty_state(
    "Quick setup",
    "This repository is empty. Add an existing project and push the default branch.",
    command_block("""
    git init
    git remote add origin #{clone_url}
    git branch -M #{repo.default_branch}
    git push -u origin #{repo.default_branch}
    """)
  )
end
```

- [ ] **Step 4: Update repository overview and README panel**

Replace `repository_overview_body/2` with:

```elixir
defp repository_overview_body(_owner, repo) do
  readme_preview(repo)
end
```

Replace `render_readme/2` with:

```elixir
defp render_readme(path, blob) do
  content = to_string(blob.data)

  body =
    if String.ends_with?(String.downcase(path), ".md") do
      MDEx.to_html!(content, sanitize: MDEx.Document.default_sanitize_options())
    else
      code_block(content)
    end

  """
  <section class="readme-panel">
    <div class="panel-heading">
      <h3>#{escape(path)}</h3>
    </div>
    #{body}
  </section>
  """
end
```

- [ ] **Step 5: Update refs, commits, tree, file, and commit-detail markup**

Change every repository table opening tag from `<table>` to a specific data-table class:

```elixir
~s(<table class="data-table refs-table">)
~s(<table class="data-table commits-table">)
~s(<table class="data-table source-table">)
~s(<table class="data-table changed-files-table">)
```

In `tree_view/5`, replace the leading path paragraph with:

```elixir
<div class="path-bar"><span>#{escape(ref)}</span><span>/</span><code>#{escape(browse_path)}</code></div>
```

In `blob_view/5`, replace the return string with:

```elixir
"""
<section class="file-panel">
  <div class="path-bar"><span>#{escape(ref)}</span><span>/</span><code>#{escape(blob_path)}</code><a class="btn btn-outline btn-compact" href="#{raw_url}">Raw</a></div>
  <p class="muted">#{blob.size} bytes</p>
  #{body}
</section>
"""
```

In `blob_view/5`, replace plain `<pre>` returns with `code_block(blob.data)`.

In `commit_detail/4`, wrap the details in a content panel:

```elixir
"""
<section class="content-panel">
  <p><code>#{escape(commit.oid)}</code></p>
  #{code_block(commit.message)}
  <table class="data-table commit-meta-table">
    <tbody>
      <tr><th>Author</th><td>#{escape(commit.author_name)} &lt;#{escape(commit.author_email)}&gt; #{escape(format_unix(commit.author_time))}</td></tr>
      <tr><th>Committer</th><td>#{escape(commit.committer_name)} &lt;#{escape(commit.committer_email)}&gt; #{escape(format_unix(commit.committer_time))}</td></tr>
      <tr><th>Parents</th><td>#{parents}</td></tr>
    </tbody>
  </table>
</section>
#{commit_diff(diff)}
"""
```

- [ ] **Step 6: Run repository tests**

Run:

```bash
mix test apps/fornacast_web/test/fornacast_web_test.exs --trace
```

Expected: repository browser, source, file, commits, branches, tags, and empty repo assertions pass.

- [ ] **Step 7: Commit repository pages**

Run:

```bash
git add apps/fornacast_web/lib/fornacast_web/controllers/repository_controller.ex apps/fornacast_web/test/fornacast_web_test.exs
git commit -m "feat(ui): refresh repository browser pages"
```

## Task 7: Full Local Verification

**Files:**
- Verify: `apps/fornacast_web/lib/fornacast_web/html.ex`
- Verify: `apps/fornacast_web/lib/fornacast_web/controllers/*_controller.ex`
- Verify: `apps/fornacast_web/assets/css/app.css`
- Verify: `apps/fornacast_web/assets/js/app.js`

- [ ] **Step 1: Run formatter**

Run:

```bash
mix format
```

Expected: exits 0.

- [ ] **Step 2: Run scoped web tests**

Run:

```bash
mix test apps/fornacast_web/test
```

Expected: all `FornacastWeb` and setup wizard tests pass.

- [ ] **Step 3: Run production asset build**

Run:

```bash
MIX_ENV=prod FORNACAST_DATABASE_ADAPTER=turso mix assets.deploy
```

Expected: Tailwind and Bun complete; no hardcoded-color errors; generated files remain ignored unless already tracked by the repo.

- [ ] **Step 4: Commit verification cleanup**

If `mix format` changed files, commit those formatting changes:

```bash
git add apps/fornacast_web
git commit -m "style(ui): format refreshed web views"
```

If `mix format` made no changes, skip this commit.

## Task 8: Chrome DevTools Visual Verification

**Files:**
- Verify in browser: all changed web pages
- Save screenshots under: `tmp/ui-verification/`

- [ ] **Step 1: Start the app locally**

Run:

```bash
PORT=4890 mix fornacast.run
```

Expected: app starts on `http://localhost:4890`.

- [ ] **Step 2: Seed browser-visible data**

Use existing web flows in the browser:

1. Open `http://localhost:4890/setup` if the instance is uninitialized.
2. Create the first administrator.
3. Log in.
4. Add one SSH key.
5. Create one empty repository.
6. Push or use existing test/dev data to inspect a non-empty repository.

- [ ] **Step 3: Capture desktop screenshots with Chrome DevTools**

Use Chrome DevTools at `1440x900`, viewport-only screenshots. Capture:

- `tmp/ui-verification/login-desktop.png`
- `tmp/ui-verification/setup-desktop.png`
- `tmp/ui-verification/dashboard-desktop.png`
- `tmp/ui-verification/new-repo-desktop.png`
- `tmp/ui-verification/ssh-keys-desktop.png`
- `tmp/ui-verification/repo-overview-desktop.png`
- `tmp/ui-verification/repo-source-desktop.png`
- `tmp/ui-verification/repo-file-desktop.png`

- [ ] **Step 4: Capture mobile screenshots with Chrome DevTools**

Use Chrome DevTools at `390x844`, viewport-only screenshots. Capture:

- `tmp/ui-verification/dashboard-mobile.png`
- `tmp/ui-verification/repo-overview-mobile.png`
- `tmp/ui-verification/repo-file-mobile.png`
- `tmp/ui-verification/ssh-keys-mobile.png`

- [ ] **Step 5: Run browser layout checks**

In Chrome DevTools, evaluate:

```javascript
(() => {
  const issues = [];
  if (document.documentElement.scrollWidth > window.innerWidth) {
    issues.push({ type: "horizontal-overflow", width: document.documentElement.scrollWidth });
  }

  document.querySelectorAll("a, button, input, textarea, select").forEach((el) => {
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) {
      issues.push({ type: "empty-interactive", text: el.textContent || el.name || el.href });
    }
  });

  return issues;
})()
```

Expected: `[]`.

- [ ] **Step 6: Check console and network**

Use Chrome DevTools console and network lists.

Expected:

- no JavaScript errors
- no failed CSS or JS asset requests
- no text overlap in screenshots
- no horizontal overflow on desktop or mobile

- [ ] **Step 7: Commit final visual fixes**

If visual verification requires small CSS or markup fixes, make the fixes, rerun Tasks 7 and 8 checks, then commit:

```bash
git add apps/fornacast_web
git commit -m "fix(ui): polish responsive forge layout"
```

If no visual fixes are needed, skip this commit.

## Task 9: Final Review And Handoff

**Files:**
- Verify: git history and working tree

- [ ] **Step 1: Inspect final diff**

Run:

```bash
git log --oneline --decorate --max-count=8
git status --short --branch
```

Expected:

- working tree is clean
- commits are split by tests, shell helpers, styles, utility pages, repository pages, and final visual fixes

- [ ] **Step 2: Summarize verification evidence**

Prepare a concise handoff with:

- commits created
- local commands run
- Chrome DevTools pages inspected
- screenshots saved under `tmp/ui-verification/`
- any known residual risk

- [ ] **Step 3: Stop local server**

Stop the `mix fornacast.run` process with `Ctrl+C`.

Expected: no app server remains running in the terminal.

## Self-Review

- Spec coverage: shell, dashboard, repository overview, source/file views, commits/branches/tags, SSH keys, setup/login, token colors, responsiveness, and Chrome DevTools verification are covered by Tasks 1-8.
- Scope check: this plan touches only approved UI files and focused web tests. It does not change routes, auth, data models, Git transport, database behavior, or Forgejo feature scope.
- Placeholder scan: the plan contains no unresolved placeholders, future work markers, or unspecified implementation steps.
- Type and name consistency: helper names used in controller tasks are introduced in Task 2 before use in Tasks 4-6.
