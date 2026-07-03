defmodule GitCore do
  @moduledoc """
  Fornacast-owned API for low-level Git repository operations.
  """

  defmodule Ref do
    @moduledoc """
    A Git reference as exposed by Fornacast.
    """

    @enforce_keys [:name, :kind, :target]
    defstruct [:name, :kind, :target]
  end

  defmodule Commit do
    @moduledoc """
    A commit summary or detail as exposed by Fornacast.
    """

    @enforce_keys [
      :oid,
      :title,
      :message,
      :author_name,
      :author_email,
      :author_time,
      :committer_name,
      :committer_email,
      :committer_time,
      :parents
    ]
    defstruct [
      :oid,
      :title,
      :message,
      :author_name,
      :author_email,
      :author_time,
      :committer_name,
      :committer_email,
      :committer_time,
      :parents
    ]
  end

  defmodule TreeEntry do
    @moduledoc """
    A directory entry in a Git tree.
    """

    @enforce_keys [:name, :kind, :mode, :oid]
    defstruct [:name, :kind, :mode, :oid]
  end

  defmodule Blob do
    @moduledoc """
    Bounded blob data read from a repository.
    """

    @enforce_keys [:name, :oid, :size, :data, :truncated, :binary]
    defstruct [:name, :oid, :size, :data, :truncated, :binary]
  end

  defmodule DiffFile do
    @moduledoc """
    A file changed by a commit.
    """

    @enforce_keys [:path, :status, :old_oid, :new_oid, :binary]
    defstruct [:path, :status, :old_oid, :new_oid, :binary]
  end

  defmodule CommitDiff do
    @moduledoc """
    Bounded unified diff data for a commit.
    """

    @enforce_keys [:files, :patch, :truncated]
    defstruct [:files, :patch, :truncated]
  end

  def init_bare(path) when is_binary(path) do
    GitCore.Native.init_bare(path)
  end

  def is_bare_repository?(path) when is_binary(path) do
    GitCore.Native.is_bare_repository(path)
  end

  def empty?(path) when is_binary(path) do
    GitCore.Native.empty(path)
  end

  def list_refs(path) when is_binary(path) do
    with {:ok, refs} <- GitCore.Native.list_refs(path) do
      refs =
        Enum.map(refs, fn {name, kind, target} ->
          %Ref{name: name, kind: ref_kind(kind), target: target}
        end)

      {:ok, refs}
    end
  end

  def branches(path) when is_binary(path) do
    filter_refs(path, :branch)
  end

  def tags(path) when is_binary(path) do
    filter_refs(path, :tag)
  end

  def commit_history(path, ref, opts \\ []) when is_binary(path) and is_binary(ref) do
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, commits} <- GitCore.Native.commit_history(path, ref, limit) do
      {:ok, Enum.map(commits, &commit_from_native/1)}
    end
  end

  def commit(path, oid) when is_binary(path) and is_binary(oid) do
    with {:ok, commit} <- GitCore.Native.commit(path, oid) do
      {:ok, commit_from_native(commit)}
    end
  end

  def read_tree(path, ref, tree_path \\ "")
      when is_binary(path) and is_binary(ref) and is_binary(tree_path) do
    with {:ok, entries} <- GitCore.Native.read_tree(path, ref, tree_path) do
      entries =
        Enum.map(entries, fn {name, kind, mode, oid} ->
          %TreeEntry{name: name, kind: tree_entry_kind(kind), mode: mode, oid: oid}
        end)

      {:ok, entries}
    end
  end

  def read_blob(path, ref, blob_path, opts \\ [])
      when is_binary(path) and is_binary(ref) and is_binary(blob_path) do
    limit = Keyword.get(opts, :limit, 1_048_576)

    with {:ok, {name, oid, size, data, truncated, binary}} <-
           GitCore.Native.read_blob(path, ref, blob_path, limit) do
      data = IO.iodata_to_binary(data)

      {:ok,
       %Blob{
         name: name,
         oid: oid,
         size: size,
         data: data,
         truncated: truncated,
         binary: binary
       }}
    end
  end

  def diff_commit(path, oid, opts \\ []) when is_binary(path) and is_binary(oid) do
    limit = Keyword.get(opts, :limit, 200_000)

    with {:ok, {files, patch, truncated}} <- GitCore.Native.diff_commit(path, oid, limit) do
      files = Enum.map(files, &diff_file_from_native/1)
      {:ok, %CommitDiff{files: files, patch: patch, truncated: truncated}}
    end
  end

  def pack_objects(path, wants) when is_binary(path) and is_list(wants) do
    GitCore.Native.pack_objects(path, wants)
  end

  def receive_pack(path, pack, commands)
      when is_binary(path) and is_binary(pack) and is_list(commands) do
    GitCore.Native.receive_pack(path, pack, commands)
  end

  defp filter_refs(path, kind) do
    with {:ok, refs} <- list_refs(path) do
      {:ok, Enum.filter(refs, &(&1.kind == kind))}
    end
  end

  defp ref_kind("branch"), do: :branch
  defp ref_kind("tag"), do: :tag

  defp tree_entry_kind("tree"), do: :tree
  defp tree_entry_kind("blob"), do: :blob
  defp tree_entry_kind("commit"), do: :commit

  defp diff_status("added"), do: :added
  defp diff_status("modified"), do: :modified
  defp diff_status("deleted"), do: :deleted

  defp diff_file_from_native({path, status, old_oid, new_oid, binary}) do
    %DiffFile{
      path: path,
      status: diff_status(status),
      old_oid: old_oid,
      new_oid: new_oid,
      binary: binary
    }
  end

  defp commit_from_native(
         {oid, title, message, {author_name, author_email, author_time},
          {committer_name, committer_email, committer_time}, parents}
       ) do
    %Commit{
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
end
