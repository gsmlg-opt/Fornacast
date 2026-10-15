defmodule FornacastWeb.AdminJobsController do
  use FornacastWeb, :controller

  alias ForgeImports.AdminJobs
  alias FornacastWeb.AdminJobsHTML

  def index(conn, _params), do: redirect(conn, to: "/-/admin/jobs")

  def jobs(conn, params) do
    case AdminJobs.list_jobs(conn.assigns.current_user, params) do
      {:ok, listing} ->
        render_jobs(conn, listing, nil)

      {:error, :invalid_filter} ->
        listing = %{
          jobs: [],
          queues: [],
          filters: %{queue: nil, state: nil},
          page: 1,
          has_next?: false
        }

        conn
        |> put_status(:bad_request)
        |> render_jobs(listing, "Invalid jobs filter. Choose a queue, state, and valid page.")

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> page("Admin", error_panel("Site administrator access required."))
    end
  end

  defp render_jobs(conn, listing, error) do
    rendered = AdminJobsHTML.index(%{listing: listing, error: error, __changed__: nil})
    body = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

    conn
    |> assign(:page_section, "Administration")
    |> page("Styx Jobs", body)
  end
end
