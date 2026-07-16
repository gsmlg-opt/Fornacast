defmodule GitCore do
  @moduledoc """
  Fornacast-owned API for low-level Git repository operations.
  """

  @commit_page_limit 50
  @commit_scan_deadline_ms 5_000

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

  def read_blob(path, ref, blob_path, opts \\ [])
      when is_binary(path) and is_binary(ref) and is_binary(blob_path) do
    limit = Keyword.get(opts, :limit, 1_048_576)

    with {:ok, {name, oid, size, data, truncated, binary}} <-
           wrap_read(GitCore.Native.read_blob(path, ref, blob_path, limit), :read_blob) do
      data = IO.iodata_to_binary(data)

      {:ok,
       %GitCore.Blob{
         name: name,
         oid: oid,
         size: size,
         data: data,
         truncated: truncated,
         binary: binary,
         non_utf8: not String.valid?(data),
         lease: nil
       }}
    end
  end

  def diff_commit(path, oid, opts \\ []) when is_binary(path) and is_binary(oid) do
    limit = Keyword.get(opts, :limit, 200_000)

    with {:ok, {files, patch, truncated}} <-
           wrap_read(GitCore.Native.diff_commit(path, oid, limit), :diff_commit) do
      files = Enum.map(files, &diff_file_from_native/1)

      {:ok,
       %GitCore.CommitDiff{
         files: files,
         patch: patch,
         truncated: truncated,
         changed_files: length(files),
         additions: nil,
         deletions: nil
       }}
    end
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

  defp diff_status("added"), do: :added
  defp diff_status("modified"), do: :modified
  defp diff_status("deleted"), do: :deleted

  defp diff_file_from_native({path, status, old_oid, new_oid, binary}) do
    %GitCore.DiffFile{
      path: path,
      status: diff_status(status),
      old_oid: old_oid,
      new_oid: new_oid,
      binary: binary,
      additions: nil,
      deletions: nil,
      truncated: false,
      lines: []
    }
  end

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
