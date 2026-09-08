defmodule ForgeGitHub.PullMetadataRecoveryTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.PullMetadataRecovery

  test "builds an exact immutable full-set recovery fragment" do
    local = issue(%{"label_github_ids" => [10, 11]})
    remote = issue()
    target = issue(%{"label_github_ids" => [10, 11]})

    assert {:ok,
            %{
              "v" => 1,
              "expected_local_issue" => ^local,
              "expected_remote_issue" => ^remote,
              "target_issue" => ^target
            }} = PullMetadataRecovery.build(local, remote, target)
  end

  test "classifies an unchanged remote preimage as not applied" do
    local = issue(%{"label_github_ids" => [10, 11]})
    remote = issue()
    target = issue(%{"label_github_ids" => [10, 11]})
    {:ok, payload} = PullMetadataRecovery.build(local, remote, target)

    assert {:ok,
            %{
              status: :not_applied,
              expected_local_issue: ^local,
              current_local_issue: ^local,
              expected_remote_issue: ^remote,
              target_issue: ^target
            }} = PullMetadataRecovery.classify(payload, local, remote)
  end

  test "classifies the target as applied without reconstructing newer local memberships" do
    expected_local = issue(%{"label_github_ids" => [10, 11]})
    expected_remote = issue()
    target = issue(%{"label_github_ids" => [10, 11]})
    current_local = issue(%{"label_github_ids" => [10, 11, 12], "assignee_github_ids" => []})
    {:ok, payload} = PullMetadataRecovery.build(expected_local, expected_remote, target)

    assert {:ok, result} = PullMetadataRecovery.classify(payload, current_local, target)
    assert result.status == :applied
    assert result.expected_local_issue == expected_local
    assert result.current_local_issue == current_local
    assert result.expected_remote_issue == expected_remote
    assert result.target_issue == target
    assert result.current_local_issue["label_github_ids"] == [10, 11, 12]
    assert result.current_local_issue["assignee_github_ids"] == []
  end

  test "classifies a third valid remote state as an ambiguous external effect" do
    local = issue(%{"label_github_ids" => [10, 11]})
    remote = issue()
    target = issue(%{"label_github_ids" => [10, 11]})
    third = issue(%{"label_github_ids" => [10, 12]})
    {:ok, payload} = PullMetadataRecovery.build(local, remote, target)

    assert {:conflict, :ambiguous_external_effect} =
             PullMetadataRecovery.classify(payload, local, third)
  end

  test "rejects a no-op effect fragment whose preimage already equals its target" do
    snapshot = issue()

    assert {:error, :invalid_projection} =
             PullMetadataRecovery.build(snapshot, snapshot, snapshot)
  end

  test "strictly validates snapshots and the exact marker shape" do
    local = issue(%{"label_github_ids" => [10, 11]})
    remote = issue()
    target = issue(%{"label_github_ids" => [10, 11]})
    {:ok, payload} = PullMetadataRecovery.build(local, remote, target)

    invalid_snapshots = [
      Map.put(local, "extra", true),
      Map.put(local, "label_github_ids", [10, 10]),
      Map.put(local, "assignee_github_ids", [21, 20]),
      Map.put(local, "label_github_ids", [0]),
      Map.put(local, "label_github_ids", Enum.to_list(1..513)),
      Map.put(local, "state_reason", "completed"),
      Map.put(local, "body", String.duplicate("界", 65_537))
    ]

    for invalid <- invalid_snapshots do
      assert {:error, :invalid_projection} =
               PullMetadataRecovery.build(invalid, remote, target)

      assert {:error, :invalid_projection} =
               PullMetadataRecovery.classify(payload, invalid, remote)
    end

    for invalid_payload <- [
          Map.put(payload, "extra", true),
          Map.put(payload, "v", 2),
          Map.put(payload, "expected_local_issue", %{}),
          Map.put(payload, "target_issue", payload["expected_remote_issue"])
        ] do
      assert {:error, :invalid_projection} =
               PullMetadataRecovery.classify(invalid_payload, local, remote)
    end
  end

  test "accepts the exact relationship, identity, and body bounds" do
    ids = Enum.to_list(1..511) ++ [9_223_372_036_854_775_807]
    local = issue(%{"body" => String.duplicate("界", 65_536), "label_github_ids" => ids})
    remote = issue(%{"body" => String.duplicate("界", 65_536), "label_github_ids" => []})
    target = issue(%{"body" => String.duplicate("界", 65_536), "label_github_ids" => ids})

    assert {:ok, payload} = PullMetadataRecovery.build(local, remote, target)

    assert {:ok, %{status: :applied, current_local_issue: ^local}} =
             PullMetadataRecovery.classify(payload, local, target)
  end

  defp issue(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Baseline",
        "body" => "Body",
        "state" => "open",
        "state_reason" => nil,
        "label_github_ids" => [10],
        "assignee_github_ids" => [20]
      },
      overrides
    )
  end
end
