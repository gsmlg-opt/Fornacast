defmodule ForgeReleases.NotesTest do
  use ExUnit.Case, async: true
  alias ForgeReleases.Notes

  test "body projections render Markdown and omit unsafe HTML" do
    body =
      "# Release\n\n**Fixed** [bug](https://example.test) and `code`.\n\n<script>alert(1)</script>"

    assert Notes.body_html(body) =~ "<strong>Fixed</strong>"
    refute Notes.body_html(body) =~ "<script>"
    assert Notes.body_text(body) =~ "Fixed bug and code."
    refute Notes.body_text(body) =~ "**"
    refute Notes.body_text(body) =~ "alert(1)"
    assert Notes.body_text(nil) == ""
  end
end
