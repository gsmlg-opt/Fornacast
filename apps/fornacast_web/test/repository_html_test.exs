defmodule FornacastWeb.RepositoryMarkdownTest do
  use ExUnit.Case, async: true

  alias FornacastWeb.RepositoryMarkdown

  @moduletag :markdown

  test "README candidates retain their exact priority at root and below a directory" do
    assert RepositoryMarkdown.candidates("") == ["README.md", "README", "README.txt"]

    assert RepositoryMarkdown.candidates("docs") == [
             "docs/README.md",
             "docs/README",
             "docs/README.txt"
           ]
  end

  test "nested relative links preserve the full selected ref and percent-encode route pieces" do
    html =
      render(
        "[Guide](<../Guide one.md#intro>) [Local](#usage)",
        path: "docs/setup/README.md",
        owner: "team space",
        repository: "demo+repo",
        ref: "refs/heads/feature/a b"
      )

    assert html =~
             ~s(href="/team%20space/demo%2Brepo/src/refs/heads/feature/a%20b/docs/Guide%20one.md#intro")

    assert html =~ ~s(href="#usage")
  end

  test "relative raster images use raw while non-raster images become escaped linked alt text" do
    html =
      render(
        "![shot](images/pic.PNG) ![diagram & unsafe](images/arch.svg)",
        path: "docs/README.md"
      )

    assert html =~
             ~s(<img src="/alice/demo/raw/refs/heads/main/docs/images/pic.PNG" alt="shot">)

    assert html =~
             ~s(<a href="/alice/demo/raw/refs/heads/main/docs/images/arch.svg" rel="noopener noreferrer">diagram &amp; unsafe</a>)

    refute html =~ ~s(<img src="/alice/demo/raw/refs/heads/main/docs/images/arch.svg")
  end

  test "same-document anchors and allowed absolute schemes stay unchanged" do
    html =
      render("""
      [Anchor](#read-me)
      [HTTP](http://example.test/docs)
      [HTTPS](https://example.test/docs)
      [Mail](mailto:docs@example.test)
      """)

    assert html =~ ~s(href="#read-me")
    assert html =~ ~s(href="http://example.test/docs")
    assert html =~ ~s(href="https://example.test/docs")
    assert html =~ ~s(href="mailto:docs@example.test")
  end

  test "query-only references inherit the current nested README path" do
    html =
      render(
        "[query](?x=1) [query-fragment](?x=1#part)",
        path: "docs/setup/README.md"
      )

    assert html =~
             ~s(href="/alice/demo/src/refs/heads/main/docs/setup/README.md?x=1")

    assert html =~
             ~s(href="/alice/demo/src/refs/heads/main/docs/setup/README.md?x=1#part")

    refute html =~ "/docs/setup?x=1"
  end

  test "parent traversal and encoded parent traversal cannot escape repository root" do
    html = render("[plain](../../secret.md) [encoded](%2e%2e/%2e%2e/secret.md)")

    refute html =~ "/src/"
    refute html =~ "secret.md"
    assert html =~ ~s(href="")
  end

  test "unsupported schemes are removed and raw HTML is sanitized" do
    html =
      render("""
      [JS](javascript:alert(1))
      [File](file:///etc/passwd)
      ![Data](data:image/png;base64,AAAA)
      <script>alert("xss")</script>
      <img src=x onerror=alert(1)>
      """)

    refute html =~ "javascript:"
    refute html =~ "file:"
    refute html =~ "data:"
    refute html =~ "<script"
    refute html =~ "onerror"
  end

  test "plain README text is escaped and every render returns Phoenix-safe content" do
    safe =
      RepositoryMarkdown.render("<script>alert(1)</script>", context(path: "README.txt"))

    assert {:safe, _iodata} = safe

    html = safe |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>"
  end

  defp render(markdown, overrides \\ []) do
    markdown
    |> RepositoryMarkdown.render(context(overrides))
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp context(overrides) do
    Keyword.merge(
      [
        path: "README.md",
        owner: "alice",
        repository: "demo",
        ref: "refs/heads/main"
      ],
      overrides
    )
  end
end

