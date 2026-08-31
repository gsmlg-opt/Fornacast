defmodule FornacastWeb.RepositoryCollaborationPageTestGit do
  def with_repository_read(repository, fun), do: fun.(repository, "/test/repository.git")

  def ref_summary(_path, _opts) do
    {:ok,
     %GitCore.RefSummary{
       branch_count: 1,
       tag_count: 0,
       branches: [],
       tags: [],
       refs_truncated: false
     }}
  end
end

defmodule FornacastWeb.RepositoryCollaborationPageTestIssues do
  def open_counts(_viewer, _owner, _repository) do
    Process.put({__MODULE__, :count_calls}, Process.get({__MODULE__, :count_calls}, 0) + 1)
    Process.get({__MODULE__, :counts}, {:ok, %{issues: 4, pull_requests: 2}})
  end

  def list(_viewer, _owner, _repository, _filters),
    do: {:ok, %Fornacast.Page{entries: [%{number: 7}], total: 1, page: 1, per_page: 30}}

  def get(_viewer, _owner, _repository, number), do: {:ok, %{number: number}}

  def list_comments(_viewer, _owner, _repository, number, _filters),
    do:
      {:ok,
       %Fornacast.Page{
         entries: [%{issue_number: number}],
         total: 1,
         page: 1,
         per_page: 100
       }}
end

defmodule FornacastWeb.RepositoryCollaborationPageTestDecorator do
  def decorate(result) do
    FornacastWeb.RepositoryCollaborationPage.decorate(result,
      forge_issues: FornacastWeb.RepositoryCollaborationPageTestIssues
    )
  end
end

defmodule FornacastWeb.RepositoryCollaborationPageTestPulls do
  def list_pull_requests(_repository, _viewer, _filters),
    do: {:ok, %Fornacast.Page{entries: [%{id: 11}], total: 1, page: 1, per_page: 30}}

  def get_pull_request(_repository, number, _viewer),
    do: {:ok, %{id: 11, issue: %{number: number}}}

  def list_commits(_repository, _pull, _viewer, opts),
    do:
      {:ok,
       %Fornacast.Page{
         entries: [%{oid: "commit"}],
         total: 1,
         page: opts[:page],
         per_page: opts[:per_page]
       }}

  def changed_files(_repository, _pull, _viewer, opts),
    do:
      {:ok,
       %ForgePulls.ChangedFilePage{
         entries: [%{path: "lib/a.ex"}],
         total: 1,
         additions: 1,
         deletions: 0,
         page: opts[:page],
         per_page: opts[:per_page],
         truncated: false
       }}
end

defmodule FornacastWeb.RepositoryCollaborationPageTestHTML do
  use Phoenix.Component

  def repository(assigns) do
    ~H"""
    <section id="test-repository-render">{@result.kind}</section>
    """
  end
end

