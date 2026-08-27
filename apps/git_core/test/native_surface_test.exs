defmodule GitCore.NativeSurfaceTest do
  use ExUnit.Case, async: true

  test "production native module excludes test-only primitives" do
    assert Code.ensure_loaded?(GitCore.Native)
    refute function_exported?(GitCore.Native, :test_dirty_io_wait, 2)
  end

  test "exports exactly the two anchored filesystem DirtyIo primitives" do
    assert Code.ensure_loaded?(GitCore.Native)
    assert function_exported?(GitCore.Native, :contained_tree_identity, 3)
    assert function_exported?(GitCore.Native, :remove_contained_tree, 4)

    source =
      __DIR__
      |> Path.join("../native/fornacast_git_core/src/lib.rs")
      |> File.read!()

    assert source =~
             ~r/#\[rustler::nif\(schedule = "DirtyIo"\)\]\s+fn contained_tree_identity\(/

    assert source =~
             ~r/#\[rustler::nif\(schedule = "DirtyIo"\)\]\s+fn remove_contained_tree\(/
  end
end
