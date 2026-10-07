defmodule FornacastWeb.ReleaseAssetController do
  use FornacastWeb, :controller

  alias FornacastWeb.{ReleaseDownload, RepositoryWeb}

  def download(conn, %{"owner" => owner, "repo" => repo, "asset_id" => id}) do
    actor = conn.assigns[:current_user]

    with {:ok, id} <- positive_id(id),
         {:ok, asset} <- ForgeReleases.get_asset(actor, owner, repo, id) do
      ReleaseDownload.asset(conn, actor, owner, repo, asset)
    else
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  def archive(conn, %{"owner" => owner, "repo" => repo, "release_id" => id, "format" => format}) do
    with {:ok, id} <- positive_id(id),
         {:ok, archive} <-
           ForgeReleases.Archives.prepare(conn.assigns[:current_user], owner, repo, id, format) do
      try do
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-disposition", ReleaseDownload.disposition(archive.filename))
        |> put_resp_content_type(archive.content_type)
        |> send_file(200, archive.path)
      after
        ForgeReleases.Archives.cleanup(archive)
      end
    else
      {:error, reason} -> RepositoryWeb.error(conn, nil, reason)
    end
  end

  defp positive_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end
end
