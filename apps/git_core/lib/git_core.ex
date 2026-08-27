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
  @diff_file_page_limit 100
  @diff_scan_deadline_ms 5_000
  @search_file_limit 10_000
  @search_byte_limit 67_108_864
  @search_result_limit 100
  @search_deadline_ms 2_000
  @analysis_file_limit 100_000
  @analysis_byte_limit 536_870_912
  @analysis_deadline_ms 2_000
  @disk_usage_deadline_ms 2_000
  @merge_commit_limit 50_000
  @merge_tree_entry_limit 100_000
  @merge_changed_path_limit 10_000
  @merge_byte_limit 67_108_864
  @merge_deadline_ms 30_000
  @comparison_commit_limit @merge_commit_limit
  @comparison_tree_entry_limit @merge_tree_entry_limit
  @comparison_file_limit @search_file_limit
  @comparison_byte_limit @merge_byte_limit

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

  @doc "Reads one canonical full reference without peeling its direct object target."
  @spec exact_ref(Path.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, GitCore.Error.t()}
  def exact_ref(path, full_name, opts \\ [])
      when is_binary(path) and is_binary(full_name) and is_list(opts) do
    deadline_ms = Keyword.get(opts, :deadline_ms, GitCore.Limits.get(:ref_deadline_ms))

    if is_integer(deadline_ms) and deadline_ms > 0 do
      bounded_deadline_ms = min(deadline_ms, GitCore.Limits.get(:ref_deadline_ms))

      GitCore.Native.exact_ref(path, :binary.bin_to_list(full_name), bounded_deadline_ms)
      |> wrap_read(:exact_ref)
    else
      invalid_input(:exact_ref, "deadline_ms must be a positive integer")
    end
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

    GitCore.Cache.fetch({path, :commit_summary, snapshot_oid}, fn ->
      GitCore.ScanLimiter.with_permit(:commit_summary, fn ->
        with {:ok, {count, latest}} <-
               wrap_read(
                 GitCore.Native.commit_summary(path, snapshot_oid, deadline_ms),
                 :commit_summary
               ) do
          {:ok, %GitCore.CommitSummary{count: count, latest: commit_from_native(latest)}}
        end
      end)
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

  @doc "Reads one page of commits reachable from an immutable head OID but not a base OID."
  @spec commit_range_page(Path.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, GitCore.CommitPage.t()} | {:error, GitCore.Error.t()}
  def commit_range_page(path, base_oid, head_oid, page, opts \\ [])
      when is_binary(path) and is_binary(base_oid) and is_binary(head_oid) and
             is_integer(page) and page > 0 and is_list(opts) do
    per_page = opts |> Keyword.get(:per_page, @commit_page_limit) |> bounded_commit_page_size()

    deadline_ms =
      opts |> Keyword.get(:deadline_ms, @commit_scan_deadline_ms) |> commit_deadline_ms()

    commit_limit =
      opts
      |> Keyword.get(:commit_limit, @comparison_commit_limit)
      |> comparison_commit_limit()

    byte_limit =
      opts |> Keyword.get(:byte_limit, @comparison_byte_limit) |> comparison_byte_limit()

    GitCore.ScanLimiter.with_permit(:commit_range_page, fn ->
      with {:ok, {commits, total}} <-
             wrap_read(
               GitCore.Native.commit_range_page(
                 path,
                 base_oid,
                 head_oid,
                 Integer.to_string(page),
                 per_page,
                 commit_limit,
                 byte_limit,
                 deadline_ms
               ),
               :commit_range_page
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

    key = {path, :tree_history, snapshot_oid, tree_path, page, per_page}

    GitCore.Cache.fetch(key, fn ->
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

    key = {path, :diff_commit, oid, {limit, deadline_ms}}

    GitCore.Cache.fetch(key, fn ->
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
    end)
  end

  @doc "Reads one path-sorted page of the aggregate diff between two immutable commit OIDs."
  @spec diff_between(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, GitCore.ComparisonDiff.t()} | {:error, GitCore.Error.t()}
  def diff_between(path, base_oid, head_oid, opts \\ [])
      when is_binary(path) and is_binary(base_oid) and is_binary(head_oid) and is_list(opts) do
    page = Keyword.get(opts, :page, 1)

    if is_integer(page) and page > 0 do
      per_page =
        opts |> Keyword.get(:per_page, @diff_file_page_limit) |> bounded_diff_file_page_size()

      limit = opts |> Keyword.get(:limit, @diff_source_limit) |> bounded_diff_source_size()

      deadline_ms =
        opts |> Keyword.get(:deadline_ms, @diff_scan_deadline_ms) |> diff_deadline_ms()

      tree_entry_limit =
        opts
        |> Keyword.get(:tree_entry_limit, @comparison_tree_entry_limit)
        |> comparison_tree_entry_limit()

      file_limit =
        opts |> Keyword.get(:file_limit, @comparison_file_limit) |> comparison_file_limit()

      byte_limit =
        opts |> Keyword.get(:byte_limit, @comparison_byte_limit) |> comparison_byte_limit()

      GitCore.ScanLimiter.with_permit(:diff_between, fn ->
        with {:ok, {files, truncated, changed_files, additions, deletions}} <-
               wrap_read(
                 GitCore.Native.diff_between(
                   path,
                   base_oid,
                   head_oid,
                   Integer.to_string(page),
                   per_page,
                   limit,
                   tree_entry_limit,
                   file_limit,
                   byte_limit,
                   deadline_ms
                 ),
                 :diff_between
               ) do
          {:ok,
           %GitCore.ComparisonDiff{
             files: Enum.map(files, &diff_file_from_native/1),
             changed_files: changed_files,
             additions: additions,
             deletions: deletions,
             truncated: truncated
           }}
        end
      end)
    else
      invalid_input(:diff_between, "page must be a positive integer")
    end
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

    key =
      {path, :repository_analysis, snapshot_oid, {file_limit, byte_limit, deadline_ms}}

    GitCore.Cache.fetch(key, fn ->
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

  @doc """
  Analyzes one immutable base/head commit pair without moving a ref or persisting merge objects.

  The scan visits at most 50,000 commits and 100,000 physical tree entries, retains at most
  10,000 changed leaf paths, and is capped by one 30-second deadline. Unique decoded/generated
  object data and retained merge paths are limited to 64 MiB in aggregate, with an 8 MiB cap for
  any individual blob. Tests may lower these bounds through options, but callers cannot raise the
  production caps.
  """
  @spec merge_analysis(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, GitCore.MergeAnalysis.t()} | {:error, GitCore.Error.t()}
  def merge_analysis(path, base_oid, head_oid, opts \\ [])
      when is_binary(path) and is_binary(base_oid) and is_binary(head_oid) and is_list(opts) do
    merge_analysis_with_runtime(path, base_oid, head_oid, opts,
      limiter: GitCore.ScanLimiter,
      task_supervisor: GitCore.MergeTaskSupervisor,
      native_merge: &GitCore.Native.merge_analysis/8,
      native_await: &GitCore.Native.await_merge_worker/1
    )
  end

  @doc false
  def merge_analysis_with_runtime(path, base_oid, head_oid, opts, runtime)
      when is_binary(path) and is_binary(base_oid) and is_binary(head_oid) and is_list(opts) and
             is_list(runtime) do
    {commit_limit, tree_entry_limit, changed_path_limit, byte_limit, deadline_ms} =
      merge_bounds(opts)

    limiter = Keyword.fetch!(runtime, :limiter)
    task_supervisor = Keyword.fetch!(runtime, :task_supervisor)
    native_merge = Keyword.fetch!(runtime, :native_merge)
    native_await = Keyword.fetch!(runtime, :native_await)

    GitCore.ScanLimiter.with_deferred_permit(
      :merge_analysis,
      fn ->
        case native_merge.(
               path,
               base_oid,
               head_oid,
               commit_limit,
               tree_entry_limit,
               changed_path_limit,
               byte_limit,
               deadline_ms
             ) do
          {:deferred, native_error, ticket} ->
            {:deferred, merge_analysis_result({:error, native_error}),
             fn ->
               native_await.(ticket)
             end}

          native_result ->
            {:complete, merge_analysis_result(native_result)}
        end
      end,
      server: limiter,
      task_supervisor: task_supervisor
    )
  end

  @doc """
  Writes the merged tree and its two-parent commit without updating a reference.

  The caller must already hold the repository writer permit. This function deliberately does
  not acquire another permit, which keeps it composable inside the durable write fence. After
  the final deadline check, object publication is not cancelled. A storage failure during that
  phase may leave unreachable content-addressed objects, but this function never updates a ref.
  """
  @spec write_merge_commit(
          Path.t(),
          String.t(),
          String.t(),
          GitCore.Signature.t(),
          GitCore.Signature.t(),
          String.t(),
          keyword()
        ) :: {:ok, String.t()} | {:error, GitCore.Error.t()}
  def write_merge_commit(
        path,
        base_oid,
        head_oid,
        %GitCore.Signature{} = author,
        %GitCore.Signature{} = committer,
        message,
        opts \\ []
      )
      when is_binary(path) and is_binary(base_oid) and is_binary(head_oid) and
             is_binary(message) and is_list(opts) do
    {commit_limit, tree_entry_limit, changed_path_limit, byte_limit, deadline_ms} =
      merge_bounds(opts)

    GitCore.Native.write_merge_commit(
      path,
      base_oid,
      head_oid,
      signature_to_native(author),
      signature_to_native(committer),
      :binary.bin_to_list(message),
      commit_limit,
      tree_entry_limit,
      changed_path_limit,
      byte_limit,
      deadline_ms
    )
    |> wrap_read(:write_merge_commit)
  end

  @doc """
  Atomically creates or fast-forwards a canonical full ref from the exact expected target.

  The proposed object must already exist and be a commit. This operation never writes objects,
  deletes refs, or permits force updates. Branches may fast-forward; tags are create-only. The
  caller must hold the repository writer fence when non-CAS writers can target the same repository.
  """
  @spec compare_and_swap_ref(
          Path.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          :fast_forward,
          keyword()
        ) :: {:ok, String.t()} | {:error, GitCore.Error.t()}
  def compare_and_swap_ref(path, full_ref, expected_oid, proposed_oid, :fast_forward, opts)
      when is_binary(path) and is_binary(full_ref) and
             (is_nil(expected_oid) or is_binary(expected_oid)) and is_binary(proposed_oid) and
             is_list(opts) do
    deadline =
      if Keyword.keyword?(opts),
        do: Keyword.get(opts, :deadline_ms, GitCore.Limits.get(:ref_deadline_ms)),
        else: :invalid

    case deadline do
      deadline_ms when is_integer(deadline_ms) ->
        deadline_ms = deadline_ms |> max(0) |> min(GitCore.Limits.get(:ref_deadline_ms))

        GitCore.Native.compare_and_swap_ref(
          path,
          full_ref,
          expected_oid,
          proposed_oid,
          "fast_forward",
          GitCore.Limits.get(:commit_visits),
          deadline_ms
        )
        |> wrap_read(:compare_and_swap_ref)

      _invalid_deadline ->
        invalid_input(:compare_and_swap_ref, "deadline_ms must be an integer")
    end
  end

  def compare_and_swap_ref(_path, _full_ref, _expected_oid, _proposed_oid, _mode, _opts) do
    invalid_input(:compare_and_swap_ref, "invalid compare-and-swap arguments")
  end

  @spec invalidate_repository_cache(Path.t()) :: :ok
  def invalidate_repository_cache(repository_path) when is_binary(repository_path) do
    invalidate_repository_cache(repository_path, [])
  end

  @type contained_tree_identity :: %{
          mode: non_neg_integer(),
          major_device: non_neg_integer(),
          minor_device: non_neg_integer(),
          inode: pos_integer()
        }

  @type contained_tree_proof :: %{
          root: contained_tree_identity(),
          target: contained_tree_identity()
        }

  @spec contained_tree_identity(Path.t(), [String.t()], non_neg_integer()) ::
          {:ok, {:present, contained_tree_proof()}}
          | {:ok, {:missing, contained_tree_identity()}}
          | {:error, atom()}
  def contained_tree_identity(storage_root, relative_segments, deadline_ms) do
    cond do
      not valid_contained_tree_request?(storage_root, relative_segments, deadline_ms) ->
        {:error, :invalid_argument}

      not anchored_remove_platform?() ->
        {:error, :unsupported_platform}

      true ->
        GitCore.Native.contained_tree_identity(storage_root, relative_segments, deadline_ms)
    end
  end

  @spec remove_contained_tree(
          Path.t(),
          [String.t()],
          contained_tree_proof(),
          non_neg_integer()
        ) ::
          {:ok, {:removed, contained_tree_proof()}}
          | {:ok, {:missing, contained_tree_identity()}}
          | {:error, atom()}
  def remove_contained_tree(storage_root, relative_segments, expected_proof, deadline_ms) do
    cond do
      not valid_contained_tree_request?(storage_root, relative_segments, deadline_ms) or
          not valid_contained_tree_proof?(expected_proof) ->
        {:error, :invalid_argument}

      not anchored_remove_platform?() ->
        {:error, :unsupported_platform}

      true ->
        GitCore.Native.remove_contained_tree(
          storage_root,
          relative_segments,
          expected_proof,
          deadline_ms
        )
    end
  end

  @spec invalidate_repository_cache_strict(Path.t()) ::
          :ok | {:error, :cache_unavailable}
  def invalidate_repository_cache_strict(repository_path) when is_binary(repository_path) do
    case GitCore.Cache.invalidate_repository(repository_path) do
      :ok -> :ok
      _other -> {:error, :cache_unavailable}
    end
  catch
    _kind, _reason -> {:error, :cache_unavailable}
  end

  @doc false
  def invalidate_repository_cache(repository_path, opts)
      when is_binary(repository_path) and is_list(opts) do
    try do
      GitCore.Cache.invalidate_repository(repository_path, opts)
    catch
      _kind, _reason -> :ok
    end
  end

  defp valid_contained_tree_request?(storage_root, relative_segments, deadline_ms) do
    is_binary(storage_root) and String.valid?(storage_root) and storage_root != "/" and
      Path.type(storage_root) == :absolute and byte_size(storage_root) <= 4_096 and
      not String.contains?(storage_root, [<<0>>, "\\"]) and
      Path.expand(storage_root) == storage_root and
      is_list(relative_segments) and relative_segments != [] and
      length(relative_segments) <= 128 and
      Enum.all?(relative_segments, &valid_contained_tree_segment?/1) and is_integer(deadline_ms) and
      deadline_ms >= 0 and deadline_ms <= 18_446_744_073_709_551_615
  end

  defp valid_contained_tree_segment?(segment) do
    is_binary(segment) and String.valid?(segment) and segment not in ["", ".", ".."] and
      byte_size(segment) <= 255 and not String.contains?(segment, ["/", "\\", <<0>>])
  end

  defp valid_contained_tree_proof?(%{root: root, target: target} = proof)
       when map_size(proof) == 2 do
    valid_contained_tree_identity?(root) and valid_contained_tree_identity?(target)
  end

  defp valid_contained_tree_proof?(_proof), do: false

  defp valid_contained_tree_identity?(
         %{mode: mode, major_device: major, minor_device: minor, inode: inode} = identity
       )
       when map_size(identity) == 4 do
    Enum.all?([mode, major, minor, inode], &is_integer/1) and mode in 0..4_294_967_295 and
      major in 0..4_294_967_295 and minor in 0..4_294_967_295 and
      inode in 1..18_446_744_073_709_551_615
  end

  defp valid_contained_tree_identity?(_identity), do: false

  defp anchored_remove_platform? do
    match?({:unix, platform} when platform in [:linux, :darwin], :os.type())
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

  defp bounded_diff_file_page_size(per_page) when is_integer(per_page) do
    per_page
    |> max(1)
    |> min(@diff_file_page_limit)
  end

  defp comparison_commit_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@comparison_commit_limit)

  defp comparison_tree_entry_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@comparison_tree_entry_limit)

  defp comparison_file_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@comparison_file_limit)

  defp comparison_byte_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@comparison_byte_limit)

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

  defp merge_bounds(opts) do
    {
      opts |> Keyword.get(:commit_limit, @merge_commit_limit) |> merge_commit_limit(),
      opts
      |> Keyword.get(:tree_entry_limit, @merge_tree_entry_limit)
      |> merge_tree_entry_limit(),
      opts
      |> Keyword.get(:changed_path_limit, @merge_changed_path_limit)
      |> merge_changed_path_limit(),
      opts |> Keyword.get(:byte_limit, @merge_byte_limit) |> merge_byte_limit(),
      opts |> Keyword.get(:deadline_ms, @merge_deadline_ms) |> merge_deadline_ms()
    }
  end

  defp merge_commit_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@merge_commit_limit)

  defp merge_tree_entry_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@merge_tree_entry_limit)

  defp merge_changed_path_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@merge_changed_path_limit)

  defp merge_byte_limit(limit) when is_integer(limit),
    do: limit |> max(0) |> min(@merge_byte_limit)

  defp merge_deadline_ms(deadline_ms) when is_integer(deadline_ms),
    do: deadline_ms |> max(0) |> min(@merge_deadline_ms)

  defp signature_to_native(%GitCore.Signature{} = signature) do
    {
      :binary.bin_to_list(signature.name),
      :binary.bin_to_list(signature.email),
      signature.seconds,
      signature.offset_minutes
    }
  end

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

  defp wrap_read({:deferred, native_error, _ticket}, operation),
    do: wrap_read({:error, native_error}, operation)

  defp wrap_read({:error, {kind, detail}}, operation) do
    {:error, %GitCore.Error{kind: native_error_kind(kind), operation: operation, detail: detail}}
  end

  defp invalid_input(operation, detail) do
    {:error, %GitCore.Error{kind: :invalid_input, operation: operation, detail: detail}}
  end

  defp merge_analysis_result(native_result) do
    with {:ok,
          {native_base_oid, native_head_oid, mergeable, ahead_by, behind_by, commit_count,
           changed_paths}} <- wrap_read(native_result, :merge_analysis) do
      {:ok,
       %GitCore.MergeAnalysis{
         base_oid: native_base_oid,
         head_oid: native_head_oid,
         mergeable: mergeable,
         ahead_by: ahead_by,
         behind_by: behind_by,
         commit_count: commit_count,
         changed_paths: changed_paths
       }}
    end
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
  defp native_error_kind("commit_limit"), do: :commit_limit
  defp native_error_kind("tree_entry_limit"), do: :tree_entry_limit
  defp native_error_kind("diff_file_limit"), do: :diff_file_limit
  defp native_error_kind("scan_byte_limit"), do: :scan_byte_limit
  defp native_error_kind("changed_path_limit"), do: :changed_path_limit
  defp native_error_kind("merge_conflict"), do: :merge_conflict
  defp native_error_kind("merge_byte_limit"), do: :merge_byte_limit
  defp native_error_kind("invalid_input"), do: :invalid_input
  defp native_error_kind("stale_ref"), do: :stale_ref
  defp native_error_kind("ref_exists"), do: :ref_exists
  defp native_error_kind("non_fast_forward"), do: :non_fast_forward
  defp native_error_kind("invalid_ref"), do: :invalid_ref
  defp native_error_kind("invalid_oid"), do: :invalid_oid
  defp native_error_kind("target_not_commit"), do: :target_not_commit
  defp native_error_kind("ref_timeout"), do: :ref_timeout
end
