defmodule GitCore.Error do
  @enforce_keys [:kind, :operation]
  defstruct [:kind, :operation, :detail]
end

defmodule GitCore.RefSelector do
  @enforce_keys [:kind, :full_name]
  defstruct [:kind, :full_name]
end

defmodule GitCore.RefSummary do
  @enforce_keys [:branch_count, :tag_count, :branches, :tags, :refs_truncated]
  defstruct [:branch_count, :tag_count, :branches, :tags, :refs_truncated]
end

defmodule GitCore.RefPage do
  @enforce_keys [:refs, :total, :page, :per_page, :total_pages]
  defstruct [:refs, :total, :page, :per_page, :total_pages]
end

defmodule GitCore.Snapshot do
  @enforce_keys [:kind, :ref, :oid]
  defstruct [:kind, :ref, :oid]
end

defmodule GitCore.Ref do
  @moduledoc """
  A Git reference as exposed by Fornacast.
  """

  @enforce_keys [:name, :kind, :target]
  defstruct [:name, :kind, :target, :display_name]
end

defmodule GitCore.CommitSummary do
  @enforce_keys [:count, :latest]
  defstruct [:count, :latest]
end

defmodule GitCore.CommitPage do
  @enforce_keys [:commits, :total, :page, :per_page, :total_pages]
  defstruct [:commits, :total, :page, :per_page, :total_pages]
end

defmodule GitCore.Commit do
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

defmodule GitCore.TreeEntry do
  @moduledoc """
  A directory entry in a Git tree.
  """

  @enforce_keys [:name, :kind, :mode, :oid]
  defstruct [:name, :kind, :mode, :oid]
end

defmodule GitCore.TreeHistoryEntry do
  @enforce_keys [:name, :kind, :mode, :oid, :latest_commit]
  defstruct [:name, :kind, :mode, :oid, :latest_commit]
end

defmodule GitCore.TreePage do
  @enforce_keys [:entries, :total_entries, :page, :per_page, :total_pages]
  defstruct [:entries, :total_entries, :page, :per_page, :total_pages]
end

defmodule GitCore.Blob do
  @moduledoc """
  Bounded blob data read from a repository.
  """

  @enforce_keys [:name, :oid, :size, :data, :truncated, :binary]
  defstruct [:name, :oid, :size, :data, :truncated, :binary, :non_utf8, :lease]
end

defmodule GitCore.DiffLine do
  @enforce_keys [:type, :content]
  defstruct [:type, :old_line, :new_line, :content]
end

defmodule GitCore.DiffFile do
  @moduledoc """
  A file changed by a commit.
  """

  @enforce_keys [:path, :status, :old_oid, :new_oid, :binary]
  defstruct [
    :path,
    :status,
    :old_oid,
    :new_oid,
    :binary,
    :additions,
    :deletions,
    :truncated,
    :lines
  ]
end

defmodule GitCore.CommitDiff do
  @moduledoc """
  Bounded unified diff data for a commit.
  """

  @enforce_keys [:files, :patch, :truncated]
  defstruct [:files, :patch, :truncated, :changed_files, :additions, :deletions]
end

defmodule GitCore.SearchResult do
  @enforce_keys [:path]
  defstruct [:path, :line, :snippet]
end

defmodule GitCore.SearchResults do
  @enforce_keys [:scope, :results, :files_scanned, :bytes_scanned, :truncated_reasons]
  defstruct [:scope, :results, :files_scanned, :bytes_scanned, :truncated_reasons]
end

defmodule GitCore.LanguageStat do
  @enforce_keys [:language, :bytes]
  defstruct [:language, :bytes]
end

defmodule GitCore.RepositoryAnalysis do
  @enforce_keys [:languages, :total_bytes, :files_scanned, :bytes_scanned, :truncated]
  defstruct [:languages, :total_bytes, :files_scanned, :bytes_scanned, :truncated]
end
