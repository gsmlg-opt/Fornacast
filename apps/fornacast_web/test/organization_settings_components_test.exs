defmodule FornacastWeb.OrganizationSettingsComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeAccounts.Organization
  alias FornacastWeb.OrganizationSettingsComponents

  test "General layout renders the organization identity, canonical links, selected state, and content" do
    html = render_layout(:general)

    assert html =~ ~s(data-organization-settings-layout)
    assert html =~ "Acme Engineering"
    assert html =~ "@acme"
    assert html =~ ~s(href="/acme")
    assert html =~ "Back to organization"
    assert html =~ ~r/href="\/organizations\/acme\/settings"[^>]*aria-current="page"/
    assert html =~ ~s(href="/organizations/acme/settings/github")
    assert html =~ "General"
    assert html =~ "GitHub integration"
    assert html =~ "layout content"
    assert length(Regex.scan(~r/aria-current="page"/, html)) == 1
    assert Enum.empty?(LazyHTML.query(LazyHTML.from_fragment(html), "details[open]"))
    refute html =~ "People"
    refute html =~ "Teams"
    refute html =~ "Permissions"
  end

  test "GitHub layout defaults to overview and escapes organization identity" do
    html =
      render_component(&OrganizationSettingsComponents.organization_settings_layout/1,
        organization: %Organization{
          id: 72,
          username: "acme<script>",
          display_name: "Acme <script>alert(1)</script>",
          state: :active
        },
        active: :github,
        inner_block: [%{inner_block: fn _changed, _argument -> "GitHub content" end}]
      )

    assert html =~ "Acme &lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "@acme&lt;script&gt;"
    assert html =~ ~s(href="/organizations/acme&lt;script&gt;/settings")

    assert html =~
             ~r/href="\/organizations\/acme&lt;script&gt;\/settings\/github"[^>]*aria-current="page"/

    assert html =~ "GitHub content"
    assert length(Regex.scan(~r/aria-current="page"/, html)) == 1
    refute html =~ "<script>alert(1)</script>"
  end

  test "GitHub submenu exposes configuration pages and selects only the current child" do
    pages = [
      overview: "",
      connection: "/connection",
      sync: "/legacy",
      repositories: "/repositories",
      history: "/runs",
      advanced: "/app/advanced",
      conflicts: "/conflicts"
    ]

    for {page, suffix} <- pages do
      document = LazyHTML.from_fragment(render_layout(:github, page))
      menu = LazyHTML.query(document, "[data-organization-github-menu][open]")

      assert Enum.count(menu) == 1
      assert LazyHTML.attribute(menu, "data-active-group") == ["true"]

      assert LazyHTML.attribute(LazyHTML.query(menu, "a"), "href") ==
               Enum.map(pages, fn {_page, path} ->
                 "/organizations/acme/settings/github#{path}"
               end)

      assert LazyHTML.attribute(LazyHTML.query(document, "a[aria-current='page']"), "href") ==
               ["/organizations/acme/settings/github#{suffix}"]

      assert Enum.empty?(LazyHTML.query(menu, "form, button, a[data-method]"))
    end
  end

  defp render_layout(active, github_page \\ :overview) do
    render_component(&OrganizationSettingsComponents.organization_settings_layout/1,
      organization: %Organization{
        id: 71,
        username: "acme",
        display_name: "Acme Engineering",
        state: :active
      },
      active: active,
      github_page: github_page,
      inner_block: [%{inner_block: fn _changed, _argument -> "layout content" end}]
    )
  end
end
