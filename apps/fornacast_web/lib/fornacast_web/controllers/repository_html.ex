defmodule FornacastWeb.RepositoryHTML do
  @moduledoc false

  use FornacastWeb, :html

  alias FornacastWeb.{RepositoryPage, RepositoryView, RepositoryPaths}
  import FornacastWeb.RepositoryPaths
  use FornacastComponent

  embed_templates "repository_html/*"

  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  attr :result, :any, required: true

  def repository(%{result: %RepositoryPage.Result{kind: kind}} = assigns) do
    template =
      case kind do
        kind when kind in [:code, :empty, :missing_default] -> :code
        kind when kind in [:tree, :blob, :refs, :commits, :commit, :search] -> kind
      end

    apply(__MODULE__, template, [assigns])
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

  def selected_ref_label(%RepositoryPage.Result{} = result) do
    result
    |> selected_full_ref()
    |> short_ref()
  end

  def configured_ref_label(%RepositoryPage.Result{chrome: %{repository: repository}}) do
    short_ref(repository.default_branch)
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
end
