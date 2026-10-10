defmodule FornacastWeb.VersionBadgeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FornacastWeb.HTML

  @info %{
    version: "0.7.4",
    environment: :prod,
    git_ref: "main",
    git_commit: "78853618a42fc1d3426550709acfcfead2dda230",
    built_at: "2026-10-10T10:00:00Z",
    released_at: "2026-10-10T10:23:22Z"
  }

  test "version beside the logo keeps the home link and tooltip trigger separate" do
    document = HTML.brand_mark("Fornacast home") |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(LazyHTML.query(document, ".brand-mark"), "href") == ["/"]

    assert LazyHTML.attribute(LazyHTML.query(document, ".brand-logo"), "src") == [
             "/images/logo.png"
           ]

    assert Enum.count(LazyHTML.query(document, ".brand-lockup > button.brand-version")) == 1
    assert Enum.count(LazyHTML.query(document, "[role='tooltip']")) == 1
  end

  test "development adds a suffix while production uses the application version" do
    for {environment, label} <- [dev: "v0.7.4-dev", prod: "v0.7.4", test: "v0.7.4"] do
      document = render(%{@info | environment: environment}) |> LazyHTML.from_fragment()

      assert LazyHTML.query(document, ".brand-version") |> LazyHTML.text() |> String.trim() ==
               label

      assert LazyHTML.attribute(LazyHTML.query(document, ".brand-version"), "interestfor") ==
               ["app-version-tooltip"]

      assert LazyHTML.attribute(LazyHTML.query(document, ".brand-version"), "aria-describedby") ==
               ["app-version-tooltip"]
    end
  end

  test "tooltip contains build provenance and does not invent missing release metadata" do
    html = render(@info)
    assert html =~ "Git ref: main"
    assert html =~ "Source commit: #{@info.git_commit}"
    assert html =~ "Built at: #{@info.built_at}"
    assert html =~ "Released at: #{@info.released_at}"

    unknown = render(%{@info | git_ref: nil, git_commit: nil, released_at: nil})
    assert unknown =~ "Git ref: Not recorded"
    assert unknown =~ "Source commit: Not recorded"
    assert unknown =~ "Released at: Not recorded"
    assert unknown =~ "Built at: #{@info.built_at}"
  end

  test "Git metadata and brand labels cannot inject markup" do
    html = render(%{@info | git_ref: ~s|<script>alert("ref")</script>|})
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"

    brand = HTML.brand_mark(~s|" onmouseover="alert(1)|)
    refute brand =~ ~s(aria-label="" onmouseover=)
    assert brand =~ "&quot;"
  end

  defp render(info), do: render_component(&HTML.version_badge/1, info: info)
end
