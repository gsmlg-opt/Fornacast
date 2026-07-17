defmodule GitCore do
  @moduledoc """
  Fornacast-owned API for low-level Git repository operations.
  """

  @commit_page_limit 50
  @commit_scan_deadline_ms 5_000
  @tree_page_limit 200
  @inline_blob_limit 1_048_576
  @complete_blob_limit 100_000_000
  @diff_source_limit 200_000
  @diff_scan_deadline_ms 5_000
  @search_file_limit 10_000
  @search_byte_limit 67_108_864
  @search_result_limit 100
  @search_deadline_ms 2_000
  @analysis_file_limit 100_000
  @analysis_byte_limit 536_870_912
  @analysis_deadline_ms 2_000
  @disk_usage_deadline_ms 2_000

  def init_bare(path) when is_binary(path) do
    GitCore.Native.init_bare(path)
  end

  def is_bare_repository?(path) when is_binary(path) do
    GitCore.Native.is_bare_repository(path)
    |> wrap_read(:is_bare_repository?)
  end

  def empty?(path) when is_binary(path) do
    GitCore.Native.empty(path)
    |> wrap_read(:empty?)
  end

  def list_refs(path) when is_binary(path) do
    read_refs(path, :list_refs)
  end

  def ref_summary(path, opts \\ []) when is_binary(path) and is_list(opts) do
    selected_ref = opts |> Keyword.get(:selected_ref) |> ref_name_to_native()

    GitCore.ScanLimiter.with_permit(:ref_summary, fn ->
      with {:ok, summary} <-
             wrap_read(GitCore.Native.ref_summary(path, selected_ref), :ref_summary) do
        {:ok, ref_summary_from_native(summary)}
      end
    end)
  end

  def ref_summary_for_route(path, route_segments)
      when is_binary(path) and is_list(route_segments) do
    native_route_segments = Enum.map(route_segments, &:binary.bin_to_list/1)

    GitCore.ScanLimiter.with_permit(:ref_summary_for_route, fn ->
      with {:ok, {summary, selector_kind, selector_full_name, repository_path}} <-
             wrap_read(
               GitCore.Native.ref_summary_for_route(path, native_route_segments),
               :ref_summary_for_route
             ) do
        {:ok,
         {ref_summary_from_native(summary),
          %GitCore.RefSelector{
            kind: selector_kind(selector_kind),
            full_name: ref_name_from_native(selector_full_name)
          }, ref_name_from_native(repository_path)}}
      end
    end)
  end

  def ref_page(path, kind, page, opts \\ [])
      when is_binary(path) and kind in [:branch, :tag] and is_integer(page) and page > 0 and
             is_list(opts) do
    per_page = opts |> Keyword.get(:per_page, 100) |> bounded_ref_page_size()

    GitCore.ScanLimiter.with_permit(:ref_page, fn ->
      with {:ok, {refs, total}} <-
             wrap_read(
               GitCore.Native.ref_page(
                 path,
                 Atom.to_string(kind),
                 Integer.to_string(page),
                 per_page
               ),
               :ref_page
             ) do
        total_pages = if total == 0, do: 1, else: div(total + per_page - 1, per_page)

        {:ok,
         %GitCore.RefPage{
           refs: Enum.map(refs, &ref_from_native/1),
           total: total,
           page: page,
           per_page: per_page,
           total_pages: total_pages
         }}
      end
    end)
  end

  def resolve_snapshot(path, %GitCore.RefSelector{kind: kind, full_name: full_name})
      when is_binary(path) and kind in [:branch, :tag, :legacy] and is_binary(full_name) do
    with {:ok, {resolved_kind, resolved_ref, oid}} <-
           wrap_read(
             GitCore.Native.resolve_snapshot(
               path,
               Atom.to_string(kind),
               :binary.bin_to_list(full_name)
             ),
             :resolve_snapshot
           ) do
      {:ok,
       %GitCore.Snapshot{
         kind: ref_kind(resolved_kind),
         ref: ref_name_from_native(resolved_ref),
         oid: oid
       }}
    end
  end

  def commit_summary(path, snapshot_oid, opts \\ [])
      when is_binary(path) and is_binary(snapshot_oid) and is_list(opts) do
    deadline_ms =
      opts |> Keyword.get(:deadline_ms, @commit_scan_deadline_ms) |> commit_deadline_ms()

    GitCore.ScanLimiter.with_permit(:commit_summary, fn ->
      with {:ok, {count, latest}} <-
             wrap_read(
               GitCore.Native.commit_summary(path, snapshot_oid, deadline_ms),
               :commit_summary
             ) do
        {:ok, %GitCore.CommitSummary{count: count, latest: commit_from_native(latest)}}
      end
    end)
  end

  def commit_page(path, snapshot_oid, page, opts \\ [])
      when is_binary(path) and is_binary(snapshot_oid) and is_integer(page) and page > 0 and
             is_list(opts) do
    per_page = opts |> Keyword.get(:per_page, @commit_page_limit) |> bounded_commit_page_size()

    deadline_ms =
      opts |> Keyword.get(:deadline_ms, @commit_scan_deadline_ms) |> commit_deadline_ms()

    GitCore.ScanLimiter.with_permit(:commit_page, fn ->
      with {:ok, {commits, total}} <-
             wrap_read(
               GitCore.Native.commit_page(
                 path,
                 snapshot_oid,
                 Integer.to_string(page),
                 per_page,
                 deadline_ms
               ),
               :commit_page
             ) do
        total_pages = if total == 0, do: 1, else: div(total + per_page - 1, per_page)

        {:ok,
         %GitCore.CommitPage{
           commits: Enum.map(commits, &commit_from_native/1),
           total: total,
           page: page,
           per_page: per_page,
           total_pages: total_pages
         }}
      end
    end)
  end

  def read_tree_with_history(path, snapshot_oid, tree_path, page, opts \\ [])
      when is_binary(path) and is_binary(snapshot_oid) and is_binary(tree_path) and
             is_integer(page) and page > 0 and is_list(opts) do
    per_page = opts |> Keyword.get(:per_page, @tree_page_limit) |> bounded_tree_page_size()

    deadline_ms =
      opts |> Keyword.get(:deadline_ms, @commit_scan_deadline_ms) |> commit_deadline_ms()

    GitCore.ScanLimiter.with_permit(:tree_history, fn ->
      with {:ok, {entries, total_entries}} <-
             wrap_read(
               native_tree_history_call(
                 path,
                 snapshot_oid,
                 :binary.bin_to_list(tree_path),
                 Integer.to_string(page),
                 per_page,
                 deadline_ms
               ),
               :tree_history
             ) do
        total_pages =
          if total_entries == 0,
            do: 1,
            else: div(total_entries + per_page - 1, per_page)

        {:ok,
         %GitCore.TreePage{
           entries: Enum.map(entries, &tree_history_entry_from_native/1),
           total_entries: total_entries,
           page: page,
           per_page: per_page,
           total_pages: total_pages
         }}
      end
    end)
  end

  # Kept as one private BEAM call boundary so tests can prove every page performs exactly one
  # native operation without exposing an injectable adapter or limiter bypass.
  defp native_tree_history_call(path, snapshot_oid, tree_path, page, per_page, deadline_ms) do
    GitCore.Native.read_tree_with_history(
      path,
      snapshot_oid,
      tree_path,
      page,
      per_page,
      deadline_ms
    )
  end

  def branches(path) when is_binary(path) do
    filter_refs(path, :branch, :branches)
  end

  def tags(path) when is_binary(path) do
    filter_refs(path, :tag, :tags)
  end

  def commit_history(path, ref, opts \\ []) when is_binary(path) and is_binary(ref) do
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, commits} <-
           wrap_read(GitCore.Native.commit_history(path, ref, limit), :commit_history) do
      {:ok, Enum.map(commits, &commit_from_native/1)}
    end
  end

  def commit(path, oid) when is_binary(path) and is_binary(oid) do
    with {:ok, commit} <- wrap_read(GitCore.Native.commit(path, oid), :commit) do
      {:ok, commit_from_native(commit)}
    end
  end

  def read_tree(path, ref, tree_path \\ "")
      when is_binary(path) and is_binary(ref) and is_binary(tree_path) do
    with {:ok, entries} <- wrap_read(GitCore.Native.read_tree(path, ref, tree_path), :read_tree) do
      entries =
        Enum.map(entries, fn {name, kind, mode, oid} ->
          %GitCore.TreeEntry{name: name, kind: tree_entry_kind(kind), mode: mode, oid: oid}
        end)

      {:ok, entries}
    end
  end

  def read_blob(path, snapshot_oid, blob_path, opts \\ [])
      when is_binary(path) and is_binary(snapshot_oid) and is_binary(blob_path) and
             is_list(opts) do
    limit = opts |> Keyword.get(:limit, @inline_blob_limit) |> bounded_inline_blob_size()

    with {:ok, metadata} <- blob_metadata(path, snapshot_oid, blob_path, :read_blob),
         {:ok, lease} <-
           GitCore.BlobLimiter.acquire(@inline_blob_limit, operation: :read_blob) do
      materialize_blob(
        metadata,
        lease,
        :read_blob,
        fn ->
          GitCore.Native.read_blob_prefix(
            path,
            metadata.oid,
            metadata.size,
            limit
          )
        end
      )
    end
  end

  def read_blob_complete(path, snapshot_oid, blob_path, opts \\ [])
      when is_binary(path) and is_binary(snapshot_oid) and is_binary(blob_path) and
             is_list(opts) do
    limit = opts |> Keyword.get(:limit, @complete_blob_limit) |> bounded_complete_blob_size()

    with {:ok, metadata} <-
           blob_metadata(path, snapshot_oid, blob_path, :read_blob_complete),
         :ok <- complete_blob_fits(metadata.size, limit),
         {:ok, lease} <-
           GitCore.BlobLimiter.acquire(metadata.size, operation: :read_blob_complete) do
      materialize_blob(
        metadata,
        lease,
        :read_blob_complete,
        fn -> GitCore.Native.read_blob_complete(path, metadata.oid, metadata.size) end
      )
    end
  end

  def release_blob(%GitCore.Blob{lease: nil}), do: :ok

  def release_blob(%GitCore.Blob{lease: lease}) do
    GitCore.BlobLimiter.release(lease)
  end

  def diff_commit(path, oid, opts \\ [])
      when is_binary(path) and is_binary(oid) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @diff_source_limit) |> bounded_diff_source_size()

    deadline_ms =
      opts |> Keyword.get(:deadline_ms, @diff_scan_deadline_ms) |> diff_deadline_ms()

    GitCore.ScanLimiter.with_permit(:diff_commit, fn ->
      with {:ok, {files, patch, truncated, changed_files, additions, deletions}} <-
             wrap_read(
               GitCore.Native.diff_commit(path, oid, limit, deadline_ms),
               :diff_commit
             ) do
        {:ok,
         %GitCore.CommitDiff{
           files: Enum.map(files, &diff_file_from_native/1),
           patch: IO.iodata_to_binary(patch),
           truncated: truncated,
           changed_files: changed_files,
           additions: additions,
           deletions: deletions
         }}
      end
    end)
  end

  def search_tree(path, snapshot_oid, query, opts \\ [])
      when is_binary(path) and is_binary(snapshot_oid) and is_binary(query) and is_list(opts) do
    scope = opts |> Keyword.get(:scope, :path) |> search_scope()
    file_limit = opts |> Keyword.get(:file_limit, @search_file_limit) |> search_file_limit()
    byte_limit = opts |> Keyword.get(:byte_limit, @search_byte_limit) |> search_byte_limit()

    result_limit =
      opts |> Keyword.get(:result_limit, @search_result_limit) |> search_result_limit()

    deadline_ms = opts |> Keyword.get(:deadline_ms, @search_deadline_ms) |> search_deadline_ms()

    GitCore.ScanLimiter.with_permit(:search_tree, fn ->
      with {:ok, {results, files_scanned, bytes_scanned, truncated_reasons}} <-
             wrap_read(
               GitCore.Native.search_tree(
                 path,
                 snapshot_oid,
                 :binary.bin_to_list(query),
                 Atom.to_string(scope),
                 file_limit,
                 byte_limit,
                 result_limit,
                 deadline_ms
               ),
               :search_tree
             ) do
        {:ok,
         %GitCore.SearchResults{
           scope: scope,
           results: Enum.map(results, &search_result_from_native/1),
           files_scanned: files_scanned,
           bytes_scanned: bytes_scanned,
           truncated_reasons: Enum.map(truncated_reasons, &search_reason/1)
         }}
      end
    end)
  end

  def repository_analysis(path, snapshot_oid, opts \\ [])
      when is_binary(path) and is_binary(snapshot_oid) and is_list(opts) do
    file_limit =
      opts
      |> Keyword.get(:file_limit, @analysis_file_limit)
      |> analysis_file_limit()

    byte_limit =
      opts
      |> Keyword.get(:byte_limit, @analysis_byte_limit)
      |> analysis_byte_limit()

    deadline_ms =
      opts
      |> Keyword.get(:deadline_ms, @analysis_deadline_ms)
      |> analysis_deadline_ms()

    GitCore.ScanLimiter.with_permit(:repository_analysis, fn ->
      with {:ok, {languages, total_bytes, files_scanned, bytes_scanned, truncated}} <-
             wrap_read(
               GitCore.Native.repository_analysis(
                 path,
                 snapshot_oid,
                 file_limit,
                 byte_limit,
                 deadline_ms
               ),
               :repository_analysis
             ) do
        {:ok,
         %GitCore.RepositoryAnalysis{
           languages:
             Enum.map(languages, fn {language, bytes} ->
               %GitCore.LanguageStat{language: language, bytes: bytes}
             end),
           total_bytes: total_bytes,
           files_scanned: files_scanned,
           bytes_scanned: bytes_scanned,
           truncated: truncated
         }}
      end
    end)
  end

  def repository_disk_usage(path, opts \\ []) when is_binary(path) and is_list(opts) do
    deadline_ms =
      opts
      |> Keyword.get(:deadline_ms, @disk_usage_deadline_ms)
      |> disk_usage_deadline_ms()

    GitCore.ScanLimiter.with_permit(:repository_disk_usage, fn ->
      GitCore.Native.repository_disk_usage(path, deadline_ms)
      |> wrap_read(:repository_disk_usage)
    end)
  end

  def pack_objects(path, wants) when is_binary(path) and is_list(wants) do
    GitCore.Native.pack_objects(path, wants)
  end

  def receive_pack(path, pack, commands)
      when is_binary(path) and is_binary(pack) and is_list(commands) do
    GitCore.Native.receive_pack(path, pack, commands)
  end

  defp read_refs(path, operation) do
    with {:ok, refs} <- wrap_read(GitCore.Native.list_refs(path), operation) do
      refs =
        Enum.map(refs, fn {name, kind, target} ->
          kind = ref_kind(kind)

          %GitCore.Ref{
            name: name,
            kind: kind,
            target: target,
            display_name: ref_display_name(name, kind)
          }
        end)

      {:ok, refs}
    end
  end

  defp filter_refs(path, kind, operation) do
    with {:ok, refs} <- read_refs(path, operation) do
      {:ok, Enum.filter(refs, &(&1.kind == kind))}
    end
  end

  defp ref_summary_from_native({branch_count, tag_count, branches, tags, refs_truncated}) do
    %GitCore.RefSummary{
      branch_count: branch_count,
      tag_count: tag_count,
      branches: Enum.map(branches, &ref_from_native/1),
      tags: Enum.map(tags, &ref_from_native/1),
      refs_truncated: refs_truncated
    }
  end

  defp ref_from_native({name, kind, target}) do
    name = ref_name_from_native(name)
    kind = ref_kind(kind)

    %GitCore.Ref{
      name: name,
      kind: kind,
      target: target,
      display_name: ref_display_name(name, kind)
    }
  end

  defp selector_kind("branch"), do: :branch
  defp selector_kind("tag"), do: :tag
  defp selector_kind("legacy"), do: :legacy

  defp bounded_ref_page_size(per_page) when is_integer(per_page) do
    per_page
    |> max(1)
    |> min(100)
  end

  defp bounded_commit_page_size(per_page) when is_integer(per_page) do
    per_page
    |> max(1)
    |> min(@commit_page_limit)
  end

  defp bounded_tree_page_size(per_page) when is_integer(per_page) do
    per_page
    |> max(1)
    |> min(@tree_page_limit)
  end

  defp bounded_inline_blob_size(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@inline_blob_limit)
  end

  defp bounded_complete_blob_size(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@complete_blob_limit)
  end

  defp bounded_diff_source_size(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@diff_source_limit)
  end

  defp diff_deadline_ms(deadline_ms) when is_integer(deadline_ms) do
    deadline_ms
    |> max(0)
    |> min(@diff_scan_deadline_ms)
  end

  defp search_scope(:path), do: :path
  defp search_scope("path"), do: :path
  defp search_scope(:content), do: :content
  defp search_scope("content"), do: :content

  defp search_scope(scope) do
    raise ArgumentError, "search scope must be :path or :content, got: #{inspect(scope)}"
  end

  defp search_file_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@search_file_limit)

  defp search_byte_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@search_byte_limit)

  defp search_result_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@search_result_limit)

  defp search_deadline_ms(deadline_ms) when is_integer(deadline_ms),
    do: deadline_ms |> max(0) |> min(@search_deadline_ms)

  defp analysis_file_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@analysis_file_limit)

  defp analysis_byte_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@analysis_byte_limit)

  defp analysis_deadline_ms(deadline_ms) when is_integer(deadline_ms),
    do: deadline_ms |> max(0) |> min(@analysis_deadline_ms)

  defp disk_usage_deadline_ms(deadline_ms) when is_integer(deadline_ms),
    do: deadline_ms |> max(0) |> min(@disk_usage_deadline_ms)

  defp blob_metadata(path, snapshot_oid, blob_path, operation) do
    with {:ok, {name, oid, size}} <-
           wrap_read(
             GitCore.Native.blob_metadata(
               path,
               snapshot_oid,
               :binary.bin_to_list(blob_path)
             ),
             operation
           ) do
      {:ok, %{name: ref_name_from_native(name), oid: oid, size: size}}
    end
  end

  defp complete_blob_fits(size, limit) when size <= limit, do: :ok

  defp complete_blob_fits(_size, _limit) do
    {:error,
     %GitCore.Error{
       kind: :blob_too_large,
       operation: :read_blob_complete,
       detail: "blob exceeds the complete-read limit"
     }}
  end

  defp materialize_blob(metadata, lease, operation, native_read)
       when is_function(native_read, 0) do
    try do
      case wrap_read(native_read.(), operation) do
        {:ok, {size, data, truncated, binary}} when size == metadata.size ->
          data = IO.iodata_to_binary(data)

          {:ok,
           %GitCore.Blob{
             name: metadata.name,
             oid: metadata.oid,
             size: size,
             data: data,
             truncated: truncated,
             binary: binary,
             non_utf8: not String.valid?(data),
             lease: lease
           }}

        {:ok, _mismatched_body} ->
          GitCore.BlobLimiter.release(lease)

          {:error,
           %GitCore.Error{
             kind: :corrupt_repository,
             operation: operation,
             detail: "blob declared size changed between metadata and body reads"
           }}

        {:error, %GitCore.Error{}} = error ->
          GitCore.BlobLimiter.release(lease)
          error
      end
    rescue
      exception ->
        GitCore.BlobLimiter.release(lease)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        GitCore.BlobLimiter.release(lease)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp commit_deadline_ms(deadline_ms) when is_integer(deadline_ms) and deadline_ms >= 0 do
    min(deadline_ms, @commit_scan_deadline_ms)
  end

  defp ref_name_to_native(nil), do: nil
  defp ref_name_to_native(name) when is_binary(name), do: :binary.bin_to_list(name)

  defp ref_name_from_native(name) when is_list(name), do: IO.iodata_to_binary(name)

  defp ref_kind("branch"), do: :branch
  defp ref_kind("tag"), do: :tag

  defp ref_display_name(<<"refs/heads/", display_name::binary>>, :branch), do: display_name
  defp ref_display_name(<<"refs/tags/", display_name::binary>>, :tag), do: display_name

  defp tree_entry_kind("tree"), do: :tree
  defp tree_entry_kind("blob"), do: :blob
  defp tree_entry_kind("commit"), do: :commit

  defp tree_history_entry_from_native({name, kind, mode, oid, latest_commit}) do
    %GitCore.TreeHistoryEntry{
      name: ref_name_from_native(name),
      kind: tree_entry_kind(kind),
      mode: mode,
      oid: oid,
      latest_commit: tree_commit_from_native(latest_commit)
    }
  end

  defp tree_commit_from_native({oid, title, author_name, author_time}) do
    %GitCore.Commit{
      oid: oid,
      title: title,
      message: nil,
      author_name: author_name,
      author_email: nil,
      author_time: author_time,
      committer_name: nil,
      committer_email: nil,
      committer_time: nil,
      parents: nil
    }
  end

  defp diff_status("added"), do: :added
  defp diff_status("modified"), do: :modified
  defp diff_status("deleted"), do: :deleted

  defp diff_file_from_native(
         {path, status, old_oid, new_oid, binary, {additions, deletions, truncated, lines}}
       ) do
    %GitCore.DiffFile{
      path: ref_name_from_native(path),
      status: diff_status(status),
      old_oid: old_oid,
      new_oid: new_oid,
      binary: binary,
      additions: additions,
      deletions: deletions,
      truncated: truncated,
      lines: Enum.map(lines, &diff_line_from_native/1)
    }
  end

  defp diff_line_from_native({type, old_line, new_line, content}) do
    %GitCore.DiffLine{
      type: diff_line_type(type),
      old_line: old_line,
      new_line: new_line,
      content: ref_name_from_native(content)
    }
  end

  defp diff_line_type("context"), do: :context
  defp diff_line_type("added"), do: :added
  defp diff_line_type("deleted"), do: :deleted
  defp diff_line_type("hunk"), do: :hunk

  defp search_result_from_native({path, line, snippet}) do
    %GitCore.SearchResult{
      path: ref_name_from_native(path),
      line: line,
      snippet: if(is_nil(snippet), do: nil, else: ref_name_from_native(snippet))
    }
  end

  defp search_reason("file_limit"), do: :file_limit
  defp search_reason("byte_limit"), do: :byte_limit
  defp search_reason("deadline"), do: :deadline
  defp search_reason("result_limit"), do: :result_limit

  defp commit_from_native(
         {oid, title, message, {author_name, author_email, author_time},
          {committer_name, committer_email, committer_time}, parents}
       ) do
    %GitCore.Commit{
      oid: oid,
      title: title,
      message: message,
      author_name: author_name,
      author_email: author_email,
      author_time: author_time,
      committer_name: committer_name,
      committer_email: committer_email,
      committer_time: committer_time,
      parents: parents
    }
  end

  defp wrap_read({:ok, value}, _operation), do: {:ok, value}

  defp wrap_read({:error, {kind, detail}}, operation) do
    {:error, %GitCore.Error{kind: native_error_kind(kind), operation: operation, detail: detail}}
  end

  defp native_error_kind("empty_repository"), do: :empty_repository
  defp native_error_kind("ref_not_found"), do: :ref_not_found
  defp native_error_kind("commit_not_found"), do: :commit_not_found
  defp native_error_kind("path_not_found"), do: :path_not_found
  defp native_error_kind("blob_too_large"), do: :blob_too_large
  defp native_error_kind("blob_busy"), do: :blob_busy
  defp native_error_kind("invalid_repository"), do: :invalid_repository
  defp native_error_kind("storage_unavailable"), do: :storage_unavailable
  defp native_error_kind("corrupt_repository"), do: :corrupt_repository
  defp native_error_kind("scan_timeout"), do: :scan_timeout
  defp native_error_kind("scan_busy"), do: :scan_busy
end
