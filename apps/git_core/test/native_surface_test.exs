defmodule GitCore.NativeSurfaceTest do
  use ExUnit.Case, async: true

  test "production native module excludes test-only primitives" do
    assert Code.ensure_loaded?(GitCore.Native)
    refute function_exported?(GitCore.Native, :test_dirty_io_wait, 2)
  end
end
