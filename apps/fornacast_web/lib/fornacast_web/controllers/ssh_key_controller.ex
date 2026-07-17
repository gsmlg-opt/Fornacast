defmodule FornacastWeb.SSHKeyController do
  use FornacastWeb, :controller

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    keys = ForgeAccounts.list_user_ssh_keys(user)
    path = ssh_keys_path(conn)

    rows =
      keys
      |> Enum.map(fn key ->
        """
        <tr>
          <td>#{escape(key.title)}</td>
          <td><code>#{escape(key.fingerprint_sha256)}</code></td>
          <td>
            <form action="#{path}/#{key.id}" method="post">
              #{csrf_input()}
              <input type="hidden" name="_method" value="delete">
              <button class="btn btn-error btn-sm" type="submit">Delete</button>
            </form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    key_table =
      if rows == "" do
        empty_state("No SSH keys", "Add a public key to push repositories over SSH.")
      else
        """
        <section class="content-panel">
          <table class="data-table key-table">
            <thead><tr><th>Title</th><th>Fingerprint</th><th>Action</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
        </section>
        """
      end

    page(conn, "SSH keys", """
    #{settings_navigation()}
    #{section_header("SSH keys", "Manage SSH keys for Git transport.", "")}
    <div class="settings-grid">
      #{ssh_key_form(path)}
      #{key_table}
    </div>
    """)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"ssh_key" => attrs}) do
    case ForgeAccounts.create_ssh_key(user, attrs) do
      {:ok, _key} ->
        redirect(conn, to: ssh_keys_path(conn))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> page(
          "SSH keys",
          settings_navigation() <>
            error_panel(validation_errors(changeset)) <> ssh_key_form(ssh_keys_path(conn))
        )
    end
  end

  def delete(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"id" => id}) do
    _ = ForgeAccounts.delete_ssh_key(user, id)
    redirect(conn, to: ssh_keys_path(conn))
  end

  defp ssh_keys_path(%Plug.Conn{request_path: "/settings" <> _}), do: "/settings/ssh-keys"
  defp ssh_keys_path(_conn), do: "/ssh-keys"

  defp validation_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      label = field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
      Enum.map(messages, &"#{label} #{&1}")
    end)
    |> Enum.join("; ")
  end

  defp ssh_key_form(path) do
    form_panel(
      "Add SSH key",
      "Paste an OpenSSH public key from your workstation.",
      """
      <form action="#{path}" method="post">
        #{csrf_input()}
        <label>Title <input name="ssh_key[title]"></label>
        <label>Public key <textarea name="ssh_key[public_key]" rows="5"></textarea></label>
        <button class="btn btn-primary" type="submit">Add key</button>
      </form>
      """
    )
  end

  defp settings_navigation do
    ~s(<nav aria-label="Settings"><a href="/settings/ssh-keys">SSH keys</a> <a href="/settings/api-keys">API keys</a></nav>)
  end
end
