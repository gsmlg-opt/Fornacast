defmodule ForgeGitHub.PublicAccessTest do
  use ExUnit.Case, async: false

  alias ForgeGitHub.{Client, Error, LFS, Organization, Repository, RequestGate}

  setup {Req.Test, :verify_on_exit!}

  test "different public run keys share the same request gate" do
    parent = self()

    holder =
      Task.async(fn ->
        RequestGate.run({:public, 1}, fn ->
          send(parent, :public_gate_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :public_gate_held

    stub = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      send(parent, :provider_requested)
      Req.Test.json(conn, %{"id" => 99, "login" => "acme"})
    end)

    try do
      assert {:error, %Error{kind: :request_gate_busy}} =
               Client.organization(
                 :public,
                 "acme",
                 Keyword.put(options(stub), :gate_key, {:one_time_run, 82})
               )

      refute_received :provider_requested
    after
      send(holder.pid, :release)
      assert :ok = Task.await(holder)
    end
  end

  test "anonymous organization discovery omits authentication and requests public inventory" do
    stub = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "user-agent") != []

      case conn.request_path do
        "/orgs/acme" ->
          Req.Test.json(conn, %{"id" => 99, "login" => "acme", "name" => "Acme"})

        "/orgs/acme/repos" ->
          assert URI.decode_query(conn.query_string)["type"] == "public"
          Req.Test.json(conn, [repository()])

        "/repos/acme/widgets" ->
          Req.Test.json(conn, repository())
      end
    end)

    assert {:ok, %Organization{id: 99}} = Client.organization(:public, "acme", options(stub))

    assert {:ok, [%Repository{id: 41, visibility: :public}]} =
             Client.organization_repositories(:public, "acme", options(stub))

    assert {:ok, %Repository{id: 41, visibility: :public}} =
             Client.repository(:public, "acme", "widgets", options(stub))
  end

  test "anonymous repository decoding rejects private inventory instead of exposing it" do
    stub = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/orgs/acme" -> Req.Test.json(conn, %{"id" => 99, "login" => "acme"})
        "/orgs/acme/repos" -> Req.Test.json(conn, [private_repository()])
        "/repos/acme/widgets" -> Req.Test.json(conn, private_repository())
      end
    end)

    assert {:error, %Error{kind: :not_found}} =
             Client.repository(:public, "acme", "widgets", options(stub))

    assert {:error, %Error{kind: :invalid_response}} =
             Client.organization_repositories(:public, "acme", options(stub))
  end

  test "anonymous inventory cannot succeed with an unsafe next page" do
    stub = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/orgs/acme" ->
          Req.Test.json(conn, %{"id" => 99, "login" => "acme"})

        "/orgs/acme/repos" ->
          conn
          |> Plug.Conn.put_resp_header(
            "link",
            "<https://example.test/repos?page=2>; rel=\"next\""
          )
          |> Req.Test.json([repository()])
      end
    end)

    assert {:error, %Error{kind: :invalid_pagination}} =
             Client.organization_repositories(:public, "acme", options(stub))
  end

  test "anonymous requests retain rate limit recovery and refuse authenticated or write endpoints" do
    stub = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.expect(stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
      |> Plug.Conn.put_resp_header("x-ratelimit-reset", "2000000000")
      |> Plug.Conn.send_resp(403, "rate limit")
    end)

    assert {:error, %Error{kind: :primary_rate_limit, retry_at: %DateTime{}}} =
             Client.organization(:public, "acme", options(stub))

    assert {:error, %Error{kind: :invalid_request}} =
             Client.authenticated_user(:public, options(stub))

    assert {:error, %Error{kind: :invalid_request}} =
             Client.request(:public, :post, "/repos/acme/widgets/issues", options(stub))
  end

  test "anonymous metadata and LFS use one shared public request identity" do
    assert :ok = RequestGate.run({:public, 1}, fn -> :ok end)
    stub = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.expect(stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Req.Test.json(conn, [])
    end)

    assert {:ok, %{releases: [], next_cursor: nil}} =
             ForgeGitHub.ReleaseClient.list_releases_page(
               :public,
               "acme",
               "widgets",
               nil,
               options(stub)
             )

    objects = [%{oid: String.duplicate("a", 64), size: 3}]

    assert {:ok, [%LFS.Object{size: 3}]} =
             LFS.batch(:public, "acme", "widgets", :download, objects,
               gate_key: {:public, 1},
               transport: __MODULE__.LFSTransport,
               test_pid: self()
             )

    assert_received {:lfs_headers, headers}
    refute List.keymember?(headers, "authorization", 0)

    assert {:error, %Error{kind: :invalid_request}} =
             LFS.batch(:public, "acme", "widgets", :upload, objects,
               gate_key: {:public, 1},
               transport: __MODULE__.LFSTransport,
               test_pid: self()
             )

    refute_received {:lfs_headers, _}
  end

  defmodule LFSTransport do
    def request(:post, _url, headers, _body, opts) do
      send(opts[:test_pid], {:lfs_headers, headers})

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/vnd.git-lfs+json"}],
         body:
           JSON.encode!(%{
             "objects" => [
               %{
                 "oid" => String.duplicate("a", 64),
                 "size" => 3,
                 "actions" => %{
                   "download" => %{
                     "href" => "https://github-cloud.githubusercontent.com/download"
                   }
                 }
               }
             ]
           })
       }}
    end
  end

  defp options(stub) do
    [
      plug: {Req.Test, stub},
      gate_key: {:public, 1},
      resolver: fn "api.github.com" -> {:ok, [{140, 82, 114, 5}]} end
    ]
  end

  defp private_repository,
    do: repository() |> Map.put("private", true) |> Map.put("visibility", "private")

  defp repository do
    %{
      "id" => 41,
      "name" => "widgets",
      "full_name" => "acme/widgets",
      "owner" => %{"id" => 99, "login" => "acme"},
      "private" => false,
      "visibility" => "public",
      "default_branch" => "main",
      "fork" => false,
      "archived" => false,
      "has_issues" => true,
      "allow_merge_commit" => true
    }
  end
end
