defmodule FornacastWeb.WorkbenchController do
  use FornacastWeb, :controller

  def issues(conn, _params) do
    page(conn, "Issues", ~s(<p class="muted">Issues are not wired in this demo yet.</p>))
  end

  def pull_requests(conn, _params) do
    page(
      conn,
      "Pull Requests",
      ~s(<p class="muted">Pull requests are not wired in this demo yet.</p>)
    )
  end
end
