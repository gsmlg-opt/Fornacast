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
          <td>#{escape(key.fingerprint_sha256)}</td>
          <td>
            <form action="/ssh-keys/#{key.id}" method="post">
              #{csrf_input()}
              <input type="hidden" name="_method" value="delete">
              <button type="submit">Delete</button>
            </form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    page(conn, "SSH keys", """
    <form action="/ssh-keys" method="post">
      #{csrf_input()}
      <label>Title <input name="ssh_key[title]"></label>
      <label>Public key <textarea name="ssh_key[public_key]" rows="5"></textarea></label>
      <button type="submit">Add key</button>
    </form>
    <table>
      <thead><tr><th>Title</th><th>Fingerprint</th><th></th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"ssh_key" => attrs}) do
    case ForgeAccounts.create_ssh_key(user, attrs) do
      {:ok, _key} ->
        redirect(conn, to: "/ssh-keys")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> page("SSH keys", ~s(<p class="error">#{escape(inspect(changeset.errors))}</p>))
    end
  end

  def delete(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"id" => id}) do
    _ = ForgeAccounts.delete_ssh_key(user, id)
    redirect(conn, to: "/ssh-keys")
  end
end
