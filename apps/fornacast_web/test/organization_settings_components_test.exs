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
    refute html =~ "People"
    refute html =~ "Teams"
    refute html =~ "Permissions"
  end

  test "GitHub layout selects its integration link and escapes organization identity" do
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

  defp render_layout(active) do
    render_component(&OrganizationSettingsComponents.organization_settings_layout/1,
      organization: %Organization{
        id: 71,
        username: "acme",
        display_name: "Acme Engineering",
        state: :active
      },
      active: active,
      inner_block: [%{inner_block: fn _changed, _argument -> "layout content" end}]
    )
  end
end
