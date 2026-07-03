defmodule GitCore.Native do
  @moduledoc false

  use Rustler,
    otp_app: :git_core,
    crate: "fornacast_git_core",
    mode: if(Mix.env() == :prod, do: :release, else: :debug)

  def init_bare(_path), do: :erlang.nif_error(:nif_not_loaded)
  def is_bare_repository(_path), do: :erlang.nif_error(:nif_not_loaded)
  def empty(_path), do: :erlang.nif_error(:nif_not_loaded)
  def list_refs(_path), do: :erlang.nif_error(:nif_not_loaded)
  def commit_history(_path, _ref, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def commit(_path, _oid), do: :erlang.nif_error(:nif_not_loaded)
  def read_tree(_path, _ref, _tree_path), do: :erlang.nif_error(:nif_not_loaded)
  def read_blob(_path, _ref, _blob_path, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def diff_commit(_path, _oid, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def pack_objects(_path, _wants), do: :erlang.nif_error(:nif_not_loaded)
  def receive_pack(_path, _pack, _commands), do: :erlang.nif_error(:nif_not_loaded)
end
