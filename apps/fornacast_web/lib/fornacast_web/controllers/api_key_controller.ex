defmodule FornacastWeb.APIKeyController do
  use FornacastWeb, :controller

  alias FornacastWeb.APIKeyHTML

  plug :put_private_no_store
  plug :require_active_user

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    render_index(conn, user)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"api_key" => params}) do
    params = if is_map(params), do: params, else: %{}
    attrs = api_key_attrs(params)

    case ForgeAccounts.create_api_key(user, attrs) do
      {:ok, _key, secret} ->
        conn
        |> put_status(:created)
        |> render_index(user, secret: secret)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_index(user, errors: validation_errors(changeset), form: params)
    end
  end

  def delete(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"id" => id}) do
    _ = ForgeAccounts.revoke_api_key(user, id)
    redirect(conn, to: "/settings/api-keys")
  end

  defp render_index(conn, user, options \\ []) do
    keys = ForgeAccounts.list_user_api_keys(user)
    form = Keyword.get(options, :form, %{})
    secret = Keyword.get(options, :secret)
    errors = Keyword.get(options, :errors)

    rendered =
      APIKeyHTML.index(%{
        keys: keys,
        form: form,
        secret: secret,
        errors: errors,
        __changed__: nil
      })

    content = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    page(conn, "API keys", settings_layout(:api_keys, content))
  end

  defp api_key_attrs(params) do
    scopes =
      params
      |> Map.get("scopes", %{})
      |> normalize_scopes()

    params
    |> Map.put("scopes", scopes)
    |> normalize_expiration()
  end

  defp normalize_scopes(scopes) when is_map(scopes) do
    scopes
    |> Enum.filter(fn {_scope, enabled} -> enabled in ["true", "on", true] end)
    |> Enum.map(&elem(&1, 0))
  end

  defp normalize_scopes(_scopes), do: []

  defp normalize_expiration(%{"expires_at" => ""} = attrs),
    do: Map.delete(attrs, "expires_at")

  defp normalize_expiration(%{"expires_at" => value} = attrs) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} ->
        Map.put(
          attrs,
          "expires_at",
          naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
        )

      {:error, _reason} ->
        attrs
    end
  end

  defp normalize_expiration(attrs), do: attrs

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

  defp require_active_user(%Plug.Conn{assigns: %{current_user: %{state: :active}}} = conn, _opts),
    do: conn

  defp require_active_user(conn, _opts) do
    conn
    |> delete_session(:user_id)
    |> redirect(to: "/login")
    |> halt()
  end

  defp put_private_no_store(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
