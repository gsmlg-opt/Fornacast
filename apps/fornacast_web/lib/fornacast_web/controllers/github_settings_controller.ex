defmodule FornacastWeb.GitHubSettingsController do
  use FornacastWeb, :controller

  alias ForgeAccounts.{GitHubAccountView, User}
  alias ForgeAccounts.GitHubAccounts.CredentialCallbackError
  alias ForgeImports.GitHubAccounts.CredentialVerificationError
  alias FornacastWeb.{GitHubSettingsHTML, RequestMetadata}

  plug :require_active_user

  @max_identity_id 9_223_372_036_854_775_807
  @max_pat_bytes 4_096
  @canonical_identity_id ~r/\A[1-9][0-9]*\z/
  @recoverable_turso_codes [:busy, :io, :corrupt]

  def index(%Plug.Conn{assigns: %{current_user: actor}} = conn, _params) do
    case service_call(fn -> github_accounts(conn).list_github_accounts(actor) end) do
      {:ok, accounts} ->
        render_accounts(conn, accounts)

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> render_accounts([], "GitHub account settings are temporarily unavailable.")
    end
  end

  def create(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, pat} <- pat_param(params),
         result <-
           service_call(fn ->
             github_accounts(conn).link_github_account(
               actor,
               pat,
               RequestMetadata.from_conn(conn)
             )
           end) do
      handle_result(conn, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def reverify(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, identity_id} <- identity_id(params),
         result <-
           service_call(fn ->
             github_accounts(conn).reverify_github_account(
               actor,
               identity_id,
               RequestMetadata.from_conn(conn)
             )
           end) do
      handle_result(conn, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def replace(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, identity_id} <- identity_id(params),
         {:ok, pat} <- pat_param(params),
         result <-
           service_call(fn ->
             github_accounts(conn).replace_github_credential(
               actor,
               identity_id,
               pat,
               RequestMetadata.from_conn(conn)
             )
           end) do
      handle_result(conn, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def delete_credential(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, identity_id} <- identity_id(params),
         result <-
           service_call(fn ->
             github_accounts(conn).delete_github_credential(
               actor,
               identity_id,
               RequestMetadata.from_conn(conn)
             )
           end) do
      handle_result(conn, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def unlink(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, identity_id} <- identity_id(params),
         result <-
           service_call(fn ->
             github_accounts(conn).unlink_github_account(
               actor,
               identity_id,
               RequestMetadata.from_conn(conn)
             )
           end) do
      handle_result(conn, result)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp handle_result(conn, {:ok, _account}) do
    conn
    |> put_status(:see_other)
    |> redirect(to: "/settings/github")
  end

  defp handle_result(conn, {:error, reason}), do: render_error(conn, reason)
  defp handle_result(conn, _unexpected), do: render_error(conn, :account_update_failed)

  defp render_error(conn, reason) do
    {status, message} = error_response(reason)

    accounts =
      case service_call(fn ->
             github_accounts(conn).list_github_accounts(conn.assigns.current_user)
           end) do
        {:ok, accounts} when is_list(accounts) -> accounts
        _unavailable -> []
      end

    conn
    |> put_status(status)
    |> render_accounts(accounts, message)
  end

  defp error_response(reason) when reason in [:not_found, :forbidden],
    do: {:not_found, "GitHub account not found."}

  defp error_response(reason) when reason in [:invalid_credential, :credential_invalid],
    do: {:unprocessable_entity, "GitHub rejected the personal access token."}

  defp error_response(:identity_mismatch),
    do: {:unprocessable_entity, "That PAT belongs to a different GitHub account."}

  defp error_response(:invalid_pat),
    do: {:unprocessable_entity, "Enter a GitHub personal access token."}

  defp error_response(:already_linked),
    do: {:conflict, "That GitHub account cannot be linked."}

  defp error_response(:credential_in_use),
    do: {:conflict, "This saved PAT is in use by an active import."}

  defp error_response(reason)
       when reason in [:busy, :stale, :request_gate_busy, :duplicate_operation],
       do: {:conflict, "The GitHub account changed or is busy. Refresh and try again."}

  defp error_response(reason)
       when reason in [:primary_rate_limit, :secondary_rate_limit],
       do: {:service_unavailable, "GitHub is rate limiting requests. Try again later."}

  defp error_response(_reason),
    do: {:service_unavailable, "GitHub account settings are temporarily unavailable."}

  defp render_accounts(conn, accounts, error \\ nil) do
    with true <- is_list(accounts),
         true <- Enum.all?(accounts, &match?(%GitHubAccountView{}, &1)) do
      rendered =
        GitHubSettingsHTML.index(%{
          accounts: accounts,
          error: error,
          __changed__: nil
        })

      conn
      |> page(
        "GitHub accounts",
        settings_layout(
          :github,
          rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
        )
      )
    else
      _invalid ->
        conn
        |> put_status(:service_unavailable)
        |> render_accounts([], "GitHub account settings are temporarily unavailable.")
    end
  end

  defp pat_param(%{"github_account" => %{"pat" => pat}}) when is_binary(pat) do
    if byte_size(pat) in 1..@max_pat_bytes and String.valid?(pat) and printable_ascii?(pat) do
      {:ok, pat}
    else
      {:error, :invalid_pat}
    end
  end

  defp pat_param(_params), do: {:error, :invalid_pat}

  defp identity_id(%{"identity_id" => value}) when is_binary(value) do
    with true <- byte_size(value) <= 19,
         true <- Regex.match?(@canonical_identity_id, value),
         {identity_id, ""} when identity_id <= @max_identity_id <- Integer.parse(value) do
      {:ok, identity_id}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp identity_id(_params), do: {:error, :not_found}

  defp printable_ascii?(<<>>), do: true

  defp printable_ascii?(<<byte, rest::binary>>) when byte in 0x21..0x7E,
    do: printable_ascii?(rest)

  defp printable_ascii?(_pat), do: false

  defp service_call(callback) when is_function(callback, 0) do
    callback.()
  rescue
    _error in [CredentialVerificationError, CredentialCallbackError, DBConnection.ConnectionError] ->
      {:error, :credential_service_unavailable}

    error in [:"Elixir.Turso.Error"] ->
      if error.code in @recoverable_turso_codes do
        {:error, :credential_service_unavailable}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp github_accounts(conn), do: conn.private[:forge_imports] || ForgeImports

  defp require_active_user(
         %Plug.Conn{assigns: %{current_user: %User{kind: :user, state: :active}}} = conn,
         _opts
       ),
       do: conn

  defp require_active_user(conn, _opts) do
    conn
    |> delete_session(:user_id)
    |> redirect(to: "/login")
    |> halt()
  end
end
