defmodule GitCore.GitData do
  @moduledoc false
  alias GitCore.{ContentEntry, ContentPlan, Error, Limits, Native, ScanLimiter}

  def bounds(opts, kind \\ :scan_deadline_ms) do
    duration =
      case Keyword.fetch(opts, :deadline) do
        {:ok, deadline} -> deadline - System.monotonic_time(:millisecond)
        :error -> Keyword.get(opts, :deadline_ms, Limits.get(kind))
      end

    {Limits.get(:commit_visits), Limits.get(:tree_entry_visits),
     max(0, min(duration, Limits.get(kind)))}
  end

  @doc false
  def deadline_options(opts) do
    now = System.monotonic_time(:millisecond)
    ceiling = now + Limits.get(:scan_deadline_ms)

    supplied =
      Keyword.get(
        opts,
        :deadline,
        now + Keyword.get(opts, :deadline_ms, Limits.get(:scan_deadline_ms))
      )

    Keyword.put(opts, :deadline, min(supplied, ceiling))
  end

  defp remaining(opts),
    do: max(Keyword.fetch!(opts, :deadline) - System.monotonic_time(:millisecond), 0)

  def plan_content_change(path, attrs, opts \\ []) do
    with {:ok, {old_blob, blob, tree, commit, objects}} <-
           wrap(
             Native.plan_content(
               path,
               Atom.to_string(attrs.action),
               attrs.ref,
               attrs.path,
               attrs.expected_ref_oid,
               attrs.expected_blob_oid,
               Map.get(attrs, :content, ""),
               signature(attrs.author),
               signature(attrs.committer),
               attrs.message,
               bounds(opts, :content_deadline_ms)
             ),
             :plan_content_change
           ) do
      objects = if blob, do: [{blob, "blob", attrs.content} | objects], else: objects

      {:ok,
       %ContentPlan{
         action: attrs.action,
         ref: attrs.ref,
         path: attrs.path,
         expected_ref_oid: attrs.expected_ref_oid,
         expected_blob_oid: old_blob,
         proposed_blob_oid: blob,
         proposed_tree_oid: tree,
         proposed_commit_oid: commit,
         object_batch: objects
       }}
    end
  end

  def write_content_change(path, %ContentPlan{} = plan, opts \\ []) do
    with {:ok, _} <-
           wrap(
             Native.write_content_objects(
               path,
               plan.object_batch,
               bounds(opts, :content_deadline_ms)
             ),
             :write_content_change
           ),
         do: {:ok, plan.proposed_commit_oid}
  end

  def refs(path, opts \\ []) do
    ScanLimiter.with_permit(:api_refs, fn ->
      wrap(Native.api_refs(path, bounds(opts)), :api_refs)
    end)
  end

  def branch_page(path, opts \\ []) do
    with {:ok, refs} <- refs(path, opts) do
      branches =
        Enum.filter(refs, fn {name, _, kind} ->
          String.starts_with?(name, "refs/heads/") and kind == "commit"
        end)

      page = Keyword.get(opts, :page, 1)
      per_page = Keyword.get(opts, :per_page, 30)

      {:ok,
       %{
         entries:
           branches
           |> Enum.drop((page - 1) * per_page)
           |> Enum.take(per_page)
           |> Enum.map(fn {ref, oid, _} ->
             %{
               name: String.replace_prefix(ref, "refs/heads/", ""),
               ref: ref,
               oid: oid,
               protected: false
             }
           end),
         total: length(branches),
         page: page,
         per_page: per_page
       }}
    end
  end

  def commit_value(path, ref, opts \\ []) do
    ScanLimiter.with_permit(:api_commit, fn ->
      with {:ok, value} <- wrap(Native.api_commit(path, ref, bounds(opts)), :api_commit),
           do: {:ok, commit(value)}
    end)
  end

  def commit_page(path, opts) do
    ScanLimiter.with_permit(:api_commits, fn ->
      page = Keyword.get(opts, :page, 1)
      per_page = Keyword.get(opts, :per_page, 30)

      with {:ok, {commits, total}} <-
             wrap(
               Native.api_commits(
                 path,
                 Keyword.fetch!(opts, :sha),
                 page,
                 per_page,
                 Keyword.get(opts, :path, ""),
                 Keyword.get(opts, :author),
                 Keyword.get(opts, :since),
                 Keyword.get(opts, :until),
                 bounds(opts)
               ),
               :api_commits
             ) do
        {:ok,
         %{entries: Enum.map(commits, &commit/1), total: total, page: page, per_page: per_page}}
      end
    end)
  end

  def commit_detail(path, ref, opts \\ []) do
    opts = deadline_options(opts)

    with {:ok, commit} <- commit_value(path, ref, opts),
         {:ok, diff} <-
           GitCore.diff_commit(path, commit.oid, Keyword.put(opts, :deadline_ms, remaining(opts))),
         false <- diff.truncated,
         true <-
           diff.changed_files <= Limits.get(:changed_path_visits) and
             byte_size(diff.patch) <= Limits.get(:patch_bytes) do
      {:ok, Map.put(commit, :diff, diff)}
    else
      {:error, _} = error -> error
      _ -> {:error, %Error{kind: :scan_work_limit, operation: :commit_detail}}
    end
  end

  def content_metadata(path, ref, content_path, opts \\ []) do
    ScanLimiter.with_permit(:api_content, fn ->
      with {:ok, {directory, entries}} <-
             wrap(Native.api_content(path, ref, content_path, bounds(opts)), :api_content) do
        {:ok, directory,
         Enum.map(entries, fn {type, name, path, oid, size, mode} ->
           %ContentEntry{type: type, name: name, path: path, oid: oid, size: size, mode: mode}
         end)}
      end
    end)
  end

  def content(path, ref, content_path, opts \\ []) do
    opts = deadline_options(opts)

    with {:ok, commit} <- commit_value(path, ref, opts),
         {:ok, directory, entries} <- content_metadata(path, commit.oid, content_path, opts) do
      if directory do
        {:ok, entries}
      else
        [entry] = entries

        if entry.type == "submodule" do
          {:ok, entry}
        else
          read_blob(path, entry, opts)
        end
      end
    end
  end

  defp read_blob(path, entry, opts) do
    cond do
      entry.size > Limits.get(:blob_bytes) ->
        {:error, %Error{kind: :blob_too_large, operation: :api_blob}}

      remaining(opts) <= 0 ->
        {:error, %Error{kind: :scan_timeout, operation: :api_blob}}

      true ->
        with {:ok, lease} <- GitCore.BlobLimiter.acquire(entry.size, operation: :api_blob) do
          try do
            case wrap(Native.api_blob(path, entry.oid, entry.size, bounds(opts)), :api_blob) do
              {:ok, bytes} ->
                {:ok, %{entry | content: bytes, lease: lease}}

              error ->
                GitCore.BlobLimiter.release(lease)
                error
            end
          rescue
            exception ->
              GitCore.BlobLimiter.release(lease)
              reraise exception, __STACKTRACE__
          end
        end
    end
  end

  def release_content(%ContentEntry{lease: lease}) when not is_nil(lease),
    do: GitCore.BlobLimiter.release(lease)

  def release_content(_), do: :ok

  defp signature(%GitCore.Signature{} = value),
    do:
      {:binary.bin_to_list(value.name), :binary.bin_to_list(value.email), value.seconds,
       value.offset_minutes}

  defp commit({{oid, _title, message, {name, email, seconds}, {cn, ce, cs}, parents}, tree}) do
    %{
      oid: oid,
      tree_oid: tree,
      message: message,
      parents: parents,
      author: %{name: name, email: email, seconds: seconds},
      committer: %{name: cn, email: ce, seconds: cs}
    }
  end

  defp wrap({:ok, value}, _), do: {:ok, value}

  defp wrap({:error, {kind, _detail}}, operation) do
    # Only compiled, stable native error codes cross this boundary.
    kind =
      case kind do
        "ref_not_found" -> :ref_not_found
        "commit_not_found" -> :commit_not_found
        "path_not_found" -> :path_not_found
        "invalid_input" -> :invalid_input
        "tree_entry_limit" -> :tree_entry_limit
        "commit_limit" -> :commit_limit
        "scan_byte_limit" -> :scan_byte_limit
        "blob_too_large" -> :blob_too_large
        "scan_timeout" -> :scan_timeout
        _ -> :storage_unavailable
      end

    {:error, %Error{kind: kind, operation: operation}}
  end
end
