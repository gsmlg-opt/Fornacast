defmodule FornacastComponent.GitRepositoryTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import FornacastComponent.GitRepository

  describe "fc_git_repository_header/1" do
    test "renders repository identity, metadata, and actions" do
      result =
        render_component(&fc_git_repository_header/1, %{
          id: "repo-header",
          owner: "duskmoon-dev",
          name: "phoenix-duskmoon-ui",
          visibility: "public",
          default_ref: "main",
          description: "DuskMoon UI for Phoenix",
          meta: [
            %{icon: "source-commit", inner_block: fn _, _ -> "b91d64a" end}
          ],
          action: [
            %{inner_block: fn _, _ -> "Settings" end}
          ]
        })

      assert result =~ ~s(id="repo-header")

      assert normalized_heading(LazyHTML.from_fragment(result)) ==
               "duskmoon-dev/phoenix-duskmoon-ui"

      assert result =~ "phoenix-duskmoon-ui"
      assert result =~ "public"
      assert result =~ "main"
      assert result =~ "DuskMoon UI for Phoenix"
      assert result =~ "b91d64a"
      assert result =~ "Settings"
    end

    test "links organization and personal owners without including the slash" do
      for owner <- ["gsmlg-opt", "jonathan"] do
        document =
          render_component(&fc_git_repository_header/1, %{
            owner: owner,
            owner_href: "/#{owner}",
            name: "agent-note"
          })
          |> LazyHTML.from_fragment()

        link = LazyHTML.query(document, "h1 a")
        assert LazyHTML.attribute(link, "href") == ["/#{owner}"]
        assert LazyHTML.text(link) == owner
        assert LazyHTML.attribute(link, "tabindex") == []
        assert normalized_heading(document) == "#{owner}/agent-note"
      end
    end

    test "keeps owners as plain text when no link is supplied" do
      for owner_href <- [nil, ""] do
        document =
          render_component(&fc_git_repository_header/1, %{
            owner: "gsmlg-opt",
            owner_href: owner_href,
            name: "agent-note"
          })
          |> LazyHTML.from_fragment()

        assert LazyHTML.attribute(LazyHTML.query(document, "h1 a"), "href") == []
        assert normalized_heading(document) == "gsmlg-opt/agent-note"
      end
    end

    test "links owner and repository name independently without including the separator" do
      document =
        render_component(&fc_git_repository_header/1, %{
          owner: "gsmlg-opt",
          owner_href: "/gsmlg-opt",
          name: "Agent-Note",
          name_href: "/gsmlg-opt/agent-note"
        })
        |> LazyHTML.from_fragment()

      links = LazyHTML.query(document, "h1 a")
      assert LazyHTML.attribute(links, "href") == ["/gsmlg-opt", "/gsmlg-opt/agent-note"]
      assert LazyHTML.text(links) == "gsmlg-optAgent-Note"

      assert LazyHTML.text(LazyHTML.query(document, "h1")) |> String.replace(~r/\s+/, "") ==
               "gsmlg-opt/Agent-Note"

      assert LazyHTML.attribute(links, "tabindex") == []
    end

    test "links the repository name without requiring an owner link" do
      document =
        render_component(&fc_git_repository_header/1, %{
          owner: "jonathan",
          name: "agent-note",
          name_href: "/jonathan/agent-note"
        })
        |> LazyHTML.from_fragment()

      link = LazyHTML.query(document, "h1 a")
      assert LazyHTML.attribute(link, "href") == ["/jonathan/agent-note"]
      assert LazyHTML.text(link) == "agent-note"
    end

    test "keeps the repository name as plain text when no destination is supplied" do
      for name_href <- [nil, ""] do
        document =
          render_component(&fc_git_repository_header/1, %{
            owner: "gsmlg-opt",
            owner_href: "/gsmlg-opt",
            name: "agent-note",
            name_href: name_href
          })
          |> LazyHTML.from_fragment()

        assert LazyHTML.attribute(LazyHTML.query(document, "h1 a"), "href") == ["/gsmlg-opt"]
        assert LazyHTML.text(LazyHTML.query(document, "h1")) =~ "agent-note"
      end
    end

    test "escapes displayed names, descriptions, and file contents" do
      header =
        render_component(&fc_git_repository_header/1, %{
          owner: "<owner>",
          name: "<script>alert(1)</script>",
          name_href: "/owner/repo",
          description: "<img src=x onerror=alert(1)>"
        })
        |> LazyHTML.from_fragment()

      blob =
        render_component(&fc_git_blob_viewer/1, %{
          filename: "example.html",
          content: "<script>alert(1)</script>\n"
        })
        |> LazyHTML.from_fragment()

      assert LazyHTML.text(LazyHTML.query(header, "h1 a")) == "<script>alert(1)</script>"
      assert LazyHTML.query(header, "script, img") |> Enum.empty?()
      assert LazyHTML.text(LazyHTML.query(blob, "pre code")) == "<script>alert(1)</script>\n"
      assert LazyHTML.query(blob, "script") |> Enum.empty?()
    end

    test "omits the owner link and slash when the owner is absent" do
      for owner <- [nil, ""] do
        document =
          render_component(&fc_git_repository_header/1, %{
            owner: owner,
            owner_href: "/gsmlg-opt",
            name: "agent-note"
          })
          |> LazyHTML.from_fragment()

        assert LazyHTML.attribute(LazyHTML.query(document, "h1 a"), "href") == []
        assert LazyHTML.text(LazyHTML.query(document, "h1")) |> String.trim() == "agent-note"
      end
    end
  end

  describe "fc_git_repository_nav/1" do
    test "renders href, navigate, patch, active, and count items" do
      result =
        render_component(&fc_git_repository_nav/1, %{
          item: [
            %{label: "Code", href: "/repos/demo", icon: "code-tags", active: true},
            %{label: "Commits", navigate: "/repos/demo/commits", replace: true, count: 12},
            %{label: "Branches", patch: "/repos/demo?tab=branches"}
          ]
        })

      assert result =~ ~s[href="/repos/demo"]
      assert result =~ ~s[aria-current="page"]
      assert result =~ "Code"
      assert result =~ ~s[href="/repos/demo/commits"]
      assert result =~ ~s[data-phx-link="redirect"]
      assert result =~ ~s[data-phx-link-state="replace"]
      assert result =~ "12"
      assert result =~ ~s[href="/repos/demo?tab=branches"]
      assert result =~ ~s[data-phx-link="patch"]
    end
  end

  describe "fc_git_file_tree/1" do
    test "renders linked repository rows with kinds, metadata, and selection state" do
      result =
        render_component(&fc_git_file_tree/1, %{
          row: [
            %{kind: "folder", name: "lib", path: "lib", href: "/tree/lib", meta: "12 files"},
            %{
              kind: "file",
              name: "mix.exs",
              path: "mix.exs",
              patch: "/blob/mix.exs",
              active: true,
              meta: "4 KB"
            },
            %{kind: "submodule", name: "vendor/theme", path: "vendor/theme", meta: "a13f9c2"}
          ]
        })

      assert result =~ "lib"
      assert result =~ "12 files"
      assert result =~ ~s[href="/tree/lib"]
      assert result =~ "mix.exs"
      assert result =~ ~s[data-phx-link="patch"]
      assert result =~ ~s[aria-current="true"]
      assert result =~ "vendor/theme"
      assert result =~ "a13f9c2"
    end

    test "renders empty state" do
      result =
        render_component(&fc_git_file_tree/1, %{
          empty_message: "No files on this branch."
        })

      assert result =~ "No files on this branch."
    end
  end

  describe "fc_git_blob_viewer/1" do
    test "renders source content, raw link, and copy affordance" do
      result =
        render_component(&fc_git_blob_viewer/1, %{
          filename: "lib/app.ex",
          size: "128 B",
          language: "elixir",
          content: "defmodule App do\nend\n",
          raw_href: "/raw/lib/app.ex"
        })

      assert result =~ "lib/app.ex"
      assert result =~ "128 B"
      assert result =~ ~s[data-language="elixir"]
      assert result =~ "defmodule App"
      assert result =~ ~s[href="/raw/lib/app.ex"]
      assert result =~ "data-fc-copy-value"
      assert result =~ "data-fc-copy-label"
      assert result =~ "data-fc-copy-status"
      assert result =~ ~s[role="status"]
      assert result =~ ~s[aria-live="polite"]
      assert result =~ ~s[aria-atomic="true"]
    end

    test "renders truncated, binary, and non-UTF-8 states" do
      truncated =
        render_component(&fc_git_blob_viewer/1, %{
          filename: "README.md",
          content: "# README",
          truncated: true
        })

      binary =
        render_component(&fc_git_blob_viewer/1, %{
          filename: "logo.png",
          binary: true
        })

      non_utf8 =
        render_component(&fc_git_blob_viewer/1, %{
          filename: "legacy.txt",
          non_utf8: true
        })

      assert truncated =~ "This file is truncated."
      assert binary =~ "Binary file not shown."
      refute binary =~ "<pre"
      assert non_utf8 =~ "Non-UTF-8 file not shown."
      refute non_utf8 =~ "<pre"
    end
  end

  describe "fc_git_commit_diff/1" do
    test "renders commit metadata, changed-file summary, and diff lines" do
      result =
        render_component(&fc_git_commit_diff/1, %{
          title: "Add forge components",
          sha: "b91d64a5f5a2c7e6d9a6",
          author: "Jonathan",
          committed_at: "2 minutes ago",
          message: "Render repository data without client tabs.",
          changed_files: 1,
          additions: 2,
          deletions: 1,
          file: [
            %{
              path: "lib/repo_view.ex",
              status: "modified",
              additions: 2,
              deletions: 1,
              lines: [
                %{type: :hunk, old_line: nil, new_line: nil, content: "@@ -1,3 +1,4 @@"},
                %{type: :context, old_line: 1, new_line: 1, content: "defmodule RepoView do"},
                %{type: :delete, old_line: 2, new_line: nil, content: "  def old, do: :ok"},
                %{type: :add, old_line: nil, new_line: 2, content: "  def new, do: :ok"}
              ]
            }
          ]
        })

      assert result =~ "Add forge components"
      assert result =~ "b91d64a5f5a"
      assert result =~ "Jonathan"
      assert result =~ "2 minutes ago"
      assert result =~ "Render repository data without client tabs."
      assert result =~ "1 file"
      assert result =~ "+2"
      assert result =~ "-1"
      assert result =~ "lib/repo_view.ex"
      assert result =~ "@@ -1,3 +1,4 @@"
      assert result =~ "def new, do: :ok"
    end

    test "renders binary, truncated, and empty diff states" do
      result =
        render_component(&fc_git_commit_diff/1, %{
          title: "Update assets",
          file: [
            %{path: "logo.png", binary: true},
            %{path: "large.diff", truncated: true}
          ]
        })

      empty = render_component(&fc_git_commit_diff/1, %{title: "No changes"})

      assert result =~ "Binary file changed."
      assert result =~ "Diff truncated."
      assert empty =~ "No file changes."
    end
  end

  describe "fc_git_clone_box/1" do
    test "renders default clone URLs and clone command" do
      result =
        render_component(&fc_git_clone_box/1, %{
          clone_url: "https://github.com/example/repo.git",
          ssh_url: "git@github.com:example/repo.git"
        })

      assert result =~ "HTTPS"
      assert result =~ "https://github.com/example/repo.git"
      assert result =~ "SSH"
      assert result =~ "git@github.com:example/repo.git"
      assert result =~ "git clone https://github.com/example/repo.git"
      assert [_, _, _] = Regex.scan(~r/data-fc-copy-value=/, result)
      assert [_, _, _] = Regex.scan(~r/data-fc-copy-status/, result)
    end

    test "renders empty repository setup commands and custom command slots" do
      empty =
        render_component(&fc_git_clone_box/1, %{
          clone_url: "https://github.com/example/empty.git",
          empty: true
        })

      custom =
        render_component(&fc_git_clone_box/1, %{
          command: [
            %{label: "Push existing", value: "git push -u origin main"}
          ]
        })

      assert empty =~ "git remote add origin https://github.com/example/empty.git"
      assert empty =~ "git push -u origin main"
      assert custom =~ "Push existing"
      assert custom =~ "git push -u origin main"
    end
  end

  defp normalized_heading(document) do
    document
    |> LazyHTML.query("h1")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, "")
  end
end
