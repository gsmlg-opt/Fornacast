defmodule ForgeMirrors.ScaffoldTest do
  use ExUnit.Case, async: true

  test "application starts the bounded coordinator tree" do
    supervisor = Process.whereis(ForgeMirrors.Supervisor)

    assert is_pid(supervisor)

    children = Supervisor.which_children(supervisor)
    assert length(children) == 4
    assert is_pid(Process.whereis(ForgeMirrors.TaskSupervisor))
    assert is_pid(Process.whereis(ForgeMirrors.OperationReconciler))
    assert is_pid(Process.whereis(ForgeMirrors.OutboxDispatcher))
    assert is_pid(Process.whereis(ForgeMirrors.PeriodicReconciler))
  end

  test "context keeps provider-neutral mirror boundary types" do
    assert {:ok, types} = Code.Typespec.fetch_types(ForgeMirrors)

    assert types
           |> Enum.map(fn {_kind, {name, _definition, args}} -> {name, length(args)} end)
           |> Enum.sort() == [direction: 0, provider: 0, resource_kind: 0]
  end
end
