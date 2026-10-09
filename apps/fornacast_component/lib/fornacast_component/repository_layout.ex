defmodule FornacastComponent.RepositoryLayout do
  @moduledoc "Shared repository page compositions over plain presentation data."
  use Phoenix.Component
  use PhoenixDuskmoon.Component
  import FornacastComponent.GitRepository

  attr :view, :map, required: true
  slot :inner_block, required: true

  def fc_repository_frame(assigns) do
    ~H"""
    <article
      id="repository-page"
      class="repository-page"
      data-repository-page
      data-repository-kind={@view.kind}
      data-repository-responsive="sidebar-stack tabs-scroll toolbar-wrap"
    >
      <div class="repository-header-zone" data-repository-header>
        <.fc_repository_header header={@view.header} />
        <.fc_repository_navigation items={@view.navigation} />
      </div>
      <.fc_ref_controls
        :if={@view.show_toolbar}
        toolbar={@view.toolbar}
        clone={@view.clone}
      />
      <div class="repository-page-content min-w-0">
        {render_slot(@inner_block)}
      </div>
    </article>
    """
  end

  attr :header, :map, required: true

  def fc_repository_header(assigns) do
    ~H"""
    <.fc_git_repository_header
      id="repository-identity"
      owner={@header.owner}
      owner_href={@header.owner_href}
      name={@header.name}
      name_href={@header.name_href}
      visibility={@header.visibility}
      default_ref={@header.default_ref}
      description={@header.description}
      class="repository-identity"
    >
      <:meta icon="source-branch">
        Default branch: {@header.configured_ref}
      </:meta>
      <:meta :if={@header.short_oid} icon="source-commit">
        <code class="repository-inline-hash">{@header.short_oid}</code>
      </:meta>
      <:meta :if={@header.last_pushed_at} icon="clock-outline">
        Last pushed: {@header.last_pushed_at}
      </:meta>
    </.fc_git_repository_header>
    """
  end

  attr :items, :list, required: true

  def fc_repository_navigation(assigns) do
    ~H"""
    <.fc_git_repository_nav
      id="repository-navigation"
      class="repository-navigation"
      data-repository-tabs
    >
      <:item
        :for={item <- @items}
        label={item.label}
        href={item.href}
        active={item.active}
        icon={item.icon}
        count={item.count}
      />
    </.fc_git_repository_nav>
    """
  end

  attr :toolbar, :map, required: true
  attr :clone, :map, required: true

  def fc_ref_controls(assigns) do
    ~H"""
    <section
      :if={@toolbar.options != []}
      id="repository-ref-controls"
      class="repository-toolbar repository-ref-controls"
      aria-label="Repository ref controls"
      data-repository-toolbar
    >
      <form
        action={@toolbar.action}
        method="get"
        class="repository-ref-form"
        data-ref-form
      >
        <.dm_select
          :if={!@toolbar.refs_truncated}
          id="repository-ref"
          name="ref"
          label="Branch or tag"
          value={@toolbar.selected}
          options={@toolbar.options}
          size="sm"
          class="repository-ref-select"
        />
        <.dm_input
          :if={@toolbar.refs_truncated}
          id="repository-exact-ref"
          name="ref"
          label="Exact full ref"
          value={@toolbar.selected}
          placeholder="refs/heads/trunk"
          class="repository-exact-ref"
        />
        <button type="submit" class="btn btn-sm repository-ref-submit">Switch ref</button>
      </form>
      <div :if={@toolbar.refs_truncated} class="repository-ref-index-links">
        <.dm_link href={@toolbar.branches_href}>Branches</.dm_link>
        <.dm_link href={@toolbar.tags_href}>Tags</.dm_link>
      </div>
      <div class="repository-toolbar-actions">
        <.dm_link
          href={@toolbar.search_href}
          class="btn btn-sm"
          data-go-to-file
        >
          Go to file
        </.dm_link>
        <.fc_clone_popover clone={@clone} />
      </div>
    </section>
    """
  end

  attr :clone, :map, required: true

  def fc_clone_popover(assigns) do
    ~H"""
    <.dm_popover
      id="repository-clone-popover"
      placement="bottom-end"
      class="repository-clone-popover"
      data-clone-popover
    >
      <:trigger :let={trigger_attrs}>
        <button
          id="repository-clone-trigger"
          type="button"
          class="btn btn-primary repository-clone-trigger"
          data-clone-trigger
          {trigger_attrs}
        >
          Code
        </button>
      </:trigger>
      <.fc_git_clone_box
        id="repository-clone-box"
        title={@clone.title}
        class="repository-clone-box"
        data-clone-box
      >
        <:url label="HTTPS" value={@clone.https_url} />
        <:url :if={@clone.ssh_url} label="SSH" value={@clone.ssh_url} />
        <:command
          :for={{label, value} <- @clone.commands}
          label={label}
          value={value}
        />
      </.fc_git_clone_box>
    </.dm_popover>
    """
  end

  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :kind, :string, default: "info"
  attr :rest, :global

  def fc_optional_panel(assigns) do
    ~H"""
    <section
      class={["repository-optional-panel", "repository-optional-panel--#{@kind}"]}
      data-optional-state={@kind}
      {@rest}
    >
      <h2>{@title}</h2>
      <p>{@message}</p>
    </section>
    """
  end

  attr :crumbs, :list, required: true

  def fc_server_breadcrumbs(assigns) do
    ~H"""
    <.dm_breadcrumb
      class="repository-breadcrumbs"
      nav_label="File path"
      data-server-breadcrumbs
    >
      <:crumb
        :for={{label, href, current?} <- @crumbs}
        to={if current?, do: nil, else: href}
      >
        {label}
      </:crumb>
    </.dm_breadcrumb>
    """
  end

  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :page_url, :string, required: true

  def fc_server_pagination(assigns) do
    ~H"""
    <.dm_pagination
      :if={@total_pages > 1}
      page_num={@page}
      page_size={1}
      total={@total_pages}
      page_url={@page_url}
      page_link_type="href"
      el_size="sm"
      class="repository-pagination"
      pagination_label="Pagination"
      data-server-pagination
    />
    """
  end
end
