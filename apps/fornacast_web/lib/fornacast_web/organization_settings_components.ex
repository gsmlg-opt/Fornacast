defmodule FornacastWeb.OrganizationSettingsComponents do
  @moduledoc false

  use FornacastWeb, :html

  attr :organization, :map, required: true
  attr :active, :atom, required: true, values: [:general, :github]

  slot :inner_block, required: true

  def organization_settings_layout(assigns) do
    ~H"""
    <section class="grid gap-4" data-organization-settings-layout>
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
                <.dm_link
                  href={"/organizations/#{@organization.username}/settings/github"}
                  aria-current={if @active == :github, do: "page"}
                  class={if @active == :github, do: "active"}
                >
                  GitHub integration
                </.dm_link>
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
end
