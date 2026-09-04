defmodule ForgeMirrors.ScaffoldTest do
  use ExUnit.Case, async: true

  test "application starts without synchronization workers" do
    supervisor = Process.whereis(ForgeMirrors.Supervisor)

    assert is_pid(supervisor)
    assert [] = Supervisor.which_children(supervisor)
  end

  test "context exposes only compile-time mirror boundary types" do
    assert {:ok, types} = Code.Typespec.fetch_types(ForgeMirrors)

    assert types
           |> Enum.map(fn {_kind, {name, _definition, args}} -> {name, length(args)} end)
           |> Enum.sort() == [direction: 0, provider: 0, resource_kind: 0]
  end
end
