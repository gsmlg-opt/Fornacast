defmodule FornacastWeb.ReleaseControllerTestPage do
  alias FornacastWeb.RepositoryPage

  def reset, do: Process.put({__MODULE__, :calls}, [])
  def calls, do: Process.get({__MODULE__, :calls}, [])

  def releases(repository, owner, viewer, filters, opts) do
    record(:releases, [repository, owner, viewer, filters, opts])

    {:ok,
     result(repository, owner, viewer, :releases, %{
       releases: %Fornacast.Page{entries: [release(repository)], total: 1, page: 1, per_page: 30},
       can_create: not is_nil(viewer)
     })}
  end

  def release(repository, owner, viewer, id, opts) do
    record(:release, [repository, owner, viewer, id, opts])
    {:ok, result(repository, owner, viewer, :release, %{release: release(repository, id)})}
  end

  def release_by_tag(repository, owner, viewer, tag, opts) do
    record(:release_by_tag, [repository, owner, viewer, tag, opts])

    release = %{release(repository) | tag_name: tag}
    {:ok, result(repository, owner, viewer, :release, %{release: release})}
  end

  def release_form(repository, owner, viewer, mode, values, errors, opts) do
    record(:release_form, [repository, owner, viewer, mode, values, errors, opts])

    {kind, release} =
      case mode do
        :new -> {:release_new, nil}
        {:edit, id} -> {:release_edit, release(repository, id)}
      end

    {:ok,
     result(repository, owner, viewer, kind, %{
       release: release,
       values: values,
       errors: errors
     })}
  end

  def decorate(result), do: result

  def release(repository, id \\ 7) do
    %ForgeReleases.Release{
      id: id,
      repository_id: repository.id,
      tag_name: "v1.0.0",
      name: "Version 1",
      body: "Release notes",
      draft: false,
      prerelease: false,
      target_commitish: "main",
      published_at: ~U[2026-09-05 08:00:00Z],
      inserted_at: ~U[2026-09-05 07:00:00Z],
      updated_at: ~U[2026-09-05 08:00:00Z],
      author: %{username: "alice"},
      capabilities: %{can_edit: true, can_delete: true}
    }
  end

  defp result(repository, owner, viewer, kind, content) do
    %RepositoryPage.Result{
      kind: kind,
      chrome: %RepositoryPage.Chrome{
        owner: owner,
        repository: repository,
        viewer: viewer,
        ref_summary: %GitCore.RefSummary{
          branch_count: 1,
          tag_count: 1,
          branches: [],
          tags: [],
          refs_truncated: false
        },
        snapshot: nil,
        clone: %RepositoryPage.Clone{https_url: "https://forge.test/alice/demo.git"},
        collaboration_counts: %{issues: 0, pull_requests: 0}
      },
      content: content
    }
  end

  defp record(operation, args),
    do: Process.put({__MODULE__, :calls}, calls() ++ [{operation, args}])
end

defmodule FornacastWeb.ReleaseControllerTestReleases do
  alias FornacastWeb.ReleaseControllerTestPage

  def reset do
    Process.put({__MODULE__, :calls}, [])
    Process.put({__MODULE__, :response}, nil)
  end

  def calls, do: Process.get({__MODULE__, :calls}, [])
  def respond(response), do: Process.put({__MODULE__, :response}, response)

  def create(actor, owner, repository, attrs, metadata) do
    reply(:create, [actor, owner, repository, attrs, metadata], fn ->
      {:ok, ReleaseControllerTestPage.release(%ForgeRepos.Repository{id: 3}, 11)}
    end)
  end

  def update(actor, owner, repository, id, attrs, metadata) do
    reply(:update, [actor, owner, repository, id, attrs, metadata], fn ->
      {:ok,
       %{
         ReleaseControllerTestPage.release(%ForgeRepos.Repository{id: 3}, id)
         | name: attrs["name"]
       }}
    end)
  end

  def delete(actor, owner, repository, id, metadata) do
    reply(:delete, [actor, owner, repository, id, metadata], fn -> :ok end)
  end

  defp reply(operation, args, fallback) do
    Process.put({__MODULE__, :calls}, calls() ++ [{operation, args}])
    Process.get({__MODULE__, :response}) || fallback.()
  end