defmodule FornacastWeb.RepositoryCollaborationPageTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest, only: [build_conn: 0]

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.{RepositoryCollaborationPage, RepositoryPage, RepositoryWeb, RequestMetadata}

  @modules [
    git_core: FornacastWeb.RepositoryCollaborationPageTestGit,
    forge_issues: FornacastWeb.RepositoryCollaborationPageTestIssues,
    forge_pulls: FornacastWeb.RepositoryCollaborationPageTestPulls
  ]

  setup do
    Process.delete({FornacastWeb.RepositoryCollaborationPageTestIssues, :counts})
    Process.delete({FornacastWeb.RepositoryCollaborationPageTestIssues, :count_calls})
    :ok
  end

  test "repository collaboration composition exposes all six typed page kinds and counts" do
    repository = repository()
    owner = owner()
    viewer = owner

    assert {:ok, %RepositoryPage.Result{kind: :issues, content: %{issues: issues}} = result} =
             RepositoryCollaborationPage.issues(
               repository,
               owner,
               viewer,
               %{state: "open"},
               @modules
             )

    assert %Fornacast.Page{total: 1} = issues
    assert result.chrome.collaboration_counts == %{issues: 4, pull_requests: 2}

    assert {:ok,
            %RepositoryPage.Result{
              kind: :issue,
              content: %{issue: %{number: 7}, comments: %Fornacast.Page{total: 1}}
            }} =
             RepositoryCollaborationPage.issue(repository, owner, viewer, 7, @modules)

    assert {:ok,
            %RepositoryPage.Result{kind: :pulls, content: %{pulls: %Fornacast.Page{total: 1}}}} =
             RepositoryCollaborationPage.pulls(
               repository,
               owner,
               viewer,
               %{state: "open"},
               @modules
             )

    assert {:ok,
            %RepositoryPage.Result{
              kind: :pull,
              content: %{pull: %{id: 11}, comments: %Fornacast.Page{total: 1}}
            }} =
             RepositoryCollaborationPage.pull(repository, owner, viewer, 9, @modules)

    params = Map.new(@modules) |> Map.merge(%{page: 2, per_page: 25})

    assert {:ok,
            %RepositoryPage.Result{
              kind: :pull_commits,
              content: %{pull: %{id: 11}, commits: %Fornacast.Page{page: 2}}
            }} =
             RepositoryCollaborationPage.pull_commits(repository, owner, viewer, 9, params)

    assert {:ok,
            %RepositoryPage.Result{
              kind: :pull_files,
              content: %{pull: %{id: 11}, files: %ForgePulls.ChangedFilePage{page: 2}}
            }} =
             RepositoryCollaborationPage.pull_files(repository, owner, viewer, 9, params)
  end

  test "collaboration counts degrade to nil without failing the repository page" do
    Process.put(
      {FornacastWeb.RepositoryCollaborationPageTestIssues, :counts},
      {:error, :temporarily_unavailable}
    )

    assert {:ok, result} =
             RepositoryCollaborationPage.issues(repository(), owner(), nil, %{}, @modules)

    assert result.chrome.collaboration_counts == %{issues: nil, pull_requests: nil}

    conn =
      build_conn()
      |> put_private(
        :repository_collaboration_page,
        FornacastWeb.RepositoryCollaborationPageTestDecorator
      )

    assert RepositoryWeb.render(
             conn,
             result,
             FornacastWeb.RepositoryCollaborationPageTestHTML,
             :repository
           ).status == 200

    assert Process.get({FornacastWeb.RepositoryCollaborationPageTestIssues, :count_calls}) == 1
  end

  test "repository web renders safe components with private cache policy and stable errors" do
    assert {:ok, result} =
             RepositoryPage.collaboration(
               repository(),
               owner(),
               nil,
               :issues,
               %{},
               git_core: FornacastWeb.RepositoryCollaborationPageTestGit
             )

    result = put_in(result.chrome.collaboration_counts, %{issues: 0, pull_requests: 0})

    rendered =
      RepositoryWeb.render(
        build_conn(),
        result,
        FornacastWeb.RepositoryCollaborationPageTestHTML,
        :repository
      )

    assert rendered.status == 200
    assert rendered.resp_body =~ "id=\"test-repository-render\">issues</section>"
    assert get_resp_header(rendered, "cache-control") == ["private, no-store"]
    assert get_resp_header(rendered, "pragma") == ["no-cache"]

    for {reason, status} <- [
          {:not_found, 404},
          {:forbidden, 403},
          {:gone, 410},
          {{:validation, []}, 422},
          {:invalid_head, 422},
          {:invalid_base, 422},
          {:cross_repository_head, 422},
          {:head_equals_base, 422},
          {:ref_conflict, 409},
          {:head_changed, 409},
          {:conflict, 405},
          {:method_not_allowed, 405},
          {:merge_commits_disabled, 405},
          {{:unavailable, :scan_busy}, 503}
        ] do
      conn = RepositoryWeb.error(build_conn(), repository(), reason)
      assert conn.status == status
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      refute conn.resp_body =~ inspect(reason)
    end
  end

  test "request metadata contains only bounded non-sensitive values" do
    user_agent = String.duplicate("agent-", 100)

    conn =
      build_conn()
      |> Map.put(:remote_ip, {203, 0, 113, 9})
      |> put_resp_header("x-request-id", "req-safe")
      |> put_req_header("user-agent", user_agent)
      |> put_req_header("cookie", "session=secret")
      |> assign(:csrf_token, "csrf-secret")
      |> assign(:token, "pat-secret")
      |> assign(:request_body, "private body")

    metadata = RequestMetadata.from_conn(conn)

    assert metadata == %{
             request_id: "req-safe",
             ip_address: "203.0.113.9",
             user_agent: String.slice(user_agent, 0, 512)
           }

    assert Map.keys(metadata) |> Enum.sort() == [:ip_address, :request_id, :user_agent]
    refute inspect(metadata) =~ "secret"
    refute inspect(metadata) =~ "private body"
  end

  test "request metadata normalizes IPv6 and safely bounds UTF-8 user agents" do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      |> put_resp_header("x-request-id", "req-v6")
      |> put_req_header("user-agent", String.duplicate("界", 200))

    assert %{request_id: "req-v6", ip_address: "2001:db8::1", user_agent: bounded} =
             RequestMetadata.from_conn(conn)

    assert byte_size(bounded) <= 512
    assert String.valid?(bounded)
  end

  test "request metadata uses explicit request assignment and permits a missing user agent" do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_resp_header("x-request-id", "response-id")
      |> assign(:request_id, "assigned-id")

    assert RequestMetadata.from_conn(conn) == %{
             request_id: "assigned-id",
             ip_address: "127.0.0.1",
             user_agent: nil
           }
  end

  test "request metadata safely bounds client-influenced request IDs" do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_resp_header("x-request-id", String.duplicate("界", 100))

    assert %{request_id: request_id} = RequestMetadata.from_conn(conn)
    assert byte_size(request_id) <= 255
    assert String.valid?(request_id)
  end

  test "external request IDs require whole valid UTF-8 before deterministic derivation" do
    actor = owner()
    repository = repository()
    shared_prefix = String.duplicate("a", 20)

    invalid_headers = [shared_prefix <> <<0xFF>>, shared_prefix <> <<0xFE>>]

    extracted =
      Enum.map(invalid_headers, fn header ->
        refute String.valid?(header)

        build_conn()
        |> put_req_header("x-request-id", header)
        |> RequestMetadata.external_request_id()
      end)

    assert extracted == [nil, nil]

    assert [first_random, second_random] =
             Enum.map(extracted, fn request_id ->
               GitTransport.ReceivePack.http_operation_batch_id(
                 actor,
                 repository,
                 request_id
               )
             end)

    refute first_random == second_random

    invalid_twentieth_byte = String.duplicate("b", 19) <> <<0xFF>>
    assert byte_size(invalid_twentieth_byte) == 20

    assert is_nil(
             build_conn()
             |> put_req_header("x-request-id", invalid_twentieth_byte)
             |> RequestMetadata.external_request_id()
           )

    for byte_count <- [20, 200] do
      valid_header = String.duplicate("c", byte_count)

      assert valid_header ==
               build_conn()
               |> put_req_header("x-request-id", valid_header)
               |> RequestMetadata.external_request_id()

      assert GitTransport.ReceivePack.http_operation_batch_id(
               actor,
               repository,
               valid_header
             ) ==
               GitTransport.ReceivePack.http_operation_batch_id(
                 actor,
                 repository,
                 valid_header
               )
    end
  end

  defp owner do
    %User{id: 1, username: "alice", kind: :user, state: :active}
  end

  defp repository do
    %Repository{
      id: 2,
      owner_user_id: 1,
      name: "Demo",
      slug: "demo",
      visibility: :public,
      default_branch: "main",
      storage_path: "repositories/alice/demo.git"
    }
  end
end
