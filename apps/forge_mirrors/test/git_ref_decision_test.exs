defmodule ForgeMirrors.GitRefDecisionTest do
  use ExUnit.Case, async: true

  alias ForgeMirrors.GitRefDecision

  @base String.duplicate("1", 40)
  @local String.duplicate("2", 40)
  @remote String.duplicate("3", 40)

  test "equal observations confirm one baseline without a write" do
    assert {:confirm, @local} = decide(:branch, @base, @local, @local, [])
    assert {:confirm, nil} = decide(:tag, @base, nil, nil, [])
  end

  test "one-sided branch creates and fast-forwards include exact expected targets" do
    assert {:apply_local, nil, @remote} =
             decide(:branch, nil, nil, @remote, [])

    assert {:apply_remote, nil, @local} =
             decide(:branch, nil, @local, nil, [])

    assert {:apply_local, @base, @remote} =
             decide(:branch, @base, @base, @remote, [{@base, @remote}])

    assert {:apply_remote, @base, @local} =
             decide(:branch, @base, @local, @base, [{@base, @local}])
  end

  test "compatible branch descendants converge even when both observations changed" do
    assert {:apply_local, @local, @remote} =
             decide(:branch, @base, @local, @remote, [{@local, @remote}])

    assert {:apply_remote, @remote, @local} =
             decide(:branch, @base, @local, @remote, [{@remote, @local}])
  end

  test "non-fast-forward branches produce one visible conflict" do
    assert {:conflict, :git_divergence} =
             decide(:branch, @base, @local, @remote, [])

    assert {:conflict, :git_divergence} =
             decide(:branch, @base, @base, @remote, [])
  end

  test "tags may be created or safely deleted but never retargeted" do
    assert {:apply_local, nil, @remote} = decide(:tag, nil, nil, @remote, [])
    assert {:apply_remote, nil, @local} = decide(:tag, nil, @local, nil, [])

    assert {:delete_local, @base} = decide(:tag, @base, @base, nil, [])
    assert {:delete_remote, @base} = decide(:tag, @base, nil, @base, [])

    assert {:conflict, :tag_retarget} = decide(:tag, @base, @base, @remote, [])
    assert {:conflict, :tag_retarget} = decide(:tag, @base, @local, @base, [])
  end

  test "deletion conflicts with an independently changed opposite side" do
    assert {:conflict, :delete_vs_update} = decide(:branch, @base, nil, @remote, [])
    assert {:conflict, :delete_vs_update} = decide(:branch, @base, @local, nil, [])
    assert {:conflict, :delete_vs_update} = decide(:tag, @base, nil, @remote, [])
  end

  test "an unknown baseline fails closed unless both observations already agree" do
    assert {:confirm, @local} = decide(:branch, :missing, @local, @local, [])
    assert {:conflict, :missing_baseline} = decide(:branch, :missing, nil, @remote, [])
    assert {:conflict, :missing_baseline} = decide(:tag, :missing, @local, nil, [])
  end

  test "ancestry failures are returned without choosing a write" do
    ancestor? = fn _ancestor, _descendant -> {:error, :repository_unavailable} end

    assert {:error, :repository_unavailable} =
             GitRefDecision.decide(:branch, @base, @base, @remote, ancestor?)
  end

  test "invalid ref kinds and object IDs are rejected before ancestry work" do
    probe = fn _ancestor, _descendant -> flunk("invalid input must not inspect ancestry") end

    assert {:error, :invalid_ref_state} =
             GitRefDecision.decide(:note, @base, @base, @remote, probe)

    assert {:error, :invalid_ref_state} =
             GitRefDecision.decide(:branch, "ABC", @base, @remote, probe)
  end

  defp decide(kind, baseline, local, remote, ancestors) do
    ancestor? = fn ancestor, descendant -> {:ok, {ancestor, descendant} in ancestors} end
    GitRefDecision.decide(kind, baseline, local, remote, ancestor?)
  end
end
