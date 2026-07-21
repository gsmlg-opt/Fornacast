defmodule FornacastAPI.MetaController do
  use FornacastAPI, :controller

  def versions(conn, _params) do
    FornacastAPI.Response.json(conn, 200, ["2022-11-28", "2026-03-10"])
  end
end
