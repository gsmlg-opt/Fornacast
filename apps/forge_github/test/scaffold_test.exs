defmodule ForgeGitHub.ScaffoldTest do
  use ExUnit.Case, async: true

  test "application starts without provider workers" do
    supervisor = Process.whereis(ForgeGitHub.Supervisor)

    assert is_pid(supervisor)
    assert [] = Supervisor.which_children(supervisor)
  end

  test "context exposes only compile-time provider boundary types" do
    assert {:ok, types} = Code.Typespec.fetch_types(ForgeGitHub)

    assert types
           |> Enum.map(fn {_kind, {name, _definition, args}} -> {name, length(args)} end)
           |> Enum.sort() == [external_id: 0, installation_id: 0, provider: 0]
  end
end
