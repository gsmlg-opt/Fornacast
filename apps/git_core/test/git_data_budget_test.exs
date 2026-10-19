defmodule GitCore.GitDataBudgetTest do
  use ExUnit.Case, async: false

  test "one absolute Git-data deadline clamps all phases to the scan ceiling" do
    now = System.monotonic_time(:millisecond)
    maximum = GitCore.Limits.get(:scan_deadline_ms)
    options = GitCore.GitData.deadline_options(deadline_ms: maximum * 2)
    assert options[:deadline] >= now
    assert options[:deadline] <= System.monotonic_time(:millisecond) + maximum
    assert options[:deadline] < now + maximum * 2
    supplied = now + maximum * 2
    assert GitCore.GitData.deadline_options(deadline: supplied)[:deadline] < supplied
    expired = now - 100
    assert GitCore.GitData.deadline_options(deadline: expired)[:deadline] == expired
    assert {_, _, 0} = GitCore.GitData.bounds(deadline: expired)
  end
end
