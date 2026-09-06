defmodule ForgeMirrors.ResourceDecisionTest do
  use ExUnit.Case, async: true

  alias ForgeMirrors.ResourceDecision

  test "scalar values follow the confirmed three-way baseline" do
    assert {:confirm, "same"} = ResourceDecision.scalar("base", "same", "same")
    assert {:apply_remote, "base", "local"} = ResourceDecision.scalar("base", "local", "base")
    assert {:apply_local, "base", "remote"} = ResourceDecision.scalar("base", "base", "remote")
    assert {:conflict, :concurrent_edit} = ResourceDecision.scalar("base", "local", "remote")
    assert {:apply_remote, "body", nil} = ResourceDecision.scalar("body", nil, "body")
    assert {:apply_local, nil, "body"} = ResourceDecision.scalar(nil, nil, "body")
  end

  test "missing scalar baselines permit equality but never choose a winner" do
    assert {:confirm, "same"} = ResourceDecision.scalar(:missing, "same", "same")
    assert {:conflict, :missing_baseline} = ResourceDecision.scalar(:missing, "one", "two")
  end

  test "set deltas preserve independent additions and removals" do
    baseline = MapSet.new([1, 2])
    local = MapSet.new([2, 3])
    remote = MapSet.new([1, 4])
    merged = MapSet.new([3, 4])
    assert {:apply_both, ^local, ^remote, ^merged} = ResourceDecision.set(baseline, local, remote)
    assert {:apply_remote, ^baseline, ^local} = ResourceDecision.set(baseline, local, baseline)
    assert {:apply_local, ^baseline, ^remote} = ResourceDecision.set(baseline, baseline, remote)
    assert {:confirm, ^local} = ResourceDecision.set(baseline, local, local)
  end

  test "unknown set baselines do not silently merge" do
    local = MapSet.new([1])
    remote = MapSet.new([2])
    assert {:confirm, ^local} = ResourceDecision.set(:missing, local, local)
    assert {:conflict, :missing_baseline} = ResourceDecision.set(:missing, local, remote)
  end

  test "all small set merges are symmetric and retain each baseline-relative change" do
    sets =
      for mask <- 0..7 do
        MapSet.new(for bit <- 0..2, Bitwise.band(mask, Bitwise.bsl(1, bit)) != 0, do: bit)
      end

    for baseline <- sets, local <- sets, remote <- sets do
      result = ResourceDecision.set(baseline, local, remote) |> merged()
      reverse = ResourceDecision.set(baseline, remote, local) |> merged()
      assert result == reverse

      for value <- 0..2 do
        expected =
          if MapSet.member?(baseline, value),
            do: MapSet.member?(local, value) and MapSet.member?(remote, value),
            else: MapSet.member?(local, value) or MapSet.member?(remote, value)

        assert MapSet.member?(result, value) == expected
      end
    end
  end

  defp merged({:confirm, value}), do: value
  defp merged({:apply_local, _expected, value}), do: value
  defp merged({:apply_remote, _expected, value}), do: value
  defp merged({:apply_both, _local, _remote, value}), do: value
end
