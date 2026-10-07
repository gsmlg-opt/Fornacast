defmodule FornacastAPI.ReleaseDownloadTest do
  use ExUnit.Case, async: true
  alias FornacastAPI.ReleaseDownload

  test "ranges are bounded, include suffixes, and reject multipart and empty ranges" do
    assert ReleaseDownload.range([], 0) == {:ok, :all}
    assert ReleaseDownload.range(["bytes=2-4"], 8) == {:ok, {2, 4}}
    assert ReleaseDownload.range(["bytes=2-"], 8) == {:ok, {2, 7}}
    assert ReleaseDownload.range(["bytes=-3"], 8) == {:ok, {5, 7}}
    assert ReleaseDownload.range(["bytes=-99"], 8) == {:ok, {0, 7}}
    assert ReleaseDownload.range(["bytes=2-99"], 8) == {:ok, {2, 7}}

    for range <- ["bytes=8-", "bytes=4-2", "bytes=-0", "bytes=-", "bytes=0-1,3-4"] do
      assert ReleaseDownload.range([range], 8) == :error
    end

    assert ReleaseDownload.range(["bytes=0-0"], 0) == :error
    assert ReleaseDownload.range(["bytes=0-0", "bytes=1-1"], 8) == :error
  end

  test "binary negotiation respects explicitly rejected octet-stream" do
    conn = Plug.Test.conn(:get, "/")

    mixed =
      Plug.Conn.put_req_header(conn, "accept", "application/octet-stream;q=0, application/json")

    refute FornacastAPI.Plugs.MediaType.binary_asset_request?(mixed)

    assert FornacastAPI.Plugs.MediaType.binary_asset_request?(
             Plug.Conn.put_req_header(conn, "accept", "application/octet-stream")
           )
  end

  test "binary media acceptance matches the asset or archive route" do
    base = "/api/v3/repos/owner/repo/releases"

    for {path, accept} <- [
          {"#{base}/assets/1", "application/zip"},
          {"#{base}/assets/1/download", "application/x-tar"},
          {"#{base}/1/archives/tar", "application/zip"},
          {"#{base}/1/archives/zip", "application/x-tar"}
        ] do
      conn =
        Plug.Test.conn(:get, path)
        |> Plug.Conn.put_req_header("accept", accept)
        |> FornacastAPI.Plugs.MediaType.call([])

      assert conn.halted
      assert conn.status == 406
    end

    for {path, accept} <- [
          {"#{base}/assets/1", "application/octet-stream"},
          {"#{base}/1/archives/tar", "application/x-tar"},
          {"#{base}/1/archives/zip", "application/zip"}
        ] do
      conn =
        Plug.Test.conn(:get, path)
        |> Plug.Conn.put_req_header("accept", accept)
        |> FornacastAPI.Plugs.MediaType.call([])

      refute conn.halted
    end
  end

  test "filenames cannot inject response headers" do
    assert ReleaseDownload.disposition("name\r\nX-Evil: yes") =~ "%0D%0A"
    refute ReleaseDownload.disposition("name\r\nX-Evil: yes") =~ "\r\n"
  end
end
