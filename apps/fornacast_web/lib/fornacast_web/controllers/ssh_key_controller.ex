defmodule FornacastWeb.SSHKeyController do
  use FornacastWeb, :controller

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    keys = ForgeAccounts.list_user_ssh_keys(user)

    rows =
      keys
      |> Enum.map(fn key ->
        """
        <tr>
          <td>#{escape(key.title)}</td>
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
    #{section_header("SSH keys", "Manage SSH keys for Git transport.", "")}
    <div class="settings-grid">
      #{ssh_key_form()}
      #{key_table}
    </div>
    """)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"ssh_key" => attrs}) do
    case ForgeAccounts.create_ssh_key(user, attrs) do
      {:ok, _key} ->
        redirect(conn, to: "/ssh-keys")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> page("SSH keys", error_panel(inspect(changeset.errors)) <> ssh_key_form())
    end
  end

  def delete(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"id" => id}) do
    _ = ForgeAccounts.delete_ssh_key(user, id)
    redirect(conn, to: "/ssh-keys")
  end

  defp ssh_key_form do
    form_panel(
      "Add SSH key",
      "Paste an OpenSSH public key from your workstation.",
      """
      <form action="/ssh-keys" method="post">
        #{csrf_input()}
        <label>Title <input name="ssh_key[title]"></label>
        <label>Public key <textarea name="ssh_key[public_key]" rows="5"></textarea></label>
        <button class="btn btn-primary" type="submit">Add key</button>
      </form>
      """
    )
  end
end
