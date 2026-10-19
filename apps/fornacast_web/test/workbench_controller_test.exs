defmodule FornacastWeb.WorkbenchControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForgeAccounts.User
  alias ForgeIssues.Issue
  alias ForgeRepos.{Collaborator, Repository}
  alias Fornacast.Repo

  @endpoint FornacastWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fornacast.Setup.force_initialized!()
    on_exit(&Fornacast.Setup.reset!/0)

    %{actor: user_fixture(), outsider: user_fixture()}
  end

  test "lists readable issues without leaking another user's private repository", c do
    own = repository_fixture(c.actor)
    public = repository_fixture(c.outsider, visibility: :public)
    private = repository_fixture(c.outsider)
    own_issue = issue_fixture(own, c.actor, "Owned issue")
    public_issue = issue_fixture(public, c.outsider, "Public issue")
    issue_fixture(private, c.outsider, "Secret issue")

    conn = request_conn(c.actor) |> get("/issues")
    html = html_response(conn, 200)

    assert html =~ "Owned issue"
    assert html =~ "Public issue"
    assert html =~ ~s(href="/#{c.actor.username}/#{own.slug}/issues/#{own_issue.number}")
    assert html =~ ~s(href="/#{c.outsider.username}/#{public.slug}/issues/#{public_issue.number}")
    refute html =~ "Secret issue"
    refute html =~ private.slug
    refute html =~ "not wired"
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "read collaborators and organization members see private work", c do
    shared = repository_fixture(c.outsider)
    Repo.insert!(%Collaborator{repository_id: shared.id, user_id: c.actor.id, role: :read})
    issue_fixture(shared, c.outsider, "Collaborator issue")

    assert {:ok, organization} =
             ForgeAccounts.create_organization(c.outsider, %{username: unique("workbench-org")})

    assert {:ok, _} = ForgeAccounts.add_organization_member(organization, c.actor)
    org_repository = repository_fixture(organization)
    issue_fixture(org_repository, c.outsider, "Organization issue")

    html = request_conn(c.actor) |> get("/issues") |> html_response(200)
    assert html =~ "Collaborator issue"
    assert html =~ "Organization issue"
  end

  test "hides importing, deleted and disabled issue repositories", c do
    for attrs <- [
          [lifecycle: :importing],
          [deleted_at: DateTime.utc_now(:second)],
          [has_issues: false]
        ] do
      repository = repository_fixture(c.actor, attrs)
      issue_fixture(repository, c.actor, "Hidden #{repository.slug}")
    end

    html = request_conn(c.actor) |> get("/issues") |> html_response(200)
    refute html =~ "Hidden "
    assert html =~ "No issues"
  end

  test "separates ordinary issues and pull requests with real detail links", c do
    repository = repository_fixture(c.actor)
    issue_fixture(repository, c.actor, "Ordinary issue")
    pull = issue_fixture(repository, c.actor, "Actual pull request", kind: :pull_request)

    issues = request_conn(c.actor) |> get("/issues") |> html_response(200)
    pulls = request_conn(c.actor) |> get("/pulls") |> html_response(200)

    assert issues =~ "Ordinary issue"
    refute issues =~ "Actual pull request"
    assert pulls =~ "Actual pull request"
    refute pulls =~ "Ordinary issue"
    assert pulls =~ ~s(href="/#{c.actor.username}/#{repository.slug}/pulls/#{pull.number}")
    refute pulls =~ "not wired"
  end

  test "state filtering and pagination apply independently to both workbenches", c do
    repository = repository_fixture(c.actor)

    for {path, kind} <- [{"/issues", :issue}, {"/pulls", :pull_request}] do
      first = issue_fixture(repository, c.actor, "First #{kind}", kind: kind)
      second = issue_fixture(repository, c.actor, "Second #{kind}", kind: kind)
      closed = issue_fixture(repository, c.actor, "Closed #{kind}", kind: kind, state: :closed)

      open_html = request_conn(c.actor) |> get(path, %{per_page: 1}) |> html_response(200)
      assert open_html =~ second.title
      refute open_html =~ first.title
      refute open_html =~ closed.title
      assert open_html =~ "page=2"
      assert open_html =~ "per_page=1"

      next_html =
        request_conn(c.actor) |> get(path, %{page: 2, per_page: 1}) |> html_response(200)

      assert next_html =~ first.title
      refute next_html =~ second.title

      closed_html = request_conn(c.actor) |> get(path, %{state: "closed"}) |> html_response(200)
      assert closed_html =~ closed.title
      refute closed_html =~ first.title

      all_html = request_conn(c.actor) |> get(path, %{state: "all"}) |> html_response(200)
      assert all_html =~ first.title
      assert all_html =~ second.title
      assert all_html =~ closed.title
    end
  end

  test "rejects invalid filters and requires authentication", c do
    for path <- ["/issues", "/pulls"] do
      assert request_conn(nil) |> get(path) |> redirected_to() == "/login"

      for filters <- [%{state: "bogus"}, %{page: "0"}, %{per_page: "101"}, %{state: ["open"]}] do
        assert request_conn(c.actor) |> get(path, filters) |> html_response(400)
      end
    end
  end

  defp request_conn(actor) do
    build_conn()
    |> Plug.Test.init_test_session(if(actor, do: [user_id: actor.id], else: []))
  end

  defp user_fixture do
    username = unique("workbench-user")

    Repo.insert!(%User{
      username: username,
      email: "#{username}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp repository_fixture(owner, attrs \\ []) do
    slug = unique("workbench-repo")

    %Repository{
      owner_user_id: owner.id,
      slug: slug,
      name: slug,
      storage_path: "workbench/#{slug}",
      visibility: :private
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp issue_fixture(repository, author, title, attrs \\ []) do
    issue =
      %Issue{
        repository_id: repository.id,
        number: System.unique_integer([:positive]),
        author_user_id: author.id,
        title: title,
        kind: :issue
      }
      |> struct!(attrs)
      |> Repo.insert!()

    if issue.kind == :pull_request do
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: repository.id,
        head_repository_id: repository.id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: String.duplicate("a", 40),
        base_sha: String.duplicate("b", 40)
      })
    end

    issue
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
