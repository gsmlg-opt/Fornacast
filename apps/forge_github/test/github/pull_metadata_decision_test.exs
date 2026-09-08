defmodule ForgeGitHub.PullMetadataDecisionTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.PullMetadataDecision

  test "confirms identical paired pull and canonical issue views" do
    pull = pull()
    issue = issue()

    assert {:ok,
            %{
              target_pull: ^pull,
              target_issue: ^issue,
              apply_local?: false,
              remote_issue_effect?: false,
              draft_effect?: false,
              local_issue: ^issue,
              remote_issue: ^issue
            }} = PullMetadataDecision.decide(pull, pull, pull, issue, issue, issue)
  end

  test "merges scalar and set deltas without embedding relationships in the pull snapshot" do
    baseline_pull = pull()
    baseline_issue = issue(%{"label_github_ids" => [10, 11], "assignee_github_ids" => [20]})

    local_issue =
      issue(%{
        "title" => "Local title",
        "label_github_ids" => [10, 11, 12],
        "assignee_github_ids" => []
      })

    remote_issue =
      issue(%{
        "body" => "Remote body",
        "label_github_ids" => [10, 11, 13],
        "assignee_github_ids" => [20, 21]
      })

    local_pull = companion(baseline_pull, local_issue) |> Map.put("draft", true)
    remote_pull = companion(baseline_pull, remote_issue)

    assert {:ok, decision} =
             PullMetadataDecision.decide(
               baseline_pull,
               local_pull,
               remote_pull,
               baseline_issue,
               local_issue,
               remote_issue
             )

    assert decision.apply_local?
    assert decision.remote_issue_effect?
    assert decision.draft_effect?
    assert decision.local_issue == local_issue
    assert decision.remote_issue == remote_issue

    assert decision.target_issue == %{
             "title" => "Local title",
             "body" => "Remote body",
             "state" => "open",
             "state_reason" => nil,
             "label_github_ids" => [10, 11, 12, 13],
             "assignee_github_ids" => [21]
           }

    assert decision.target_pull ==
             baseline_pull
             |> Map.merge(Map.take(decision.target_issue, ~w(title body state state_reason)))
             |> Map.put("draft", true)

    refute Map.has_key?(decision.target_pull, "label_github_ids")
    refute Map.has_key?(decision.target_pull, "assignee_github_ids")
  end

  test "marks a remote-only relationship change for local application only" do
    baseline_pull = pull()
    baseline_issue = issue()
    remote_issue = issue(%{"label_github_ids" => [10, 11]})
    remote_pull = companion(baseline_pull, remote_issue)

    assert {:ok,
            %{
              target_issue: %{"label_github_ids" => [10, 11]},
              apply_local?: true,
              remote_issue_effect?: false,
              draft_effect?: false
            }} =
             PullMetadataDecision.decide(
               baseline_pull,
               baseline_pull,
               remote_pull,
               baseline_issue,
               baseline_issue,
               remote_issue
             )
  end

  test "returns a scalar conflict when both sides changed incompatibly" do
    baseline_pull = pull()
    baseline_issue = issue()
    local_issue = issue(%{"title" => "Local"})
    remote_issue = issue(%{"title" => "Remote"})

    assert {:conflict, :concurrent_edit} =
             PullMetadataDecision.decide(
               baseline_pull,
               companion(baseline_pull, local_issue),
               companion(baseline_pull, remote_issue),
               baseline_issue,
               local_issue,
               remote_issue
             )
  end

  test "rejects every head or base ref change as a pull ref conflict" do
    baseline_pull = pull()
    baseline_issue = issue()

    for field <- ~w(head_ref head_sha base_ref base_sha) do
      changed =
        case field do
          ref when ref in ~w(head_ref base_ref) -> "refs/heads/replaced"
          _sha -> String.duplicate("c", 40)
        end

      assert {:conflict, :pull_ref_mismatch} =
               PullMetadataDecision.decide(
                 baseline_pull,
                 Map.put(baseline_pull, field, changed),
                 baseline_pull,
                 baseline_issue,
                 baseline_issue,
                 baseline_issue
               )
    end
  end

  test "rejects malformed snapshots, relationship sets, and incoherent companions" do
    pull = pull()
    issue = issue()

    invalid = [
      {Map.put(pull, "github_object_id", 1), pull, pull, issue, issue, issue},
      {Map.put(pull, "body", String.duplicate("x", 262_145)), pull, pull, issue, issue, issue},
      {pull, pull, pull, Map.put(issue, "label_github_ids", [10, 10]), issue, issue},
      {pull, pull, pull, issue, Map.put(issue, "assignee_github_ids", [21, 20]), issue},
      {pull, pull, pull, issue, issue, Map.put(issue, "label_github_ids", [0])},
      {pull, pull, pull, issue, issue,
       Map.put(issue, "assignee_github_ids", Enum.to_list(1..513))},
      {pull, pull, pull, issue, Map.put(issue, "title", "Does not match pull"), issue}
    ]

    for arguments <- invalid do
      assert {:error, :invalid_projection} =
               apply(PullMetadataDecision, :decide, Tuple.to_list(arguments))
    end
  end

  defp pull do
    %{
      "title" => "Baseline",
      "body" => "Body",
      "state" => "open",
      "state_reason" => nil,
      "draft" => false,
      "head_ref" => "refs/heads/feature",
      "head_sha" => String.duplicate("a", 40),
      "base_ref" => "refs/heads/main",
      "base_sha" => String.duplicate("b", 40)
    }
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

  defp companion(pull, issue),
    do: Map.merge(pull, Map.take(issue, ~w(title body state state_reason)))
end