defmodule FornacastWeb.RepositoryHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.User
  alias ForgeRepos.Repository
  alias FornacastWeb.{HTML, RepositoryHTML, RepositoryPage}

  test "code surface renders repository identity, selected full ref, exact counts, and only approved navigation" do
    html = render_result(code_result())

    assert html =~ "alice/demo"
    assert html =~ "public"
    assert html =~ "feature/forge"
    assert html =~ "Default branch: trunk"
    assert html =~ "Last pushed: 2025-07-16 12:00 UTC"
    assert html =~ "93 commits"
    assert html =~ "3 branches"
    assert html =~ "2 tags"

    [navigation] = Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, html)
    assert length(Regex.scan(~r/aria-current="page"/, navigation)) == 1

    assert html =~ "href=\"/alice/demo?ref=refs%2Fheads%2Ffeature%2Fforge"
    assert html =~ "href=\"/alice/demo/commits/refs/heads/feature/forge"
    assert html =~ "href=\"/alice/demo/branches"
    assert html =~ "href=\"/alice/demo/tags"

    refute html =~ ">Issues<"
    refute html =~ ">Pull Requests<"
    refute html =~ ">Actions<"
    refute html =~ ">Packages<"
    refute html =~ ">Projects<"
    refute html =~ ">Releases<"
    refute html =~ ">Wiki<"
    refute html =~ ">Star<"
    refute html =~ ">Fork<"
    refute html =~ ">Watch<"
    refute html =~ ">Activity<"
  end

  test "full refs remain canonical while slash and same-name branch/tag labels stay short" do
    html = render_result(code_result())

    assert html =~ "value=\"refs/heads/release\""
    assert html =~ "value=\"refs/tags/release\""
    assert html =~ "value=\"refs/heads/feature/forge\""
    assert html =~ ~r/>\s*release\s*<\/option>/
    assert html =~ ~r/>\s*feature\/forge\s*<\/option>/
    assert html =~ "<form action=\"/alice/demo\" method=\"get\""
    assert html =~ "name=\"ref\""
    assert html =~ "Switch ref"
    refute html =~ "onchange"
  end

  test "same-name tags select and link by their canonical full ref" do
    tag_snapshot = %GitCore.Snapshot{
      kind: :tag,
      ref: "refs/tags/release",
      oid: String.duplicate("b", 40)
    }

    result = put_in(code_result().chrome.snapshot, tag_snapshot)
    html = render_result(result)

    assert html =~ "href=\"/alice/demo?ref=refs%2Ftags%2Frelease"
    assert html =~ "href=\"/alice/demo/commits/refs/tags/release"
    assert html =~ ~r/<option[^>]+value="refs\/tags\/release"[^>]+selected/
    refute html =~ ~r/<option[^>]+value="refs\/heads\/release"[^>]+selected/
    assert html =~ ">release</span>"
  end

  test "literal plus signs remain percent-encoded in full refs and repository paths" do
    snapshot = %GitCore.Snapshot{
      kind: :branch,
      ref: "refs/heads/feature+c",
      oid: String.duplicate("d", 40)
    }

    result =
      %GitCore.Blob{
        name: "lib/a+b.ex",
        oid: String.duplicate("e", 40),
        size: 4,
        data: "safe",
        truncated: false,
        binary: false,
        non_utf8: false
      }
      |> blob_result()
      |> put_in([Access.key(:chrome), Access.key(:snapshot)], snapshot)

    html = render_result(result)

    assert html =~ "href=\"/alice/demo?ref=refs%2Fheads%2Ffeature%2Bc"

    assert html =~
             "href=\"/alice/demo/raw/refs/heads/feature%2Bc/lib/a%2Bb.ex"
  end

  test "truncated ref samples require a labeled exact full ref and link to complete ref pages" do
    result =
      update_in(code_result().chrome.ref_summary, fn summary ->
        %{summary | refs_truncated: true}
      end)

    html = render_result(result)

    assert html =~ "Exact full ref"
    assert html =~ "name=\"ref\""
    assert html =~ "value=\"refs/heads/feature/forge\""
    assert html =~ "href=\"/alice/demo/branches"
    assert html =~ "href=\"/alice/demo/tags"
    refute html =~ "<select"
  end

  test "code page maps commit-aware tree, safe README, partial analysis, and optional failures" do
    html = render_result(code_result())

    assert html =~ "feat: ship repository surface"
    assert html =~ "lib"
    assert html =~ "README.md"
    assert html =~ "href=\"/alice/demo/src/refs/heads/feature/forge/lib"
    assert html =~ "href=\"/alice/demo/src/refs/heads/feature/forge/README.md"
    assert html =~ "<strong>safe</strong>"
    assert html =~ "Partial language analysis"
    assert html =~ "2 files / 128 bytes scanned"
    assert html =~ "Size temporarily unavailable"
    assert html =~ "README"
    assert html =~ "data-language-bar"
    assert html =~ "repository-language-segment"
    assert html =~ "data-readme-jump"
    assert html =~ "Branch or tag"
    assert html =~ "Search code"

    assert html =~
             ~s(href="/alice/demo/search?ref=refs%2Fheads%2Ffeature%2Fforge&amp;scope=path")

    assert html =~ ~r/id="repository-clone-trigger"[^>]*>\s*Code\s*</s
    assert html =~ ~s(aria-label="Quick repository search")

    assert_ordered(html, [
      "data-repository-summary",
      "id=\"repository-ref-controls\"",
      "data-latest-commit",
      "data-file-tree",
      "data-readme"
    ])

    [sidebar] = Regex.run(~r/<aside\b.*?data-repository-sidebar.*?<\/aside>/s, html)
    assert sidebar =~ "Quick repository search"
    assert sidebar =~ "data-readme-jump"
    assert sidebar =~ "data-repository-languages"
  end

  test "commit links preserve selected ref context while snapshot-less pages use the default ref" do
    selected = code_result()
    oid = selected.content.commit_summary.latest.oid

    assert RepositoryHTML.commit_path(selected.chrome, oid) ==
             "/alice/demo/commit/#{oid}?ref=refs%2Fheads%2Ffeature%2Fforge"

    code = render_result(selected)

    assert code =~
             "href=\"/alice/demo/commit/#{oid}?ref=refs%2Fheads%2Ffeature%2Fforge"

    refs = render_result(refs_result())
    assert refs =~ "href=\"/alice/demo/commits/refs/heads/trunk"

    without_context =
      commit_result()
      |> put_in([Access.key(:chrome), Access.key(:snapshot)], nil)
      |> put_in([Access.key(:content), Access.key(:ref_context)], nil)

    assert RepositoryHTML.commit_path(without_context.chrome, oid) ==
             "/alice/demo/commit/#{oid}"

    commit = render_result(without_context)
    assert commit =~ "href=\"/alice/demo/commits/refs/heads/trunk"
  end

  test "every repository route marks exactly one correct navigation item active" do
    cases = [
      {"Code", code_result()},
      {"Code", tree_result()},
      {"Code",
       blob_result(%GitCore.Blob{
         name: "README.md",
         oid: String.duplicate("a", 40),
         size: 4,
         data: "safe",
         truncated: false,
         binary: false,
         non_utf8: false
       })},
      {"Code", search_result()},
      {"Commits", commits_result()},
      {"Commits", commit_result()},
      {"Branches", refs_result(:branch)},
      {"Tags", refs_result(:tag)}
    ]

    for {expected, result} <- cases do
      html = render_result(result)
      assert active_navigation_label(html) == expected
    end
  end

  test "blob page escapes text and exposes raw, binary, non-UTF-8, and truncated states" do
    text_html =
      blob_result(%GitCore.Blob{
        name: "unsafe.ex",
        oid: String.duplicate("a", 40),
        size: 17,
        data: "<script>alert(1)</script>",
        truncated: true,
        binary: false,
        non_utf8: false
      })
      |> render_result()

    assert text_html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute text_html =~ "<script>"
    assert text_html =~ "This file is truncated."
    assert text_html =~ "href=\"/alice/demo/raw/refs/heads/feature/forge/unsafe.ex"
    assert text_html =~ "data-copy-value=\"&lt;script&gt;alert(1)&lt;/script&gt;\""

    binary_html =
      blob_result(%GitCore.Blob{
        name: "logo.bin",
        oid: String.duplicate("b", 40),
        size: 2,
        data: <<0, 1>>,
        truncated: false,
        binary: true,
        non_utf8: false
      })
      |> render_result()

    assert binary_html =~ "Binary file not shown."
    assert binary_html =~ ~r/>\s*Raw\s*<\/a>/
    assert binary_html =~ "href=\"/alice/demo/raw/refs/heads/feature/forge/logo.bin"
    refute binary_html =~ "Copy file contents"

    [binary_viewer] =
      Regex.run(~r/<section\s+id="repository-blob".*?<\/section>/s, binary_html)

    refute binary_viewer =~ "data-copy-value"

    non_utf8_html =
      blob_result(%GitCore.Blob{
        name: "legacy.txt",
        oid: String.duplicate("c", 40),
        size: 1,
        data: <<255>>,
        truncated: false,
        binary: false,
        non_utf8: true
      })
      |> render_result()

    assert non_utf8_html =~ "Non-UTF-8 file not shown."
    assert non_utf8_html =~ ~r/>\s*Raw\s*<\/a>/
    assert non_utf8_html =~ "href=\"/alice/demo/raw/refs/heads/feature/forge/legacy.txt"

    [non_utf8_viewer] =
      Regex.run(~r/<section\s+id="repository-blob".*?<\/section>/s, non_utf8_html)

    refute non_utf8_viewer =~ "data-copy-value"
  end

  test "empty and missing-default states stay explicit and never invent repository content" do
    empty_html = render_result(empty_result(true))

    assert empty_html =~ "Empty repository"
    assert empty_html =~ "git branch -M trunk"
    assert empty_html =~ "git push -u origin trunk"

    [empty_navigation] =
      Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, empty_html)

    assert length(
             Regex.scan(
               ~r/<span class="rounded-full[^"]*">\s*0\s*<\/span>/,
               empty_navigation
             )
           ) == 3

    refute empty_html =~ "Repository files"
    refute empty_html =~ "Languages"
    refute empty_html =~ "README"

    reader_html = render_result(empty_result(false))
    refute reader_html =~ "git push -u origin trunk"

    missing_html = render_result(missing_default_result())
    assert missing_html =~ "Configured default ref is unavailable"
    assert missing_html =~ "refs/heads/trunk"
    assert missing_html =~ "feature/forge"
    assert missing_html =~ "release"
  end

  test "commit page maps structured DiffLine values without parsing patch text" do
    html = render_result(commit_result())

    assert html =~ "Ship bounded repository pages"
    assert html =~ "lib/forge.ex"
    assert html =~ "def repository"
    assert html =~ "old line"
    assert html =~ "Binary file changed."
    assert html =~ "Diff truncated."
    assert html =~ "Commit diff truncated."
    assert html =~ "bg-error/10 text-error"
    assert html =~ "bg-success/10 text-success"
    assert html =~ "bg-info/10 text-info"
    assert html =~ ">@</span>"
    assert html =~ ">-</span>"
    assert html =~ ">+</span>"
    assert html =~ "unchanged line"
    assert html =~ ">42</span>"
    assert html =~ ">43</span>"
    refute html =~ "UNPARSED PATCH SENTINEL"
  end

  test "commit diff accepts already-mapped DiffLine values" do
    result =
      update_in(commit_result().content.diff.files, fn [first | rest] ->
        [
          %{
            first
            | lines: [
                %{type: :deleted, old_line: 7, new_line: nil, content: "old mapped line"},
                %{type: :added, old_line: nil, new_line: 8, content: "new mapped line"}
              ]
          }
          | rest
        ]
      end)

    html = render_result(result)

    assert html =~ "old mapped line"
    assert html =~ "new mapped line"
    assert html =~ ">7</span>"
    assert html =~ ">8</span>"
  end

  test "commit-level truncation remains visible when no individual file is truncated" do
    result =
      update_in(commit_result().content.diff.files, fn files ->
        Enum.map(files, &%{&1 | truncated: false})
      end)

    html = render_result(result)

    assert html =~ "Commit diff truncated."
    assert html =~ "data-diff-truncated"
    refute html =~ "Diff truncated."
  end

  test "refs, commits, search, and tree pages render compact server-linked states" do
    refs = render_result(refs_result())
    assert refs =~ "Branches"
    assert refs =~ "refs/heads/feature/forge"
    assert refs =~ "href=\"/alice/demo?ref=refs%2Fheads%2Ffeature%2Fforge"
    assert refs =~ "href=\"/alice/demo/commits/refs/heads/trunk"

    paginated_refs =
      refs_result()
      |> put_in([Access.key(:content), Access.key(:page), Access.key(:total_pages)], 2)
      |> render_result()

    assert paginated_refs =~ "href=\"/alice/demo/branches?page=2"

    commits = render_result(commits_result())
    assert commits =~ "Ship bounded repository pages"

    assert commits =~
             "href=\"/alice/demo/commit/#{String.duplicate("d", 40)}?ref=refs%2Fheads%2Ffeature%2Fforge"

    assert commits =~
             "href=\"/alice/demo/commits/refs/heads/feature/forge?page=2"

    search = render_result(search_result())
    assert search =~ "Search repository"
    assert search =~ "name=\"q\""
    assert search =~ "name=\"scope\""
    assert search =~ "Search query"
    assert search =~ "Search scope"
    assert search =~ "lib/forge.ex"
    assert search =~ "Result limit reached"

    tree = render_result(tree_result())
    assert tree =~ "href=\"/alice/demo/src/refs/heads/feature/forge"
    assert tree =~ "href=\"/alice/demo/src/refs/heads/feature/forge/lib"
    assert tree =~ "Next"
  end

  test "server breadcrumbs and pagination preserve exact encoded nested paths" do
    result =
      tree_result()
      |> put_in([Access.key(:content), Access.key(:path)], "demo/a+b space")
      |> put_in([Access.key(:content), Access.key(:tree)], tree_page("demo/a+b space"))

    html = render_result(result)

    [breadcrumbs] =
      Regex.run(~r/<nav\b[^>]*data-server-breadcrumbs[^>]*>.*?<\/nav>/s, html)

    assert length(Regex.scan(~r/aria-hidden="true">\s*\/\s*<\/span>/, breadcrumbs)) == 2

    assert breadcrumbs =~
             "href=\"/alice/demo/src/refs/heads/feature/forge/demo"

    assert breadcrumbs =~ ~r/aria-current="page">\s*a\+b space\s*</

    assert html =~
             "href=\"/alice/demo/src/refs/heads/feature/forge/demo/a%2Bb%20space?page=2"
  end

  test "repository timestamps stay safe and compact for tree metadata" do
    assert RepositoryHTML.format_time(253_402_300_800) == "Unknown time"
    assert RepositoryHTML.relative_time(253_402_300_800) == "Unknown time"
    assert RepositoryHTML.relative_time(0) =~ ~r/^\d+y ago$/

    result =
      update_in(tree_result().content.tree.entries, fn entries ->
        Enum.map(entries, fn entry ->
          put_in(entry.latest_commit.author_time, 0)
        end)
      end)

    html = render_result(result)
    [tree] = Regex.run(~r/<section\b[^>]*id="repository-file-tree".*?<\/section>/s, html)

    assert tree =~ ~r/\d+y ago/
    refute tree =~ "UTC"
  end

  test "clone popover uses explicit URLs and trunk commands without the dependency main fallback" do
    html = render_result(empty_result(true))

    assert html =~ "https://forge.test/alice/demo.git"
    assert html =~ "ssh://git@forge.test/alice/demo.git"
    assert html =~ "git branch -M trunk"
    assert html =~ "git push -u origin trunk"
    refute html =~ "git push -u origin main"
    assert html =~ "role=\"status\""
    assert html =~ "aria-live=\"polite\""
    assert html =~ "data-copy-status"
  end

  test "repository shell accepts safe iodata and keeps anonymous and authenticated chrome distinct" do
    body = ["<section data-safe-fragment>", {:safe, "<strong>safe</strong>"}, "</section>"]

    anonymous =
      build_conn()
      |> HTML.repository_page("alice/demo", body)
      |> response_body()

    assert anonymous =~ "repository-shell"
    assert anonymous =~ "Fornacast"
    assert anonymous =~ "href=\"/login\""
    assert anonymous =~ "Theme"
    assert anonymous =~ "<strong>safe</strong>"
    refute anonymous =~ "Repository workbench"
    refute anonymous =~ "auth-shell"
    refute anonymous =~ "User Repos"
    refute anonymous =~ "Create new"
    refute anonymous =~ "Account menu"

    authenticated =
      build_conn()
      |> Plug.Conn.assign(:current_user, owner())
      |> HTML.repository_page("alice/demo", body)
      |> response_body()

    assert authenticated =~ "User Repos"
    assert authenticated =~ "Create new"
    assert authenticated =~ "Account menu"
    assert length(Regex.scan(~r/<main\b/, authenticated)) == 1
    refute authenticated =~ "Repository workbench"
    refute authenticated =~ "class=\"content-panel\""
  end

  test "repository shell accepts the actual rendered repository component as safe iodata" do
    rendered = RepositoryHTML.repository(%{result: code_result(), __changed__: nil})
    safe_body = Phoenix.HTML.Safe.to_iodata(rendered)

    anonymous =
      build_conn()
      |> HTML.repository_page("<unsafe>", safe_body)
      |> response_body()

    assert anonymous =~ "&lt;unsafe&gt; - Fornacast"
    assert anonymous =~ "data-repository-kind=\"code\""
    assert anonymous =~ "<strong>safe</strong>"
    refute anonymous =~ "&lt;article"

    [header] = Regex.run(~r/<header\b.*?<\/header>/s, anonymous)

    assert header =~ "Fornacast"
    assert header =~ "href=\"/login\""
    assert header =~ "Theme"
    refute anonymous =~ ">Issues<"
    refute anonymous =~ ">Pull Requests<"
    refute anonymous =~ "Profile"
    refute anonymous =~ "Logout"
  end

  test "released server-side navigation components replace local workarounds" do
    source =
      File.read!(Path.expand("../lib/fornacast_web/controllers/repository_html.ex", __DIR__))

    lock = File.read!(Path.expand("../../../mix.lock", __DIR__))

    assert lock =~ ~r/"phoenix_duskmoon".*"9\.9\.0"/
    assert source =~ "<.dm_breadcrumb"
    assert source =~ "<.dm_pagination"
    refute source =~ "WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#82"
    refute source =~ "WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#83"
  end

  test "repository assets retain responsive containment and load the package clipboard runtime" do
    css = File.read!(Path.expand("../assets/css/app.css", __DIR__))
    js = File.read!(Path.expand("../assets/js/app.js", __DIR__))

    assert css =~ ~s(@import "phoenix_duskmoon/components";)
    assert css =~ "WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#89"
    assert css =~ "TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#89"

    assert css =~
             ~s(@import "../../../../deps/phoenix_duskmoon/priv/static/assets/css/app.css";)

    assert css =~
             ~r/^\s*@import "\.\.\/\.\.\/\.\.\/\.\.\/deps\/phoenix_duskmoon\/priv\/static\/assets\/css\/app\.css";$/m

    assert css =~ "grid-template-columns: minmax(0, 1fr)"
    assert css =~ "@media (max-width: 1023px)"
    assert css =~ "@media (max-width: 767px)"
    assert css =~ "@media (max-width: 639px)"
    assert css =~ "@media (prefers-reduced-motion: reduce)"
    assert css =~ ".repository-table thead"
    assert css =~ "display: table-header-group"

    refute css =~
             ~r/(?:#(?:[0-9a-fA-F]{3}){1,2}|(?:bg|text|border)-(?:slate|gray|red|blue|green|purple)-\d{2,3})/

    assert js =~ ~s(import "phoenix_duskmoon";)
    refute js =~ "WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#80"
    refute js =~ "const writeClipboard"
    refute js =~ "document.createElement(\"textarea\")"
    refute js =~ "Copied to clipboard."
  end

  test "mobile repository ref controls reset desktop flex bases" do
    css = File.read!(Path.expand("../assets/css/app.css", __DIR__))

    assert css =~
             ~r/@media \(max-width: 639px\) \{.*?\[data-repository-page\] \.repository-ref-form,\s+\[data-repository-page\] \.repository-ref-form \.form-group \{\s+flex-basis: auto;\s+\}/s
  end

  test "clone popover restores trigger focus after Escape" do
    js = File.read!(Path.expand("../assets/js/app.js", __DIR__))

    assert js =~ "TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#92"
    assert js =~ "WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#92"
    assert js =~ ~s(event.key !== "Escape")
    assert js =~ ~s([data-clone-popover][open])
    assert js =~ "window.requestAnimationFrame"
    assert js =~ "trigger.focus()"
  end

  test "repository metadata and search snippets are escaped at the component boundary" do
    malicious_repository = %{
      repository()
      | name: "<script>alert('repository')</script>",
        description: "<img src=x onerror=alert('description')>"
    }

    code =
      code_result()
      |> put_in([Access.key(:chrome), Access.key(:repository)], malicious_repository)
      |> render_result()

    assert code =~ "&lt;script&gt;alert(&#39;repository&#39;)&lt;/script&gt;"
    assert code =~ "&lt;img src=x onerror=alert(&#39;description&#39;)&gt;"
    refute code =~ "<script>alert"
    refute code =~ "<img src=x"

    malicious_search =
      search_result()
      |> put_in(
        [Access.key(:content), Access.key(:results), Access.key(:results)],
        [
          %GitCore.SearchResult{
            path: "lib/<unsafe>.ex",
            line: 9,
            snippet: "<script>alert('match')</script>"
          }
        ]
      )
      |> render_result()

    assert malicious_search =~ "lib/&lt;unsafe&gt;.ex"
    assert malicious_search =~ "&lt;script&gt;alert(&#39;match&#39;)&lt;/script&gt;"
    refute malicious_search =~ "<script>alert"
  end

  test "README, language analysis, and disk failures degrade independently" do
    result =
      code_result()
      |> put_in([Access.key(:content), Access.key(:readme)], {:unavailable, :blob_busy})
      |> put_in([Access.key(:content), Access.key(:analysis)], {:unavailable, :scan_busy})
      |> put_in([Access.key(:content), Access.key(:disk_usage)], {:unavailable, :scan_timeout})

    html = render_result(result)

    assert html =~ "README temporarily unavailable"
    assert html =~ "Analysis temporarily unavailable"
    assert html =~ "Size temporarily unavailable"
    refute html =~ "<strong>safe</strong>"
  end

  test "search validation and no-result states retain the submitted ref, query, and scope" do
    invalid =
      search_result()
      |> put_in([Access.key(:content), Access.key(:validation_error)], :query_too_long)
      |> put_in([Access.key(:content), Access.key(:results)], nil)
      |> render_result()

    assert invalid =~ "Search query must be 200 characters or fewer."
    assert invalid =~ "value=\"repository\""
    assert invalid =~ "value=\"refs/heads/feature/forge\""
    assert invalid =~ ~r/<option[^>]+value="content"[^>]+selected/
    refute invalid =~ "data-repository-table"
    refute invalid =~ "data-repository-snippet"

    no_results =
      search_result()
      |> put_in(
        [Access.key(:content), Access.key(:results)],
        %GitCore.SearchResults{
          scope: :content,
          results: [],
          files_scanned: 4,
          bytes_scanned: 512,
          truncated_reasons: []
        }
      )
      |> render_result()

    assert no_results =~ "No results found."
    refute no_results =~ "Result limit reached"

    initial =
      search_result()
      |> put_in([Access.key(:content), Access.key(:query)], "")
      |> put_in([Access.key(:content), Access.key(:results)], nil)
      |> render_result()

    assert initial =~ "Enter a query to search this snapshot."
    refute initial =~ "data-repository-table"
    assert initial =~ "value=\"refs/heads/feature/forge\""
  end

  test "search result links preserve the full ref and encode unsafe path segments" do
    result =
      search_result()
      |> put_in(
        [Access.key(:content), Access.key(:results), Access.key(:results)],
        [%GitCore.SearchResult{path: "lib/unsafe file.ex", line: 4, snippet: "safe"}]
      )

    html = render_result(result)

    assert html =~
             "href=\"/alice/demo/src/refs/heads/feature/forge/lib/unsafe%20file.ex"
  end

  test "analysis states distinguish partial bytes from complete percentages and omit absent README" do
    partial = render_result(code_result())
    assert partial =~ "Partial language analysis"
    assert partial =~ "aria-label=\"Partial language breakdown by scanned bytes\""
    refute partial =~ "75.0%"
    refute partial =~ "25.0%"

    complete =
      code_result()
      |> put_in(
        [Access.key(:content), Access.key(:analysis), Access.elem(1), Access.key(:truncated)],
        false
      )
      |> put_in([Access.key(:content), Access.key(:readme)], nil)
      |> render_result()

    assert complete =~ ~r/>\s*Languages\s*<\/h2>/
    assert complete =~ "aria-label=\"Languages by bytes\""
    assert complete =~ "75.0%"
    assert complete =~ "25.0%"
    refute complete =~ "data-readme"
    refute complete =~ "data-readme-jump"
    refute complete =~ "README temporarily unavailable"
  end

  test "read-only empty repositories expose clone URLs without command slots" do
    html = render_result(empty_result(false))

    assert html =~ "Clone URL"
    assert html =~ "https://forge.test/alice/demo.git"
    refute html =~ "git init"
    refute html =~ "git remote add"
    refute html =~ "git branch -M"
    refute html =~ "git push"
  end

  test "repository pages emit stable responsive and QA markers" do
    code = render_result(code_result())

    blob =
      render_result(
        blob_result(%GitCore.Blob{
          name: "README.md",
          oid: String.duplicate("a", 40),
          size: 4,
          data: "safe",
          truncated: false,
          binary: false,
          non_utf8: false
        })
      )

    commit = render_result(commit_result())
    tree = render_result(tree_result())
    search = render_result(search_result())

    assert code =~
             "data-repository-responsive=\"sidebar-stack tabs-scroll toolbar-wrap\""

    for marker <- ~w(
      data-repository-page
      data-repository-header
      data-repository-tabs
      data-repository-toolbar
      data-repository-grid
      data-file-tree
      data-readme
      data-repository-sidebar
      data-clone-popover
      data-copy-status
    ) do
      assert code =~ marker
    end

    assert code =~ "data-repository-kind=\"code\""
    assert code =~ "data-clone-trigger"
    assert code =~ "data-clone-box"
    assert blob =~ "data-blob-viewer"
    assert commit =~ "data-commit-diff"
    assert tree =~ "data-server-breadcrumbs"
    assert tree =~ "data-server-pagination"
    assert search =~ "data-search-form"
    assert search =~ "data-repository-table"
    assert search =~ "data-repository-snippet"
  end

  defp render_result(result) do
    render_component(&RepositoryHTML.repository/1, result: result)
  end

  defp response_body(%Plug.Conn{resp_body: body}), do: IO.iodata_to_binary(body)

  defp active_navigation_label(html) do
    [navigation] = Regex.run(~r/<nav\b[^>]*id="repository-navigation".*?<\/nav>/s, html)
    assert length(Regex.scan(~r/aria-current="page"/, navigation)) == 1

    [_, active] =
      Regex.run(
        ~r/<a\b[^>]*aria-current="page"[^>]*>.*?<span class="whitespace-nowrap">\s*([^<]+?)\s*<\/span>/s,
        navigation
      )

    String.trim(active)
  end

  defp assert_ordered(html, markers) do
    positions =
      Enum.map(markers, fn marker ->
        {position, _length} = :binary.match(html, marker)
        position
      end)

    assert positions == Enum.sort(positions)
  end

  defp build_conn do
    Plug.Test.conn(:get, "/alice/demo")
  end

  defp owner do
    %User{
      id: 1,
      username: "alice",
      email: "alice@example.test",
      display_name: "Alice",
      kind: :user,
      role: :user,
      state: :active
    }
  end

  defp repository do
    %Repository{
      id: 7,
      owner_user_id: 1,
      slug: "demo",
      name: "demo",
      description: "A bounded, self-hosted forge.",
      visibility: :public,
      storage_path: "alice/demo.git",
      default_branch: "trunk",
      last_pushed_at: ~U[2025-07-16 12:00:00Z]
    }
  end

  defp ref_summary(refs_truncated \\ false) do
    %GitCore.RefSummary{
      branch_count: 3,
      tag_count: 2,
      branches: [
        ref("refs/heads/feature/forge", :branch, "feature/forge"),
        ref("refs/heads/release", :branch, "release"),
        ref("refs/heads/trunk", :branch, "trunk")
      ],
      tags: [
        ref("refs/tags/release", :tag, "release"),
        ref("refs/tags/v1.0", :tag, "v1.0")
      ],
      refs_truncated: refs_truncated
    }
  end

  defp ref(name, kind, display_name) do
    %GitCore.Ref{
      name: name,
      kind: kind,
      target: String.duplicate(if(kind == :branch, do: "a", else: "b"), 40),
      display_name: display_name
    }
  end

  defp snapshot do
    %GitCore.Snapshot{
      kind: :branch,
      ref: "refs/heads/feature/forge",
      oid: String.duplicate("a", 40)
    }
  end

  defp commit(title \\ "feat: ship repository surface") do
    %GitCore.Commit{
      oid: String.duplicate("d", 40),
      title: title,
      message: title <> "\n\nBounded and coherent.",
      author_name: "Alice",
      author_email: "alice@example.test",
      author_time: 1_752_710_400,
      committer_name: "Alice",
      committer_email: "alice@example.test",
      committer_time: 1_752_710_400,
      parents: [String.duplicate("c", 40)]
    }
  end

  defp tree_page(path \\ "") do
    %GitCore.TreePage{
      entries: [
        %GitCore.TreeHistoryEntry{
          name: "lib",
          kind: :tree,
          mode: "040000",
          oid: String.duplicate("1", 40),
          latest_commit: commit("refactor: bound repository reads")
        },
        %GitCore.TreeHistoryEntry{
          name: "README.md",
          kind: :blob,
          mode: "100644",
          oid: String.duplicate("2", 40),
          latest_commit: commit("docs: explain the forge")
        }
      ],
      total_entries: if(path == "", do: 102, else: 2),
      page: 1,
      per_page: 100,
      total_pages: 2
    }
  end

  defp chrome(summary \\ ref_summary(), selected \\ snapshot()) do
    %RepositoryPage.Chrome{
      owner: owner(),
      repository: repository(),
      viewer: owner(),
      ref_summary: summary,
      snapshot: selected,
      clone: %RepositoryPage.Clone{
        https_url: "https://forge.test/alice/demo.git",
        ssh_url: "ssh://git@forge.test/alice/demo.git",
        push_commands: [
          "git init",
          "git remote add origin ssh://git@forge.test/alice/demo.git",
          "git branch -M trunk",
          "git push -u origin trunk"
        ]
      }
    }
  end

  defp code_result do
    %RepositoryPage.Result{
      kind: :code,
      chrome: chrome(),
      content: %RepositoryPage.Code{
        commit_summary: %GitCore.CommitSummary{count: 93, latest: commit()},
        tree: tree_page(),
        readme:
          {:ok,
           %{
             path: "README.md",
             blob: %GitCore.Blob{
               name: "README.md",
               oid: String.duplicate("3", 40),
               size: 14,
               data: "**safe**",
               truncated: false,
               binary: false,
               non_utf8: false
             },
             html: {:safe, "<p><strong>safe</strong></p>"}
           }},
        analysis:
          {:ok,
           %GitCore.RepositoryAnalysis{
             languages: [
               %GitCore.LanguageStat{language: "Elixir", bytes: 96},
               %GitCore.LanguageStat{language: "Other", bytes: 32}
             ],
             total_bytes: 128,
             files_scanned: 2,
             bytes_scanned: 128,
             truncated: true
           }},
        disk_usage: {:unavailable, %GitCore.Error{kind: :scan_timeout, operation: :disk}}
      }
    }
  end

  defp blob_result(blob) do
    %RepositoryPage.Result{
      kind: :blob,
      chrome: chrome(),
      content: %RepositoryPage.Blob{path: blob.name, blob: blob}
    }
  end

  defp empty_result(write_access) do
    %RepositoryPage.Result{
      kind: :empty,
      chrome:
        chrome(
          %GitCore.RefSummary{
            branch_count: 0,
            tag_count: 0,
            branches: [],
            tags: [],
            refs_truncated: false
          },
          nil
        ),
      content: %RepositoryPage.Empty{write_access: write_access, disk_usage: {:ok, 256}}
    }
  end

  defp missing_default_result do
    %RepositoryPage.Result{
      kind: :missing_default,
      chrome: chrome(ref_summary(), nil),
      content: %RepositoryPage.MissingDefault{configured_ref: "refs/heads/trunk"}
    }
  end

  defp commit_result do
    %RepositoryPage.Result{
      kind: :commit,
      chrome: chrome(),
      content: %RepositoryPage.Commit{
        commit: commit("Ship bounded repository pages"),
        ref_context: snapshot(),
        diff: %GitCore.CommitDiff{
          patch: "UNPARSED PATCH SENTINEL",
          truncated: true,
          changed_files: 2,
          additions: 1,
          deletions: 1,
          files: [
            %GitCore.DiffFile{
              path: "lib/forge.ex",
              status: :modified,
              old_oid: String.duplicate("1", 40),
              new_oid: String.duplicate("2", 40),
              binary: false,
              additions: 1,
              deletions: 1,
              truncated: true,
              lines: [
                %GitCore.DiffLine{
                  type: :hunk,
                  old_line: 40,
                  new_line: 40,
                  content: "@@ -40 +40 @@"
                },
                %GitCore.DiffLine{
                  type: :context,
                  old_line: 41,
                  new_line: 41,
                  content: "unchanged line"
                },
                %GitCore.DiffLine{type: :deleted, old_line: 42, content: "old line"},
                %GitCore.DiffLine{type: :added, new_line: 43, content: "def repository"}
              ]
            },
            %GitCore.DiffFile{
              path: "priv/logo.bin",
              status: :modified,
              old_oid: String.duplicate("3", 40),
              new_oid: String.duplicate("4", 40),
              binary: true,
              additions: 0,
              deletions: 0,
              truncated: false,
              lines: []
            }
          ]
        }
      }
    }
  end

  defp refs_result(kind \\ :branch) do
    refs = if kind == :branch, do: ref_summary().branches, else: ref_summary().tags

    %RepositoryPage.Result{
      kind: :refs,
      chrome: chrome(ref_summary(), nil),
      content: %RepositoryPage.Refs{
        kind: kind,
        page: %GitCore.RefPage{
          refs: refs,
          total: length(refs),
          page: 1,
          per_page: 100,
          total_pages: 1
        }
      }
    }
  end

  defp commits_result do
    %RepositoryPage.Result{
      kind: :commits,
      chrome: chrome(),
      content: %RepositoryPage.Commits{
        page: %GitCore.CommitPage{
          commits: [commit("Ship bounded repository pages")],
          total: 51,
          page: 1,
          per_page: 50,
          total_pages: 2
        }
      }
    }
  end

  defp search_result do
    %RepositoryPage.Result{
      kind: :search,
      chrome: chrome(),
      content: %RepositoryPage.Search{
        query: "repository",
        scope: :content,
        validation_error: nil,
        results: %GitCore.SearchResults{
          scope: :content,
          results: [
            %GitCore.SearchResult{path: "lib/forge.ex", line: 12, snippet: "def repository"}
          ],
          files_scanned: 2,
          bytes_scanned: 128,
          truncated_reasons: [:result_limit]
        }
      }
    }
  end

  defp tree_result do
    %RepositoryPage.Result{
      kind: :tree,
      chrome: chrome(),
      content: %RepositoryPage.Tree{path: "lib", tree: tree_page("lib")}
    }
  end
end
