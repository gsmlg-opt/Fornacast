defmodule GitCore.Native do
  @moduledoc false

  @type read_error :: {String.t(), String.t()}

  @darwin_target :erlang.system_info(:system_architecture) |> to_string()
  @target if String.ends_with?(@darwin_target, "-apple-darwin"), do: @darwin_target

  use Rustler,
    otp_app: :git_core,
    crate: "fornacast_git_core",
    mode: if(Mix.env() == :prod, do: :release, else: :debug),
    target: @target

  def init_bare(_path), do: :erlang.nif_error(:nif_not_loaded)
  def is_bare_repository(_path), do: :erlang.nif_error(:nif_not_loaded)
  def empty(_path), do: :erlang.nif_error(:nif_not_loaded)
  def list_refs(_path), do: :erlang.nif_error(:nif_not_loaded)
  def ref_summary(_path, _selected_ref), do: :erlang.nif_error(:nif_not_loaded)

  def ref_summary_for_route(_path, _route_segments),
    do: :erlang.nif_error(:nif_not_loaded)

  def ref_page(_path, _kind, _page, _per_page), do: :erlang.nif_error(:nif_not_loaded)
  def resolve_snapshot(_path, _kind, _full_name), do: :erlang.nif_error(:nif_not_loaded)
  def commit_summary(_path, _snapshot_oid, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  def commit_page(_path, _snapshot_oid, _page, _per_page, _deadline_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  def read_tree_with_history(
        _path,
        _snapshot_oid,
        _tree_path,
        _page,
        _per_page,
        _deadline_ms
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def commit_history(_path, _ref, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def commit(_path, _oid), do: :erlang.nif_error(:nif_not_loaded)
  def read_tree(_path, _ref, _tree_path), do: :erlang.nif_error(:nif_not_loaded)
  def blob_metadata(_path, _snapshot_oid, _blob_path), do: :erlang.nif_error(:nif_not_loaded)

  def read_blob_prefix(_path, _oid, _expected_size, _limit),
    do: :erlang.nif_error(:nif_not_loaded)

  def read_blob_complete(_path, _oid, _expected_size),
    do: :erlang.nif_error(:nif_not_loaded)

  def diff_commit(_path, _oid, _limit, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  def search_tree(
        _path,
        _snapshot_oid,
        _query,
        _scope,
        _file_limit,
        _byte_limit,
        _result_limit,
        _deadline_ms
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def repository_analysis(
        _path,
        _snapshot_oid,
        _file_limit,
        _byte_limit,
        _deadline_ms
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def repository_disk_usage(_path, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  def pack_objects(_path, _wants), do: :erlang.nif_error(:nif_not_loaded)
  def receive_pack(_path, _pack, _commands), do: :erlang.nif_error(:nif_not_loaded)
end