end

defmodule FornacastWeb.ReleaseControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.ReleaseControllerTestPage, as: TestPage
  alias FornacastWeb.ReleaseControllerTestReleases, as: TestReleases

  @endpoint FornacastWeb.Endpoint

  setup do
    reset_database!()
    Fornacast.Setup.force_initialized!()
    TestPage.reset()
    TestReleases.reset()

    alice = insert_user!("alice")
    public = insert_repository!(alice, "public", :public)
    private = insert_repository!(alice, "private", :private)

    on_exit(&Fornacast.Setup.reset!/0)
    %{alice: alice, public: public, private: private}
  end

  test "anonymous repository readers list and show published releases" do
    index = request_conn() |> get("/alice/public/releases")
    assert html_response(index, 200) =~ "data-releases-page"
    assert index.resp_body =~ "Version 1"

    show = request_conn() |> get("/alice/public/releases/7")
    assert html_response(show, 200) =~ "data-release-page"
    assert show.resp_body =~ "Release notes"

    assert [
             {:releases, [repository, owner, nil, %{page: 1, per_page: 30}, []]},
             {:release, [repository, owner, nil, 7, []]}
           ] = TestPage.calls()

    assert_private_no_store(index)
    assert_private_no_store(show)
  end

  test "canonical tag route decodes an encoded slash" do
    conn = request_conn() |> get("/alice/public/releases/tag/release%2Fv1")

    assert html_response(conn, 200) =~ "data-release-page"
    assert conn.resp_body =~ "release/v1"
    assert [{:release_by_tag, [_repository, _owner, nil, "release/v1", []]}] = TestPage.calls()
    assert_private_no_store(conn)
  end

  test "private repositories remain masked and mutation forms require sign-in" do
    assert (request_conn() |> get("/alice/private/releases")).status == 404

    new = request_conn() |> get("/alice/public/releases/new")
    edit = request_conn() |> get("/alice/public/releases/7/edit")

    assert redirected_to(new) ==
             "/login?return_to=" <> URI.encode_www_form("/alice/public/releases/new")

    assert redirected_to(edit) ==
             "/login?return_to=" <> URI.encode_www_form("/alice/public/releases/7/edit")
  end

  test "authenticated forms submit supported metadata and destructive delete", %{alice: alice} do
    form = request_conn(alice) |> get("/alice/public/releases/new")
    assert html_response(form, 200) =~ ~s(name="release[tag_name]")
    assert form.resp_body =~ ~s(name="_csrf_token")

    created =
      submit_with_csrf(
        alice,
        "/alice/public/releases/new",
        :post,
        "/alice/public/releases",
        %{
          "release" => %{
            "tag_name" => "v1.0.0",
            "name" => "Version 1",
            "body" => "Notes",
            "target_commitish" => "main",
            "draft" => "false",
            "prerelease" => "true"
          }
        }
      )

    assert redirected_to(created) == "/alice/public/releases/11"

    assert [{:create, [^alice, "alice", "public", attrs, metadata]}] =
             TestReleases.calls()

    assert attrs == %{
             "tag_name" => "v1.0.0",
             "name" => "Version 1",
             "body" => "Notes",
             "target_commitish" => "main",
             "draft" => false,
             "prerelease" => true
           }

    assert Map.keys(metadata) |> Enum.sort() == [:ip_address, :request_id, :user_agent]

    TestReleases.reset()

    deleted =
      submit_with_csrf(
        alice,
        "/alice/public/releases/7/edit",
        :delete,
        "/alice/public/releases/7",
        %{}
      )

    assert redirected_to(deleted) == "/alice/public/releases"
    assert [{:delete, [^alice, "alice", "public", 7, _metadata]}] = TestReleases.calls()
  end

  test "authenticated edit submits supported release metadata", %{alice: alice} do
    updated =
      submit_with_csrf(
        alice,
        "/alice/public/releases/7/edit",
        :patch,
        "/alice/public/releases/7",
        %{
          "release" => %{
            "name" => "Updated release",
            "draft" => "true",
            "prerelease" => "false"
          }
        }
      )

    assert redirected_to(updated) == "/alice/public/releases/7"

    assert [{:update, [^alice, "alice", "public", 7, attrs, metadata]}] =
             TestReleases.calls()

    assert attrs == %{
             "name" => "Updated release",
             "draft" => true,
             "prerelease" => false
           }

    assert Map.keys(metadata) |> Enum.sort() == [:ip_address, :request_id, :user_agent]
  end

  test "validation re-renders retained release metadata", %{alice: alice} do
    TestReleases.respond(
      {:error, {:validation, [%{resource: "Release", field: "tag_name", code: :missing}]}}
    )

    conn =
      submit_with_csrf(
        alice,
        "/alice/public/releases/new",
        :post,
        "/alice/public/releases",
        %{"release" => %{"tag_name" => "missing", "name" => "Retained"}}
      )

    assert html_response(conn, 422) =~ "Retained"
    assert conn.resp_body =~ "Tag name is missing"
  end

  test "controller validation re-renders raw allowed values without a domain call", %{
    alice: alice
  } do
    created =
      submit_with_csrf(
        alice,
        "/alice/public/releases/new",
        :post,
        "/alice/public/releases",
        %{"release" => %{"name" => "Retained create", "draft" => "sometimes"}}
      )

    assert html_response(created, 422) =~ "Retained create"
    assert created.resp_body =~ "Draft is invalid"
    assert TestReleases.calls() == []

    TestPage.reset()

    updated =
      submit_with_csrf(
        alice,
        "/alice/public/releases/7/edit",
        :patch,
        "/alice/public/releases/7",
        %{"release" => %{"name" => "Retained update", "prerelease" => "sometimes"}}
      )

    assert html_response(updated, 422) =~ "Retained update"
    assert updated.resp_body =~ "Prerelease is invalid"
    assert TestReleases.calls() == []
  end

  defp request_conn(user \\ nil) do
    conn =
      build_conn()
      |> Plug.Conn.put_private(:repository_collaboration_page, TestPage)
      |> Plug.Conn.put_private(:forge_releases, TestReleases)

    if user, do: Plug.Test.init_test_session(conn, user_id: user.id), else: conn
  end

  defp submit_with_csrf(user, form_path, method, path, params) do
    form = request_conn(user) |> get(form_path)
    [_full, token] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, form.resp_body)

    conn =
      form
      |> recycle()
      |> Plug.Conn.put_private(:repository_collaboration_page, TestPage)
      |> Plug.Conn.put_private(:forge_releases, TestReleases)
      |> then(&%{&1 | private: Map.delete(&1.private, :plug_skip_csrf_protection)})

    params = Map.put(params, "_csrf_token", token)

    case method do
      :post -> post(conn, path, params)
      :patch -> patch(conn, path, params)
      :delete -> delete(conn, path, params)
    end
  end

  defp assert_private_no_store(conn) do
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(conn, "pragma") == ["no-cache"]
  end

  defp insert_user!(username) do
    Fornacast.Repo.insert!(%User{
      username: username,
      email: "#{username}@example.test",
      password_hash: "not-used",
      kind: :user,
      role: :user,
      state: :active
    })
  end

  defp insert_repository!(owner, slug, visibility) do
    Fornacast.Repo.insert!(%Repository{
      owner_user_id: owner.id,
      slug: slug,
      name: slug,
      visibility: visibility,
      storage_path: "@release-web/#{slug}.git",
      default_branch: "main"
    })
  end

  defp reset_database! do
    case Application.get_env(:fornacast, :database_adapter) do
      value when value in ["postgres", "postgresql"] ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fornacast.Repo)

      value when value in ["libsql", "turso"] ->
        Enum.each(
          [
            "releases",
            "audit_events",
            "repository_collaborators",
            "repositories",
            "organization_members",
            "api_keys",
            "ssh_keys",
            "users"
          ],
          &Ecto.Adapters.SQL.query!(Fornacast.Repo, "delete from #{&1}", [])
        )
    end
  end
end
