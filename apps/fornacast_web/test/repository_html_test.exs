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
