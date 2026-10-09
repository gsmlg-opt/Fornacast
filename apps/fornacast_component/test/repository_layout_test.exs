defmodule FornacastComponent.RepositoryLayoutTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import FornacastComponent.RepositoryLayout

  test "renders a shared frame from plain presentation data and preserves distinct title links" do
    document =
      render_component(&fc_repository_frame/1, %{
        view: view(),
        inner_block: [%{inner_block: fn _, _ -> "Prepared page content" end}]
      })
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(LazyHTML.query(document, "article"), "data-repository-kind") ==
             ["blob"]

    assert LazyHTML.attribute(LazyHTML.query(document, "h1 a"), "href") ==
             ["/gsmlg-opt", "/gsmlg-opt/agent-note"]

    assert Enum.map(LazyHTML.query(document, "h1 a"), &LazyHTML.text/1) ==
             ["gsmlg-opt", "Agent-Note"]

    assert LazyHTML.text(document) =~ "Prepared page content"

    assert LazyHTML.attribute(LazyHTML.query(document, "[data-go-to-file]"), "href") ==
             ["/gsmlg-opt/agent-note/search?ref=refs%2Fheads%2Ffeature%2Fui"]

    assert LazyHTML.attribute(LazyHTML.query(document, "[data-ref-form]"), "action") ==
             ["/gsmlg-opt/agent-note"]
  end

  test "renders zero counts and exactly one active destination without inventing unknown counts" do
    document =
      render_component(&fc_repository_navigation/1, %{items: view().navigation})
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(LazyHTML.query(document, "a[aria-current=page]"), "href") ==
             ["/gsmlg-opt/agent-note/blob?ref=refs%2Fheads%2Ffeature%2Fui&path=README.md"]

    assert LazyHTML.attribute(LazyHTML.query(document, "a"), "href") ==
             [
               "/gsmlg-opt/agent-note/blob?ref=refs%2Fheads%2Ffeature%2Fui&path=README.md",
               "/gsmlg-opt/agent-note/issues"
             ]

    assert LazyHTML.text(LazyHTML.query(document, "li:last-child")) |> String.trim() =~ "0"
    assert Enum.count(LazyHTML.query(document, "a[aria-current=page]")) == 1
  end

  test "uses prepared full-ref options and selected value" do
    document =
      render_component(&fc_ref_controls/1, %{toolbar: view().toolbar, clone: view().clone})
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(LazyHTML.query(document, "select[name=ref] option"), "value") ==
             ["refs/heads/main", "refs/heads/feature/ui", "refs/tags/feature/ui"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "select[name=ref] option[selected]"),
             "value"
           ) == ["refs/heads/feature/ui"]
  end

  test "uses exact-ref entry and prepared index links when the ref list is truncated" do
    toolbar = %{view().toolbar | refs_truncated: true}

    document =
      render_component(&fc_ref_controls/1, %{toolbar: toolbar, clone: view().clone})
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, "select[name=ref]"))

    assert LazyHTML.attribute(LazyHTML.query(document, "input[name=ref]"), "value") ==
             ["refs/heads/feature/ui"]

    assert LazyHTML.attribute(LazyHTML.query(document, ".repository-ref-index-links a"), "href") ==
             ["/gsmlg-opt/agent-note/branches", "/gsmlg-opt/agent-note/tags"]
  end

  test "omits ref controls on collaboration and empty repository surfaces" do
    for prepared_view <- [
          %{view() | kind: :issues, show_toolbar: false, toolbar: nil, clone: nil},
          %{view() | kind: :empty, toolbar: %{view().toolbar | options: []}}
        ] do
      document =
        render_component(&fc_repository_frame/1, %{
          view: prepared_view,
          inner_block: [%{inner_block: fn _, _ -> "Page" end}]
        })
        |> LazyHTML.from_fragment()

      assert Enum.empty?(LazyHTML.query(document, "[data-repository-toolbar]"))

      assert LazyHTML.attribute(LazyHTML.query(document, "h1 a"), "href") ==
               ["/gsmlg-opt", "/gsmlg-opt/agent-note"]
    end
  end

  test "connects the Code button to its native clone popover" do
    document =
      render_component(&fc_clone_popover/1, %{clone: view().clone})
      |> LazyHTML.from_fragment()

    trigger = LazyHTML.query(document, "button#repository-clone-trigger")

    assert LazyHTML.attribute(trigger, "command") == ["toggle-popover"]
    assert LazyHTML.attribute(trigger, "commandfor") == ["repository-clone-popover"]
    assert LazyHTML.attribute(trigger, "aria-controls") == ["repository-clone-popover"]

    assert LazyHTML.attribute(trigger, "style") == [
             "anchor-name: --anchor-repository-clone-popover"
           ]

    assert Enum.count(
             LazyHTML.query(
               document,
               "#repository-clone-trigger + #repository-clone-popover[popover=auto] .popover-body #repository-clone-box"
             )
           ) == 1
  end

  test "renders exact clone and empty-setup commands supplied by the consumer" do
    clone = %{
      title: "Set up repository",
      https_url: "https://forge.test/gsmlg-opt/agent-note.git",
      ssh_url: "ssh://git@forge.test:2222/gsmlg-opt/agent-note.git",
      commands: [
        {"Add remote", "git remote add origin https://forge.test/gsmlg-opt/agent-note.git"},
        {"Set default branch", "git branch -M trunk"},
        {"Push", "git push -u origin trunk"}
      ]
    }

    document =
      render_component(&fc_clone_popover/1, %{clone: clone})
      |> LazyHTML.from_fragment()

    assert LazyHTML.text(document) =~ "Set up repository"

    assert LazyHTML.attribute(
             LazyHTML.query(document, "[data-fc-copy-value]"),
             "data-fc-copy-value"
           ) ==
             [clone.https_url, clone.ssh_url | Enum.map(clone.commands, &elem(&1, 1))]

    assert Enum.count(LazyHTML.query(document, "[data-fc-copy-status][aria-live=polite]")) == 5
    refute LazyHTML.text(document) =~ "git push -u origin main"

    read_only =
      render_component(&fc_clone_popover/1, %{clone: %{clone | ssh_url: nil, commands: []}})
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(
             LazyHTML.query(read_only, "[data-fc-copy-value]"),
             "data-fc-copy-value"
           ) ==
             [clone.https_url]

    refute LazyHTML.text(read_only) =~ "git push"
  end

  test "renders supplied breadcrumbs without making the current location a link" do
    document =
      render_component(&fc_server_breadcrumbs/1, %{
        crumbs: [
          {"agent-note", "/gsmlg-opt/agent-note?ref=refs%2Ftags%2Fv1", false},
          {"lib", "/gsmlg-opt/agent-note/tree?ref=refs%2Ftags%2Fv1&path=lib", false},
          {"<module>.ex", nil, true}
        ]
      })
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(LazyHTML.query(document, "a"), "href") ==
             [
               "/gsmlg-opt/agent-note?ref=refs%2Ftags%2Fv1",
               "/gsmlg-opt/agent-note/tree?ref=refs%2Ftags%2Fv1&path=lib"
             ]

    assert LazyHTML.text(LazyHTML.query(document, "[aria-current=page]")) |> String.trim() ==
             "<module>.ex"

    assert Enum.empty?(LazyHTML.query(document, "module"))
  end

  test "renders ordinary pagination links using the supplied URL pattern and preserves filters" do
    document =
      render_component(&fc_server_pagination/1, %{
        page: 2,
        total_pages: 3,
        page_url: "/gsmlg-opt/agent-note/issues?state=open&labels=bug&page={page}"
      })
      |> LazyHTML.from_fragment()

    hrefs = LazyHTML.attribute(LazyHTML.query(document, "a"), "href")
    assert "/gsmlg-opt/agent-note/issues?state=open&labels=bug&page=1" in hrefs
    assert "/gsmlg-opt/agent-note/issues?state=open&labels=bug&page=3" in hrefs
    assert Enum.empty?(LazyHTML.query(document, "[data-phx-link]"))

    single_page =
      render_component(&fc_server_pagination/1, %{
        page: 1,
        total_pages: 1,
        page_url: "/gsmlg-opt/agent-note/issues?page={page}"
      })
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(single_page, "[data-server-pagination]"))
  end

  defp view do
    %{
      kind: :blob,
      header: %{
        owner: "gsmlg-opt",
        owner_href: "/gsmlg-opt",
        name: "Agent-Note",
        name_href: "/gsmlg-opt/agent-note",
        visibility: "public",
        default_ref: "feature/ui",
        description: "Prepared description",
        configured_ref: "main",
        short_oid: "0123456789ab",
        last_pushed_at: nil
      },
      navigation: [
        %{
          label: "Code",
          href: "/gsmlg-opt/agent-note/blob?ref=refs%2Fheads%2Ffeature%2Fui&path=README.md",
          active: true,
          icon: "code-tags",
          count: nil
        },
        %{
          label: "Issues",
          href: "/gsmlg-opt/agent-note/issues",
          active: false,
          icon: "alert-circle-outline",
          count: 0
        }
      ],
      show_toolbar: true,
      toolbar: %{
        options: [
          {"refs/heads/main", "main"},
          {"refs/heads/feature/ui", "feature/ui"},
          {"refs/tags/feature/ui", "feature/ui (tag)"}
        ],
        selected: "refs/heads/feature/ui",
        refs_truncated: false,
        action: "/gsmlg-opt/agent-note",
        branches_href: "/gsmlg-opt/agent-note/branches",
        tags_href: "/gsmlg-opt/agent-note/tags",
        search_href: "/gsmlg-opt/agent-note/search?ref=refs%2Fheads%2Ffeature%2Fui"
      },
      clone: %{
        title: "Clone repository",
        https_url: "https://forge.test/gsmlg-opt/agent-note.git",
        ssh_url: nil,
        commands: [{"Clone", "git clone https://forge.test/gsmlg-opt/agent-note.git"}]
      }
    }
  end
end
