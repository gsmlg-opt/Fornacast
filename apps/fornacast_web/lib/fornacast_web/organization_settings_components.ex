defmodule FornacastWeb.OrganizationSettingsComponents do
  @moduledoc false

  use FornacastWeb, :html

  attr :organization, :map, required: true
  attr :active, :atom, required: true, values: [:general, :github]

  attr :github_page, :atom,
    default: :overview,
    values: [:overview, :connection, :sync, :repositories, :history, :advanced, :conflicts]

  slot :inner_block, required: true

  def organization_settings_layout(assigns) do
    assigns = assign_new(assigns, :github_page, fn -> :overview end)

    ~H"""
    <section class="grid content-start gap-4" data-organization-settings-layout>
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div class="grid gap-1">
          <h2 class="text-2xl font-semibold text-on-surface">
            {@organization.display_name || @organization.username}
          </h2>
          <p class="text-sm text-on-surface-variant">@{@organization.username}</p>
        </div>
        <.dm_link href={"/#{@organization.username}"} class="text-primary">
          Back to organization
        </.dm_link>
      </header>

      <div class="settings-layout">
        <aside class="settings-sidebar">
          <nav
            class="nested-menu nested-menu-bordered settings-menu"
            aria-label="Organization settings"
          >
            <ul role="list">
              <li class="nested-menu-title">Organization settings</li>
              <li>
                <.dm_link
                  href={"/organizations/#{@organization.username}/settings"}
                  aria-current={if @active == :general, do: "page"}
                  class={if @active == :general, do: "active"}
                >
                  General
                </.dm_link>
              </li>
              <li>
                <details
                  open={@active == :github}
                  data-organization-github-menu
                  data-active-group={to_string(@active == :github)}
                >
                  <summary class={if @active == :github, do: "font-semibold"}>
                    GitHub integration
                  </summary>
                  <ul role="list">
                    <li :for={{page, label, suffix} <- github_pages()}>
                      <.dm_link
                        href={"/organizations/#{@organization.username}/settings/github#{suffix}"}
                        aria-current={if @active == :github and @github_page == page, do: "page"}
                        class={if @active == :github and @github_page == page, do: "active"}
                      >
                        {label}
                      </.dm_link>
                    </li>
                  </ul>
                </details>
              </li>
            </ul>
          </nav>
        </aside>
        <div class="settings-content">
          {render_slot(@inner_block)}
        </div>
      </div>
    </section>
    """
  end

  defp github_pages do
    [
      {:overview, "Overview", ""},
      {:connection, "App connection", "/connection"},
      {:sync, "Sync configuration", "/legacy"},
      {:repositories, "Repositories", "/repositories"},
      {:history, "Task history", "/runs"},
      {:advanced, "Advanced App settings", "/app/advanced"},
      {:conflicts, "Conflicts", "/conflicts"}
    ]
  end
end
