defmodule FornacastWeb.RepositoryHTML do
  @moduledoc false

  use FornacastWeb, :html

  alias FornacastWeb.RepositoryPage

  embed_templates "repository_html/*"

  attr :result, :any, required: true

  def repository(%{result: %RepositoryPage.Result{kind: kind}} = assigns) do
    template =
      case kind do
        kind when kind in [:code, :empty, :missing_default] -> :code
        kind when kind in [:tree, :blob, :refs, :commits, :commit, :search] -> kind
      end

    apply(__MODULE__, template, [assigns])
  end

  attr :result, :any, required: true
  attr :active, :atom, required: true
  slot :inner_block, required: true

  def repository_frame(assigns) do
    ~H"""
    <article
      id="repository-page"
      class="repository-page"
      data-repository-page
      data-repository-kind={@result.kind}
      data-repository-responsive="sidebar-stack tabs-scroll toolbar-wrap"
    >
      <div class="repository-header-zone" data-repository-header>
        <.repository_header result={@result} />
        <.repository_navigation result={@result} active={@active} />
      </div>
      <.ref_controls :if={@result.kind != :code} result={@result} />
      <div class="repository-page-content min-w-0">
        {render_slot(@inner_block)}
      </div>
    </article>
    """
  end

  attr :result, :any, required: true

  def repository_header(assigns) do
    ~H"""
    <.dm_git_repository_header
      id="repository-identity"
      owner={owner_name(@result)}
      name={repository_name(@result)}
      visibility={visibility_label(@result)}
      default_ref={selected_ref_label(@result)}
      description={@result.chrome.repository.description}
      class="repository-identity"
    >
      <:meta icon="source-branch">
        Default branch: {configured_ref_label(@result)}
      </:meta>
      <:meta :if={@result.chrome.snapshot} icon="source-commit">
        <code class="repository-inline-hash">{short_oid(@result.chrome.snapshot.oid)}</code>
      </:meta>
      <:meta :if={@result.chrome.repository.last_pushed_at} icon="clock-outline">
        Last pushed: {format_time(@result.chrome.repository.last_pushed_at)}
      </:meta>
    </.dm_git_repository_header>
    """
  end

  attr :result, :any, required: true
  attr :active, :atom, required: true

  def repository_navigation(assigns) do
    summary = assigns.result.chrome.ref_summary
    commit_count = commit_count(assigns.result)

    assigns =
      assigns
      |> assign(:summary, summary)
      |> assign(:commit_count, commit_count)

    ~H"""
    <.dm_git_repository_nav
      id="repository-navigation"
      class="repository-navigation"
      data-repository-tabs
    >
      <:item
        label="Code"
        href={code_path(@result.chrome)}
        active={@active == :code}
        icon="code-tags"
      />
      <:item
        label="Commits"
        href={commits_path(@result.chrome)}
        active={@active == :commits}
        icon="source-commit"
        count={@commit_count}
      />
      <:item
        label="Branches"
        href={refs_path(@result.chrome, :branch)}
        active={@active == :branches}
        icon="source-branch"
        count={@summary.branch_count}
      />
      <:item
        label="Tags"
        href={refs_path(@result.chrome, :tag)}
        active={@active == :tags}
        icon="tag-outline"
        count={@summary.tag_count}
      />
    </.dm_git_repository_nav>
    """
  end

  attr :result, :any, required: true

  def ref_controls(assigns) do
    summary = assigns.result.chrome.ref_summary
    refs = summary.branches ++ summary.tags
    selected = selected_or_default_full_ref(assigns.result.chrome)

    assigns =
      assigns
      |> assign(:summary, summary)
      |> assign(:refs, refs)
      |> assign(:selected, selected)
      |> assign(:options, Enum.map(refs, &{&1.name, ref_label(&1)}))

    ~H"""
    <section
      :if={@refs != []}
      id="repository-ref-controls"
      class="repository-toolbar repository-ref-controls"
      aria-label="Repository ref controls"
      data-repository-toolbar
    >
      <form
        action={repository_base(@result.chrome)}
        method="get"
        class="repository-ref-form"
        data-ref-form
      >
        <.dm_select
          :if={!@summary.refs_truncated}
          id="repository-ref"
          name="ref"
          label="Branch or tag"
          value={@selected}
          options={@options}
          size="sm"
          class="repository-ref-select"
        />
        <.dm_input
          :if={@summary.refs_truncated}
          id="repository-exact-ref"
          name="ref"
          label="Exact full ref"
          value={@selected}
          placeholder="refs/heads/trunk"
          class="repository-exact-ref"
        />
        <button type="submit" class="btn btn-sm repository-ref-submit">Switch ref</button>
      </form>
      <div :if={@summary.refs_truncated} class="repository-ref-index-links">
        <.dm_link href={refs_path(@result.chrome, :branch)}>Branches</.dm_link>
        <.dm_link href={refs_path(@result.chrome, :tag)}>Tags</.dm_link>
      </div>
      <div class="repository-toolbar-actions">
        <.dm_link
          href={search_path(@result.chrome, :path)}
          class="btn btn-sm"
          data-go-to-file
        >
          Go to file
        </.dm_link>
        <.clone_popover result={@result} />
      </div>
    </section>
    """
  end

  attr :result, :any, required: true

  def clone_popover(assigns) do
    assigns =
      assigns
      |> assign(:commands, clone_commands(assigns.result))
      |> assign(:clone, assigns.result.chrome.clone)

    ~H"""
    <.dm_popover
      id="repository-clone-popover"
      placement="bottom-end"
      class="repository-clone-popover"
      data-clone-popover
    >
      <:trigger>
        <button
          id="repository-clone-trigger"
          type="button"
          class="btn btn-primary repository-clone-trigger"
          data-clone-trigger
        >
          Code
        </button>
      </:trigger>
      <.dm_git_clone_box
        id="repository-clone-box"
        title={if @result.kind == :empty, do: "Set up repository", else: "Clone repository"}
        class="repository-clone-box"
        data-clone-box
      >
        <:url label="HTTPS" value={@clone.https_url} />
        <:url :if={@clone.ssh_url} label="SSH" value={@clone.ssh_url} />
        <:command
          :for={{label, value} <- @commands}
          label={label}
          value={value}
        />
      </.dm_git_clone_box>
    </.dm_popover>
    """
  end

  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :kind, :string, default: "info"
  attr :rest, :global

  def optional_panel(assigns) do
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

  attr :result, :any, required: true
  attr :path, :string, required: true

  def server_breadcrumbs(assigns) do
    crumbs =
      assigns.result.chrome
      |> breadcrumb_items(assigns.path)

    assigns = assign(assigns, :crumbs, crumbs)

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
  attr :base_href, :string, required: true

  def server_pagination(assigns) do
    ~H"""
    <.dm_pagination
      :if={@total_pages > 1}
      page_num={@page}
      page_size={1}
      total={@total_pages}
      page_url={page_href(@base_href, "{page}")}
      page_link_type="href"
      el_size="sm"
      class="repository-pagination"
      pagination_label="Pagination"
      data-server-pagination
    />
    """
  end

  def tree_rows(%RepositoryPage.Result{} = result, path, entries) do
    Enum.map(entries, fn entry ->
      entry_path = join_repository_path(path, entry.name)
      latest = entry.latest_commit

      %{
        kind: tree_kind(entry.kind),
        name: entry.name,
        path: latest && latest.title,
        meta: latest && relative_time(latest.author_time),
        href: source_path(result.chrome, entry_path),
        aria_label: "#{tree_kind_label(entry.kind)} #{entry.name}"
      }
    end)
  end

  def search_truncation_labels(%GitCore.SearchResults{truncated_reasons: reasons}) do
    [
      {:file_limit, "File scan limit reached"},
      {:byte_limit, "Content byte limit reached"},
      {:deadline, "Search time limit reached"},
      {:result_limit, "Result limit reached"}
    ]
    |> Enum.filter(fn {reason, _label} -> reason in reasons end)
    |> Enum.map(&elem(&1, 1))
  end

  def search_truncation_labels(_results), do: []

  def diff_line_map(%_{} = line), do: Map.from_struct(line)
  def diff_line_map(line) when is_map(line), do: line

  def code_path(chrome) do
    case selected_full_ref(chrome) do
      nil -> repository_base(chrome)
      ref -> repository_base(chrome) <> "?ref=" <> URI.encode_www_form(ref)
    end
  end

  def commits_path(chrome) do
    ref = selected_or_default_full_ref(chrome)
    repository_base(chrome) <> "/commits/" <> encode_repository_path(ref)
  end

  def refs_path(chrome, :branch), do: repository_base(chrome) <> "/branches"
  def refs_path(chrome, :tag), do: repository_base(chrome) <> "/tags"

  def ref_code_path(chrome, full_ref) do
    repository_base(chrome) <> "?ref=" <> URI.encode_www_form(full_ref)
  end

  def commit_path(chrome, oid) do
    path = repository_base(chrome) <> "/commit/" <> encode_segment(oid)

    case selected_full_ref(chrome) do
      nil -> path
      ref -> path <> "?ref=" <> URI.encode_www_form(ref)
    end
  end

  def source_path(chrome, path \\ "") do
    ref = selected_full_ref(chrome)
    base = repository_base(chrome) <> "/src/" <> encode_repository_path(ref || "")

    if path in [nil, ""] do
      base
    else
      base <> "/" <> encode_repository_path(path)
    end
  end

  def raw_path(chrome, path) do
    ref = selected_full_ref(chrome)

    repository_base(chrome) <>
      "/raw/" <> encode_repository_path(ref || "") <> "/" <> encode_repository_path(path)
  end

  def search_path(chrome), do: repository_base(chrome) <> "/search"

  def search_path(chrome, :path) do
    repository_base(chrome) <>
      "/search?ref=" <>
      URI.encode_www_form(selected_or_default_full_ref(chrome)) <> "&scope=path"
  end

  def selected_full_ref(%RepositoryPage.Result{chrome: chrome}), do: selected_full_ref(chrome)
  def selected_full_ref(%RepositoryPage.Chrome{snapshot: nil}), do: nil
  def selected_full_ref(%RepositoryPage.Chrome{snapshot: snapshot}), do: snapshot.ref

  def selected_or_default_full_ref(%RepositoryPage.Result{chrome: chrome}),
    do: selected_or_default_full_ref(chrome)

  def selected_or_default_full_ref(%RepositoryPage.Chrome{} = chrome) do
    selected_full_ref(chrome) || canonical_default_ref(chrome.repository.default_branch)
  end

  def selected_ref_label(%RepositoryPage.Result{} = result) do
    result
    |> selected_full_ref()
    |> short_ref()
  end

  def configured_ref_label(%RepositoryPage.Result{chrome: %{repository: repository}}) do
    short_ref(repository.default_branch)
  end

  def repository_base(%RepositoryPage.Chrome{owner: owner, repository: repository}) do
    "/" <> encode_segment(owner.username) <> "/" <> encode_segment(repository.slug)
  end

  def repository_name(%RepositoryPage.Result{chrome: %{repository: repository}}),
    do: repository.name || repository.slug

  def owner_name(%RepositoryPage.Result{chrome: %{owner: owner}}), do: owner.username

  def visibility_label(%RepositoryPage.Result{chrome: %{repository: repository}}),
    do: repository.visibility |> to_string()

  def ref_label(%GitCore.Ref{display_name: display_name}) when display_name not in [nil, ""],
    do: display_name

  def ref_label(%GitCore.Ref{name: name}), do: short_ref(name)

  def short_ref(nil), do: nil
  def short_ref("refs/heads/" <> name), do: name
  def short_ref("refs/tags/" <> name), do: name
  def short_ref(name), do: name

  def short_oid(oid) when is_binary(oid) and byte_size(oid) > 12, do: binary_part(oid, 0, 12)
  def short_oid(oid), do: oid

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_024, do: "#{bytes} B"

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576,
    do: "#{Float.round(bytes / 1_024, 1)} KiB"

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  def format_bytes(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"

  def format_bytes(_bytes), do: "Unknown"

  def format_time(time) when is_integer(time) do
    case DateTime.from_unix(time) do
      {:ok, datetime} -> format_time(datetime)
      {:error, _reason} -> "Unknown time"
    end
  end

  def format_time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M UTC")
  def format_time(_time), do: "Unknown time"

  def relative_time(time) when is_integer(time) do
    case DateTime.from_unix(time) do
      {:ok, _datetime} ->
        seconds = max(System.system_time(:second) - time, 0)

        cond do
          seconds < 60 -> "now"
          seconds < 3_600 -> "#{div(seconds, 60)}m ago"
          seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
          seconds < 2_592_000 -> "#{div(seconds, 86_400)}d ago"
          seconds < 31_536_000 -> "#{max(div(seconds, 2_592_000), 1)}mo ago"
          true -> "#{max(div(seconds, 31_536_000), 1)}y ago"
        end

      {:error, _reason} ->
        "Unknown time"
    end
  end

  def relative_time(%DateTime{} = time), do: time |> DateTime.to_unix() |> relative_time()
  def relative_time(time), do: format_time(time)

  def language_hint(path) do
    case String.downcase(Path.extname(path)) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".heex" -> "heex"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".css" -> "css"
      ".html" -> "html"
      ".md" -> "markdown"
      ".rs" -> "rust"
      _extension -> nil
    end
  end

  def analysis_percentage(bytes, total)
      when is_integer(bytes) and is_integer(total) and total > 0,
      do: Float.round(bytes * 100 / total, 1)

  def analysis_percentage(_bytes, _total), do: 0.0

  def language_segment_class(index) when is_integer(index) do
    Enum.at(
      ~w(repository-language-segment--primary repository-language-segment--secondary repository-language-segment--tertiary repository-language-segment--accent),
      rem(index, 4)
    )
  end

  def validation_message(nil), do: nil
  def validation_message(message) when is_binary(message), do: message
  def validation_message(:query_required), do: "Enter a search query."
  def validation_message(:query_too_long), do: "Search query must be 200 characters or fewer."
  def validation_message(:invalid_scope), do: "Choose path or content search."
  def validation_message(_message), do: "Search request is invalid."

  defp commit_count(%RepositoryPage.Result{
         kind: :code,
         content: %RepositoryPage.Code{commit_summary: %{count: count}}
       }),
       do: count

  defp commit_count(%RepositoryPage.Result{kind: :empty}), do: 0
  defp commit_count(_result), do: nil

  defp clone_commands(%RepositoryPage.Result{
         kind: :empty,
         content: %RepositoryPage.Empty{write_access: true},
         chrome: %{clone: clone}
       }) do
    Enum.map(clone.push_commands, &{push_command_label(&1), &1})
  end

  defp clone_commands(%RepositoryPage.Result{kind: :empty}), do: []

  defp clone_commands(%RepositoryPage.Result{chrome: %{clone: clone}}) do
    [{"Clone", "git clone #{clone.https_url}"}]
  end

  defp push_command_label("git init"), do: "Initialize"
  defp push_command_label("git remote add origin " <> _url), do: "Add remote"
  defp push_command_label("git branch -M " <> _ref), do: "Set default branch"
  defp push_command_label("git push " <> _rest), do: "Push"
  defp push_command_label(_command), do: "Command"

  defp canonical_default_ref("refs/" <> _rest = ref), do: ref
  defp canonical_default_ref(ref) when is_binary(ref), do: "refs/heads/" <> ref

  defp breadcrumb_items(chrome, path) do
    root = [{chrome.repository.name || chrome.repository.slug, source_path(chrome), path == ""}]
    segments = String.split(path, "/", trim: true)

    {crumbs, _parts} =
      Enum.map_reduce(segments, [], fn segment, prior ->
        parts = prior ++ [segment]
        current_path = Enum.join(parts, "/")
        {{segment, source_path(chrome, current_path), current_path == path}, parts}
      end)

    root ++ crumbs
  end

  defp page_href(base_href, page) do
    separator = if String.contains?(base_href, "?"), do: "&", else: "?"
    base_href <> separator <> "page=#{page}"
  end

  defp join_repository_path("", name), do: name
  defp join_repository_path(path, name), do: path <> "/" <> name

  defp tree_kind(kind) when kind in [:tree, :dir, :folder], do: :folder
  defp tree_kind(:submodule), do: :submodule
  defp tree_kind(:symlink), do: :symlink
  defp tree_kind(_kind), do: :file

  defp tree_kind_label(kind) when kind in [:tree, :dir, :folder], do: "Folder"
  defp tree_kind_label(:submodule), do: "Submodule"
  defp tree_kind_label(:symlink), do: "Symbolic link"
  defp tree_kind_label(_kind), do: "File"

  defp encode_repository_path(path) do
    path
    |> to_string()
    |> String.split("/", trim: false)
    |> Enum.map_join("/", &encode_segment/1)
  end

  defp encode_segment(segment), do: URI.encode(to_string(segment), &URI.char_unreserved?/1)
end
