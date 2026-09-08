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

  test "merge decision follows scalar three-way changes and returns only metadata" do
    for {local, remote, target, local?, remote?} <- [
          {"Baseline", "Baseline", "Baseline", false, false},
          {"Local", "Baseline", "Local", false, true},
          {"Baseline", "Remote", "Remote", true, false},
          {"Same", "Same", "Same", false, false}
        ] do
      local_issue = issue(%{"title" => local})
      remote_issue = issue(%{"title" => remote})

      assert {:ok, result} =
               PullMetadataDecision.decide_merge(
                 pull(),
                 companion(pull(), local_issue),
                 companion(pull(), remote_issue),
                 issue(),
                 local_issue,
                 remote_issue
               )

      assert result == %{
               target_metadata: %{
                 "title" => target,
                 "body" => "Body",
                 "draft" => false,
                 "label_github_ids" => [10],
                 "assignee_github_ids" => [20]
               },
               apply_local?: local?,
               remote_issue_effect?: remote?
             }
    end

    local = issue(%{"title" => "Local"})
    remote = issue(%{"title" => "Remote"})

    assert {:conflict, :concurrent_edit} =
             PullMetadataDecision.decide_merge(
               pull(),
               companion(pull(), local),
               companion(pull(), remote),
               issue(),
               local,
               remote
             )
  end

  test "merge decision combines independent scalar edits and relationship deltas" do
    local =
      issue(%{"title" => "Local", "label_github_ids" => [10, 11], "assignee_github_ids" => []})

    remote =
      issue(%{
        "body" => "Remote",
        "label_github_ids" => [10, 12],
        "assignee_github_ids" => [20, 21]
      })

    assert {:ok, result} =
             PullMetadataDecision.decide_merge(
               pull(),
               companion(pull(), local),
               companion(pull(), remote),
               issue(),
               local,
               remote
             )

    assert result == %{
             target_metadata: %{
               "title" => "Local",
               "body" => "Remote",
               "draft" => false,
               "label_github_ids" => [10, 11, 12],
               "assignee_github_ids" => [21]
             },
             apply_local?: true,
             remote_issue_effect?: true
           }
  end

  test "merge decision ignores valid coordinator-owned state and refs without projecting them" do
    remote_issue = issue(%{"state" => "closed", "state_reason" => "completed"})

    remote_pull =
      companion(pull(), remote_issue)
      |> Map.put("base_sha", String.duplicate("c", 40))
      |> Map.put("head_ref", "refs/heads/other")

    assert {:ok, result} =
             PullMetadataDecision.decide_merge(
               pull(),
               pull(),
               remote_pull,
               issue(),
               issue(),
               remote_issue
             )

    refute result.apply_local?
    refute result.remote_issue_effect?

    assert Enum.sort(Map.keys(result.target_metadata)) ==
             ~w(assignee_github_ids body draft label_github_ids title)

    assert remote_pull["base_sha"] == String.duplicate("c", 40)
    assert remote_issue["state_reason"] == "completed"
  end

  test "merge decision rejects drafts in every view and malformed paired snapshots" do
    for position <- 0..2 do
      args =
        [pull(), pull(), pull(), issue(), issue(), issue()]
        |> List.update_at(position, &Map.put(&1, "draft", true))

      assert {:conflict, :merged_draft_conflict} =
               apply(PullMetadataDecision, :decide_merge, args)
    end

    for {position, field, value} <- [
          {0, "base_sha", "bad"},
          {1, "extra", true},
          {2, "title", "mismatch"},
          {3, "label_github_ids", [10, 10]},
          {4, "assignee_github_ids", [0]},
          {5, "title", "mismatch"}
        ] do
      args =
        [pull(), pull(), pull(), issue(), issue(), issue()]
        |> List.update_at(position, &Map.put(&1, field, value))

      assert {:error, :invalid_projection} = apply(PullMetadataDecision, :decide_merge, args)
    end
  end

  test "merge decision rejects relationship unions exceeding the target limit" do
    for field <- ~w(label_github_ids assignee_github_ids) do
      baseline = issue(%{field => []})
      local = issue(%{field => Enum.to_list(1..512)})
      remote = issue(%{field => Enum.to_list(513..1024)})

      assert {:error, :invalid_projection} =
               PullMetadataDecision.decide_merge(
                 pull(),
                 companion(pull(), local),
                 companion(pull(), remote),
                 baseline,
                 local,
                 remote
               )
    end
  end

  test "merge decision rejects incompatible newer local state and allows baseline or final state" do
    for {state, reason} <- [{"closed", "not_planned"}, {"open", "reopened"}] do
      local = issue(%{"state" => state, "state_reason" => reason})

      assert {:conflict, :merged_state_conflict} =
               PullMetadataDecision.decide_merge(
                 pull(),
                 companion(pull(), local),
                 pull(),
                 issue(),
                 local,
                 issue()
               )
    end

    for local <- [issue(), issue(%{"state" => "closed", "state_reason" => "completed"})] do
      assert {:ok, %{target_metadata: metadata}} =
               PullMetadataDecision.decide_merge(
                 pull(),
                 companion(pull(), local),
                 pull(),
                 issue(),
                 local,
                 issue()
               )

      refute Map.has_key?(metadata, "state")
      refute Map.has_key?(metadata, "state_reason")
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
