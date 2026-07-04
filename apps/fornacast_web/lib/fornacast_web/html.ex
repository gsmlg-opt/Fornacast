defmodule FornacastWeb.HTML do
  @moduledoc false

  import Phoenix.HTML
  import Plug.Conn

  def page(conn, title, body) do
    current_user = conn.assigns[:current_user]
    css_path = FornacastWeb.Endpoint.static_path("/assets/app.css")
    js_path = FornacastWeb.Endpoint.static_path("/assets/app.js")

    nav =
      if current_user do
        """
        <nav>
          <a href="/">Dashboard</a>
          <a href="/repos/new">New repository</a>
          <a href="/ssh-keys">SSH keys</a>
          <form action="/logout" method="post" class="inline">
            #{csrf_input()}
            <input type="hidden" name="_method" value="delete">
            <button type="submit">Logout</button>
          </form>
        </nav>
        """
      else
        ~s(<nav><a href="/login">Login</a></nav>)
      end

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
      <body>
        <header><h1>Fornacast</h1>#{nav}</header>
        <main><h2>#{escape(title)}</h2>#{body}</main>
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
end
