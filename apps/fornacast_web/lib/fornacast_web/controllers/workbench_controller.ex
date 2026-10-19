defmodule FornacastWeb.WorkbenchController do
  use FornacastWeb, :controller

  alias FornacastWeb.WorkbenchHTML

  plug :put_private_no_store

  def issues(conn, params), do: workbench(conn, params, :issue)
  def pull_requests(conn, params), do: workbench(conn, params, :pull_request)

  defp workbench(conn, params, kind) do
    filters = Map.take(params, ["state", "page", "per_page"])
    actor = conn.assigns.current_user

    result =
      case kind do
        :issue -> ForgeIssues.list_workbench(actor, :issue, filters)
        :pull_request -> ForgePulls.list_workbench(actor, filters)
      end

    case result do
      {:ok, result} ->
        entries = Enum.map(result.entries, &Map.put(&1, :href, detail_path(conn, kind, &1)))

        rendered =
          WorkbenchHTML.index(%{
            kind: kind,
            page: %{result | entries: entries},
            state: String.downcase(Map.get(filters, "state", "open")),
            __changed__: nil
          })

        page(
          conn,
          title(kind),
          rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
        )

      {:error, {:validation, _errors}} ->
        conn |> put_status(:bad_request) |> page(title(kind), "Invalid workbench filters.")

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> page(title(kind), "Workbench access is unavailable.")
    end
  end

  defp detail_path(conn, :issue, entry),
    do: Routes.issue_path(conn, :show, entry.owner_slug, entry.repository_slug, entry.number)

  defp detail_path(conn, :pull_request, entry),
    do:
      Routes.pull_request_path(conn, :show, entry.owner_slug, entry.repository_slug, entry.number)

  defp title(:issue), do: "Issues"
  defp title(:pull_request), do: "Pull Requests"

  defp put_private_no_store(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
  end
end
