defmodule FornacastWeb.HTML do
  @moduledoc false

  import Phoenix.HTML
  import Plug.Conn

  def page(conn, title, body) do
    current_user = conn.assigns[:current_user]

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
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{escape(title)} - Fornacast</title>
        <style>
          body { color: #182026; font-family: system-ui, sans-serif; line-height: 1.5; margin: 0; background: #f6f7f8; }
          header, main { margin: 0 auto; max-width: 980px; padding: 20px; }
          header { align-items: center; display: flex; justify-content: space-between; }
          nav { align-items: center; display: flex; gap: 12px; }
          a { color: #2459a6; }
          form.inline { display: inline; }
          input, textarea, select { border: 1px solid #b9c2cc; border-radius: 4px; box-sizing: border-box; display: block; margin: 4px 0 12px; max-width: 540px; padding: 8px; width: 100%; }
          button { background: #2459a6; border: 0; border-radius: 4px; color: white; cursor: pointer; padding: 8px 12px; }
          pre { background: #101820; color: #e9eef2; overflow-x: auto; padding: 14px; }
          table { border-collapse: collapse; width: 100%; }
          th, td { border-bottom: 1px solid #d8dde3; padding: 8px; text-align: left; }
          .muted { color: #596773; }
          .error { background: #ffe8e8; border: 1px solid #e2a3a3; padding: 10px; }
        </style>
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
