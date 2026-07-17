defmodule FornacastWeb.APIKeyController do
  use FornacastWeb, :controller

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    render_index(conn, user)
  end

  def create(%Plug.Conn{assigns: %{current_user: user}} = conn, %{"api_key" => params}) do
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

    notices =
      secret_panel(Keyword.get(options, :secret)) <>
        error_message(Keyword.get(options, :errors))

    page(conn, "API keys", """
    #{settings_navigation()}
    #{section_header("API keys", "Create personal API keys for Git and API access.", "")}
    #{notices}
    <div class="settings-grid">
      #{api_key_form(form)}
      #{api_key_table(keys)}
    </div>
    """)
  end

  defp api_key_attrs(params) do
    scopes =
      params
      |> Map.get("scopes", %{})
      |> Enum.filter(fn {_scope, enabled} -> enabled in ["true", "on", true] end)
      |> Enum.map(&elem(&1, 0))

    params
    |> Map.put("scopes", scopes)
    |> drop_blank_expiration()
  end

  defp drop_blank_expiration(%{"expires_at" => ""} = attrs), do: Map.delete(attrs, "expires_at")
  defp drop_blank_expiration(attrs), do: attrs

  defp settings_navigation do
    ~s(<nav aria-label="Settings"><a href="/settings/ssh-keys">SSH keys</a> <a href="/settings/api-keys">API keys</a></nav>)
  end

  defp api_key_form(form) do
    name = escape(Map.get(form, "name", ""))
    scopes = Map.get(form, "scopes", %{})
    expires_at = escape(Map.get(form, "expires_at", ""))

    form_panel(
      "Create API key",
      "The secret is shown once. Store it somewhere safe.",
      """
      <form action="/settings/api-keys" method="post">
        #{csrf_input()}
        <label>Name <input name="api_key[name]" value="#{name}"></label>
        <fieldset>
          <legend>Repository scopes</legend>
          <label><input type="checkbox" name="api_key[scopes][repo:read]" value="true"#{checked(scopes, "repo:read")}> repo:read</label>
          <label><input type="checkbox" name="api_key[scopes][repo:write]" value="true"#{checked(scopes, "repo:write")}> repo:write</label>
        </fieldset>
        <label>Expires at (optional) <input type="datetime-local" name="api_key[expires_at]" value="#{expires_at}"></label>
        <button class="btn btn-primary" type="submit">Create key</button>
      </form>
      """
    )
  end

  defp checked(scopes, scope) when is_map(scopes) do
    if Map.get(scopes, scope) in ["true", "on", true], do: " checked", else: ""
  end

  defp checked(_scopes, _scope), do: ""

  defp api_key_table([]),
    do: empty_state("No API keys", "Create a personal API key for repository access.")

  defp api_key_table(keys) do
    rows = Enum.map_join(keys, "\n", &api_key_row/1)

    """
    <section class="content-panel">
      <table class="data-table key-table">
        <thead><tr><th>Name</th><th>Prefix</th><th>Scopes</th><th>Created</th><th>Expires</th><th>Last used</th><th>Status</th><th>Action</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </section>
    """
  end

  defp api_key_row(key) do
    """
    <tr>
      <td>#{escape(key.name)}</td>
      <td><code>#{escape(key.token_prefix)}</code></td>
      <td>#{format_scopes(key.scopes)}</td>
      <td>#{format_datetime(key.inserted_at, "Unknown")}</td>
      <td>#{format_datetime(key.expires_at, "Never")}</td>
      <td>#{format_datetime(key.last_used_at, "Never")}</td>
      <td>#{if key.revoked_at, do: "Revoked", else: "Active"}</td>
      <td>#{revoke_form(key)}</td>
    </tr>
    """
  end

  defp format_scopes(scopes) do
    scopes
    |> Enum.filter(fn {_scope, enabled} -> enabled end)
    |> Enum.map_join(", ", fn {scope, _enabled} -> escape(scope) end)
  end

  defp format_datetime(nil, fallback), do: fallback
  defp format_datetime(datetime, _fallback), do: datetime |> DateTime.to_string() |> escape()

  defp revoke_form(%{revoked_at: nil, id: id}) do
    """
    <form action="/settings/api-keys/#{id}" method="post">
      #{csrf_input()}
      <input type="hidden" name="_method" value="delete">
      <button class="btn btn-error btn-sm" type="submit">Revoke</button>
    </form>
    """
  end

  defp revoke_form(_key), do: ""

  defp secret_panel(nil), do: ""

  defp secret_panel(secret) do
    """
    <section class="content-panel" role="status">
      <h2>API key created</h2>
      <p>Copy this secret now. It will not be shown again.</p>
      <code>#{escape(secret)}</code>
    </section>
    """
  end

  defp error_message(nil), do: ""
  defp error_message(message), do: error_panel(message)

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
end
