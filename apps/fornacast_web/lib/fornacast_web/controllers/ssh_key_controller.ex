defmodule FornacastWeb.SSHKeyController do
  use FornacastWeb, :controller

  alias FornacastWeb.SSHKeyHTML

  plug :put_private_no_store

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    render_index(conn, user, %{})
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"ssh_key" => attrs}) do
    case ForgeAccounts.create_ssh_key(user, attrs) do
      {:ok, _key} ->
        redirect(conn, to: ssh_keys_path(conn))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_index(user, attrs, validation_errors(changeset))
    end
  end

  def delete(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"id" => id}) do
    _ = ForgeAccounts.delete_ssh_key(user, id)
    redirect(conn, to: ssh_keys_path(conn))
  end

  defp render_index(conn, user, form, error \\ nil) do
    keys = ForgeAccounts.list_user_ssh_keys(user)
    path = ssh_keys_path(conn)

    rendered =
      SSHKeyHTML.index(%{
        keys: keys,
        path: path,
        form: form,
        error: error,
        __changed__: nil
      })

    content = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    page(conn, "SSH keys", settings_layout(:ssh_keys, content))
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

  defp put_private_no_store(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
