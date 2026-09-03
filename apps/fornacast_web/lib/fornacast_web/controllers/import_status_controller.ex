defmodule FornacastWeb.ImportStatusController do
  use FornacastWeb, :controller

  alias ForgeAccounts.User
  alias ForgeImports.RunView
  alias FornacastWeb.ImportStatusJSON

  plug :require_active_user

  def show(%Plug.Conn{assigns: %{current_user: actor}} = conn, params) do
    with {:ok, run_id} <- canonical_id(Map.get(params, "id")),
         {:ok, %RunView{} = run} <- fetch_status(conn, actor, run_id),
         :ok <- validate_status_view(run, actor, run_id) do
      conn
      |> put_status(:ok)
      |> json(ImportStatusJSON.show(run))
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :invalid_view} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "unavailable"})
    end
  end

  defp fetch_status(conn, actor, run_id) do
    case imports(conn).get_status(actor, run_id) do
      {:ok, %RunView{} = run} -> {:ok, run}
      {:error, :not_found} -> {:error, :not_found}
      _other -> {:error, :invalid_view}
    end
  end

  defp validate_status_view(
         %RunView{id: id, actor_user_id: actor_id},
         %User{id: actor_id},
         run_id
       )
       when id == run_id,
       do: :ok

  defp validate_status_view(_run, _actor, _run_id), do: {:error, :not_found}

  defp canonical_id(value) when is_binary(value) do
    with true <- byte_size(value) <= 19,
         true <- Regex.match?(~r/\A[1-9][0-9]*\z/, value),
         {id, ""} <- Integer.parse(value),
         true <- id in 1..9_223_372_036_854_775_807 do
      {:ok, id}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp canonical_id(_value), do: {:error, :not_found}

  defp imports(conn), do: conn.private[:forge_imports] || ForgeImports

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
