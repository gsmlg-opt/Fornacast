defmodule ForgeGitHub.PullCreateRecoveryTest do
  use ExUnit.Case, async: true
  alias ForgeGitHub.PullCreateRecovery, as: Recovery
  alias ForgeMirrors.CorrelationMarker

  @uuid "6a416164-9ac6-426b-b7bc-a6245e0c2940"

  test "initial recovery only authorizes a scan" do
    assert Recovery.decision(Recovery.initial()) == {:scan, 1}
  end

  test "an empty complete scan is ambiguous, never permission to create again" do
    assert {:ok, checkpoint} =
             Recovery.advance(Recovery.initial(), %{pulls: [], next_cursor: nil}, @uuid)

    assert Recovery.decision(checkpoint) == {:error, :ambiguous_external_effect}
  end

  test "a unique positive match is retained without body while remaining pages are scanned" do
    row = pull(91)

    assert {:ok, first} =
             Recovery.advance(Recovery.initial(), %{pulls: [row], next_cursor: 2}, @uuid)

    assert Recovery.decision(first) == {:scan, 2}
    refute JSON.encode!(first) =~ "body"
    assert byte_size(JSON.encode!(first)) < 1024
    assert {:ok, last} = Recovery.advance(first, %{pulls: [], next_cursor: nil}, @uuid)
    assert Recovery.decision(last) == {:found, identity(row)}
  end

  test "the same immutable object repeated by page drift is not a second candidate" do
    row = pull(91)
    {:ok, first} = Recovery.advance(Recovery.initial(), %{pulls: [row], next_cursor: 2}, @uuid)
    assert {:ok, last} = Recovery.advance(first, %{pulls: [row], next_cursor: nil}, @uuid)
    assert Recovery.decision(last) == {:found, identity(row)}
  end

  test "multiple identities or a changed node for the same ID conflict" do
    row = pull(91)
    {:ok, first} = Recovery.advance(Recovery.initial(), %{pulls: [row], next_cursor: 2}, @uuid)

    for second <- [pull(92), %{row | "node_id" => "PR_changed"}, %{row | "number" => 999}] do
      assert {:error, :ambiguous_external_effect} =
               Recovery.advance(first, %{pulls: [second], next_cursor: nil}, @uuid)
    end
  end

  test "only the expected terminal UUID marker supplies positive evidence" do
    {:ok, other} = CorrelationMarker.append(nil, Ecto.UUID.generate())

    rows = [
      Map.put(pull(91), "body", other),
      Map.put(pull(92), "body", "ordinary body"),
      Map.update!(pull(93), "body", &(&1 <> " no longer terminal"))
    ]

    {:ok, last} = Recovery.advance(Recovery.initial(), %{pulls: rows, next_cursor: nil}, @uuid)
    assert Recovery.decision(last) == {:error, :ambiguous_external_effect}
  end

  test "malformed pages and nonsequential cursors never advance recovery" do
    for page <- [
          %{pulls: [], next_cursor: 1},
          %{pulls: [], next_cursor: 3},
          %{pulls: List.duplicate(pull(91), 101), next_cursor: nil},
          %{pulls: [%{"body" => "untrusted"}], next_cursor: nil},
          %{pulls: [], next_cursor: nil, extra: true}
        ] do
      assert {:error, :invalid_recovery_page} = Recovery.advance(Recovery.initial(), page, @uuid)
    end

    assert {:error, :invalid_recovery_page} =
             Recovery.advance(Recovery.initial(), %{pulls: [], next_cursor: nil}, "not-a-uuid")
  end

  test "invalid or completed checkpoints cannot resume page ingestion" do
    for checkpoint <- [
          %{},
          %{"page" => 0, "complete" => false, "candidate" => nil},
          %{"page" => 1, "complete" => true, "candidate" => nil}
        ] do
      assert {:error, :invalid_recovery_page} =
               Recovery.advance(checkpoint, %{pulls: [], next_cursor: nil}, @uuid)
    end

    assert Recovery.decision(%{}) == {:error, :invalid_recovery_checkpoint}
  end

  defp pull(id) do
    {:ok, body} = CorrelationMarker.append(nil, @uuid)
    %{"id" => id, "node_id" => "PR_#{id}", "number" => id + 100, "body" => body}
  end

  defp identity(row),
    do: %{
      "github_object_id" => row["id"],
      "github_node_id" => row["node_id"],
      "github_number" => row["number"]
    }
end
