defmodule FornacastWeb.ReleaseHTMLTest do
  use ExUnit.Case, async: true

  alias ForgeAccounts.User
  alias ForgeReleases.Release
  alias ForgeRepos.Repository
  alias Fornacast.Page
  alias FornacastWeb.{ReleaseHTML, RepositoryHTML, RepositoryPage}

  test "index is a dense DuskMoon release list with one primary action" do
    release = release()

    html =
      :releases
      |> result(%{
        releases: %Page{entries: [release], total: 1, page: 1, per_page: 30},
        can_create: true
      })
      |> render(:index)

    assert html =~ "data-releases-page"
    assert html =~ "data-release-row"
    assert html =~ "Version 1"
    assert html =~ "v1.0.0"
    assert html =~ "Published"
    assert html =~ "el-dm-button"
    assert html =~ "Create release"

    [navigation] =
      Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, html)

    [_, active_label] =
      Regex.run(
        ~r/<a\b[^>]*aria-current="page"[^>]*>.*?<span class="whitespace-nowrap">\s*([^<]+?)\s*<\/span>/s,
        navigation
      )

    assert String.trim(active_label) == "Releases"
    assert navigation =~ ~s(href="/alice/demo/releases")
    refute html =~ ~r/(bg|text)-(red|blue|gray|slate)-[0-9]+/
  end

  test "repository release path is canonical" do
    assert :releases |> result(%{}) |> then(&RepositoryHTML.releases_path(&1.chrome)) ==
             "/alice/demo/releases"
  end

  test "detail renders supported metadata, sanitized markdown, and no assets" do
    html =
      :release
      |> result(%{release: release()})
      |> render(:show)

    assert html =~ "data-release-page"
    assert html =~ "Version 1"
    assert html =~ "Release notes"
    refute html =~ "<script>"
    assert html =~ "Edit release"
    assert html =~ "Delete release"
    refute html =~ "Upload asset"
    refute html =~ "Release assets"
  end

  test "new and edit forms use DuskMoon fields for every supported mutation field" do
    for {template, kind, release} <- [
          {:new, :release_new, nil},
          {:edit, :release_edit, release()}
        ] do
      html =
        kind
        |> result(%{
          release: release,
          values: values(release),
          errors: [%{resource: "Release", field: "name", code: :invalid}]
        })
        |> render(template)

      assert html =~ ~s(name="release[tag_name]")
      assert html =~ ~s(name="release[name]")
      assert html =~ ~s(name="release[body]")
      assert html =~ ~s(name="release[target_commitish]")
      assert html =~ ~s(name="release[draft]")
      assert html =~ ~s(name="release[prerelease]")
      assert html =~ "Name is invalid"
      assert html =~ ~s(name="_csrf_token")
    end
  end

  defp render(result, template) do
    template
    |> then(&apply(ReleaseHTML, &1, [%{result: result, __changed__: nil}]))
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp result(kind, content) do
    owner = %User{id: 1, username: "alice", kind: :user, state: :active}

    repository = %Repository{
      id: 2,
      owner_user_id: owner.id,
      name: "Demo",
      slug: "demo",
      visibility: :public,
      default_branch: "main"
    }

    %RepositoryPage.Result{
      kind: kind,
      chrome: %RepositoryPage.Chrome{
        owner: owner,
        repository: repository,
        viewer: owner,
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

  defp release do
    %Release{
      id: 4,
      repository_id: 2,
      tag_name: "v1.0.0",
      name: "Version 1",
      body: "Release notes <script>unsafe()</script>",
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

  defp values(nil), do: %{}

  defp values(release) do
    %{
      "tag_name" => release.tag_name,
      "name" => release.name,
      "body" => release.body,
      "target_commitish" => release.target_commitish,
      "draft" => release.draft,
      "prerelease" => release.prerelease
    }
  end
end
