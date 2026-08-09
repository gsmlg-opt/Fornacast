defmodule FornacastWeb.CollaborationMarkdownTest do
  use ExUnit.Case, async: true

  alias FornacastWeb.CollaborationMarkdown

  test "renders allowed links while removing unsafe markup and destinations" do
    safe =
      CollaborationMarkdown.render(
        "[web](https://example.test) [mail](mailto:team@example.test) " <>
          "[relative](guide.md) [protocol-relative](//example.test/path) " <>
          "<script>x()</script> ![unsafe](javascript:x)"
      )

    html = safe |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

    assert html =~ ~s(href="https://example.test")
    assert html =~ ~s(href="mailto:team@example.test")
    refute html =~ ~s(href="guide.md")
    refute html =~ ~s(href="//example.test/path")
    refute html =~ "<script"
    refute html =~ "javascript:"
    refute html =~ "/src/"
  end
end
