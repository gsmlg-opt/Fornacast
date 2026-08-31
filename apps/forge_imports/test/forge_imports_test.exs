defmodule ForgeImportsTest do
  use ExUnit.Case, async: true

  test "the coordinator exposes the supported provider" do
    assert ForgeImports.provider() == :github
  end
end
