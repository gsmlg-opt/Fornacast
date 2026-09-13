defmodule ForgeGitHub.PullMergeObservationTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.Repo
  alias ForgeGitHub.PullMergeObservation

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture()
    owner = Repo.get!(ForgeAccounts.User, organization.organization_id)
    actor = organization_owner_fixture(organization)

    {:ok, repository} =
      ForgeRepos.create_repository(owner, %{
        name: "observation",
        slug: "observation",
        visibility: :private
      })

    binding = repository_mirror_fixture(organization, %{repository_id: repository.id})

    issue =
      Repo.insert!(%ForgeIssues.Issue{
        repository_id: repository.id,
        number: 7,
        kind: :pull_request,
        title: "Local newer title",
        author_user_id: actor.id
      })

    b = String.duplicate("a", 40)
    h = String.duplicate("b", 40)
    m = String.duplicate("c", 40)

    pull =
      Repo.insert!(%ForgePulls.PullRequest{
        issue_id: issue.id,
        repository_id: repository.id,
        head_repository_id: repository.id,
        head_ref: "refs/heads/feature",
        base_ref: "refs/heads/main",
        head_sha: h,
        base_sha: b
      })

    label =
      Repo.insert!(
        ForgeIssues.Label.changeset(%ForgeIssues.Label{repository_id: repository.id}, %{
          name: "known",
          normalized_name: "known",
          color: "112233"
        })
      )

    Repo.insert!(%ForgeIssues.IssueLabel{issue_id: issue.id, label_id: label.id})

    Repo.insert!(
      ForgeMirrors.MirrorResourceState.persistence_changeset(
        %ForgeMirrors.MirrorResourceState{},
        %{
          repository_mirror_id: binding.id,
          resource_kind: :label,
          local_resource_type: "ForgeIssues.Label",
          local_resource_id: label.id,
          github_object_id: 800,
          github_node_id: "L_800",
          confirmed_snapshot: %{},
          state: :confirmed
        }
      )
    )

    identity =
      Repo.insert!(
        ForgeAccounts.GitHubIdentity.observed_changeset(%ForgeAccounts.GitHubIdentity{}, %{
          github_user_id: 801,
          github_node_id: "U_801",
          login: "known"
        })
      )

    Repo.insert!(%ForgeIssues.IssueAssignee{issue_id: issue.id, github_identity_id: identity.id})

    remote_repo = %{
      "id" => binding.github_repository_id,
      "node_id" => binding.github_node_id,
      "full_name" => "org/repo"
    }

    provider_identity = %{
      "github_issue_object_id" => 901,
      "github_issue_node_id" => "I_901",
      "github_number" => 7,
      "base_repository" => Map.take(remote_repo, ["id", "node_id"]),
      "head_repository" => Map.take(remote_repo, ["id", "node_id"])
    }

    sync = %{
      repository_id: repository.id,
      repository_mirror_id: binding.id,
      expected: %{pull_id: pull.id, provider_identity: provider_identity},
      provider_pull_identity: %{"id" => 902, "node_id" => "PR_902"},
      intent: %{
        merge_oid: m,
        expected_base_oid: b,
        expected_head_oid: h,
        base_ref: pull.base_ref,
        head_ref: pull.head_ref
      }
    }

    raw_issue = %{
      "id" => 901,
      "node_id" => "I_901",
      "number" => 7,
      "title" => "Remote title",
      "body" => nil,
      "state" => "closed",
      "state_reason" => "completed",
      "labels" => [%{"id" => 800, "node_id" => "L_800", "name" => "known"}],
      "assignees" => [%{"id" => 801, "node_id" => "U_801", "login" => "known"}],
      "user" => %{"id" => 801},
      "created_at" => "2026-09-01T00:00:00Z",
      "updated_at" => "2026-09-08T00:00:00Z"
    }

    raw_pull =
      Map.merge(Map.take(raw_issue, ~w(number title body state created_at updated_at)), %{
        "id" => 902,
        "node_id" => "PR_902",
        "draft" => false,
        "merged" => true,
        "merged_at" => "2026-09-08T00:00:00Z",
        "merge_commit_sha" => m,
        "mergeable" => nil,
        "rebaseable" => nil,
        "mergeable_state" => "unknown",
        "head" => %{"ref" => "feature", "sha" => h, "repo" => remote_repo},
        "base" => %{"ref" => "main", "sha" => m, "repo" => remote_repo}
      })

    %{sync: sync, pair: %{pull: raw_pull, issue: raw_issue}, m: m}
  end

  test "normalizes exact merge proof using existing relationship identities", %{
    sync: sync,
    pair: pair,
    m: m
  } do
    assert {:ok, result} = PullMergeObservation.build(sync, pair, m)
    assert result.remote_base_oid == m
    assert result.pull.confirmed_snapshot["title"] == "Remote title"

    assert result.pull.confirmed_merge_state == %{
             "merged_at" => "2026-09-08T00:00:00Z",
             "merge_commit_sha" => m
           }

    assert result.issue.confirmed_snapshot["label_github_ids"] == [800]
    assert result.issue.confirmed_snapshot["assignee_github_ids"] == [801]
    assert %DateTime{} = result.pull.remote_updated_at
    refute Map.has_key?(result.pull, :local_version)
  end

  test "rejects contradictory identities, refs, merge facts and malformed times", %{
    sync: sync,
    pair: pair,
    m: m
  } do
    for {path, value} <- [
          {[:pull, "id"], 903},
          {[:pull, "node_id"], "PR_wrong"},
          {[:issue, "id"], 903},
          {[:issue, "node_id"], "I_wrong"},
          {[:issue, "number"], 8},
          {[:pull, "merged"], false},
          {[:pull, "merge_commit_sha"], String.duplicate("d", 40)},
          {[:pull, "base", "sha"], String.duplicate("d", 40)},
          {[:pull, "head", "sha"], m},
          {[:pull, "base", "ref"], "other"},
          {[:pull, "base", "repo", "node_id"], "R_wrong"},
          {[:pull, "head", "repo", "id"], 999},
          {[:pull, "merged_at"], "invalid"},
          {[:issue, "updated_at"], "invalid"}
        ] do
      assert {:error, _} = PullMergeObservation.build(sync, put_in(pair, path, value), m)
    end

    assert {:error, _} = PullMergeObservation.build(sync, pair, sync.intent.expected_base_oid)
    assert {:error, _} = PullMergeObservation.build(sync, %{pull: %{}, issue: %{}}, m)
  end

  test "uses confirmed branch result when GitHub retains historical pull base and null issue reason",
       %{sync: sync, pair: pair, m: m} do
    pair =
      pair
      |> put_in([:pull, "base", "sha"], sync.intent.expected_base_oid)
      |> put_in([:issue, "state_reason"], nil)

    assert {:ok, result} = PullMergeObservation.build(sync, pair, m)
    assert result.pull.provider_base_oid == sync.intent.expected_base_oid
    assert result.issue.provider_state_reason == nil
    assert result.pull.confirmed_snapshot["base_sha"] == m
    assert result.pull.confirmed_snapshot["state_reason"] == "completed"
    assert result.issue.confirmed_snapshot["state_reason"] == "completed"
    assert {:error, _} = PullMergeObservation.build(sync, pair, sync.intent.expected_base_oid)

    for reason <- ["not_planned", "reopened"] do
      assert {:error, _} =
               PullMergeObservation.build(sync, put_in(pair, [:issue, "state_reason"], reason), m)
    end
  end

  test "observes known provider memberships absent from the local issue without writes", c do
    label =
      Repo.insert!(
        ForgeIssues.Label.changeset(%ForgeIssues.Label{repository_id: c.sync.repository_id}, %{
          name: "remote-known",
          normalized_name: "remote-known",
          color: "223344"
        })
      )

    Repo.insert!(
      ForgeMirrors.MirrorResourceState.persistence_changeset(
        %ForgeMirrors.MirrorResourceState{},
        %{
          repository_mirror_id: c.sync.repository_mirror_id,
          resource_kind: :label,
          local_resource_type: "ForgeIssues.Label",
          local_resource_id: label.id,
          github_object_id: 802,
          github_node_id: "L_802",
          confirmed_snapshot: %{},
          state: :confirmed
        }
      )
    )

    Repo.insert!(
      ForgeAccounts.GitHubIdentity.observed_changeset(%ForgeAccounts.GitHubIdentity{}, %{
        github_user_id: 803,
        github_node_id: "U_803",
        login: "remote-known"
      })
    )

    pair =
      c.pair
      |> put_in([:issue, "labels"], [
        %{"id" => 802, "node_id" => "L_802", "name" => "remote-known"}
      ])
      |> put_in([:issue, "assignees"], [
        %{"id" => 803, "node_id" => "U_803", "login" => "remote-known"}
      ])

    before =
      {Repo.all(ForgeAccounts.GitHubIdentity), Repo.all(ForgeMirrors.MirrorResourceState),
       Repo.all(ForgeIssues.IssueLabel), Repo.all(ForgeIssues.IssueAssignee)}

    assert {:ok, result} = PullMergeObservation.build(c.sync, pair, c.m)
    assert result.issue.confirmed_snapshot["label_github_ids"] == [802]
    assert result.issue.confirmed_snapshot["assignee_github_ids"] == [803]

    assert before ==
             {Repo.all(ForgeAccounts.GitHubIdentity), Repo.all(ForgeMirrors.MirrorResourceState),
              Repo.all(ForgeIssues.IssueLabel), Repo.all(ForgeIssues.IssueAssignee)}
  end

  test "observes provider removals without deleting local memberships", c do
    pair = c.pair |> put_in([:issue, "labels"], []) |> put_in([:issue, "assignees"], [])
    before = {Repo.all(ForgeIssues.IssueLabel), Repo.all(ForgeIssues.IssueAssignee)}
    assert {:ok, result} = PullMergeObservation.build(c.sync, pair, c.m)
    assert result.issue.confirmed_snapshot["label_github_ids"] == []
    assert result.issue.confirmed_snapshot["assignee_github_ids"] == []
    assert before == {Repo.all(ForgeIssues.IssueLabel), Repo.all(ForgeIssues.IssueAssignee)}
  end

  test "node validation takes ordered nonblocking share locks in the caller transaction", c do
    owner = self()
    handler = "merge-observation-node-locks-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fornacast, :repo, :query],
      fn _, _, metadata, _ -> send(owner, {:node_query, metadata.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, {:ok, _}} =
             Repo.transaction(fn -> PullMergeObservation.build(c.sync, c.pair, c.m) end)

    queries = node_queries([])

    for table <- ["mirror_resource_states", "github_identities"] do
      assert Enum.any?(
               queries,
               &(String.contains?(&1, "FROM \"#{table}\"") and String.contains?(&1, "ORDER BY") and
                   String.contains?(&1, "FOR SHARE NOWAIT"))
             )
    end
  end

  test "a contended node identity returns a typed error and leaves the outer transaction usable",
       c do
    owner = self()
    github_id = System.unique_integer([:positive]) + 8_000_000_000

    task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          identity =
            Repo.insert!(
              ForgeAccounts.GitHubIdentity.observed_changeset(%ForgeAccounts.GitHubIdentity{}, %{
                github_user_id: github_id,
                github_node_id: "U_BUSY_#{github_id}",
                login: "busy-#{github_id}"
              })
            )

          try do
            Repo.transaction(fn ->
              Ecto.Adapters.SQL.query!(
                Repo,
                "SELECT id FROM github_identities WHERE id = $1 FOR UPDATE",
                [identity.id]
              )

              send(owner, {:identity_locked, github_id})

              receive do
                :release -> :ok
              after
                10_000 -> raise "identity lock was not released"
              end
            end)
          after
            Repo.delete!(identity)
          end
        end)
      end)

    try do
      assert_receive {:identity_locked, ^github_id}, 5_000

      pair =
        c.pair
        |> put_in([:issue, "labels"], [])
        |> put_in([:issue, "assignees"], [
          %{"id" => github_id, "node_id" => "U_BUSY_#{github_id}", "login" => "busy-#{github_id}"}
        ])

      assert {:ok, :usable} =
               Repo.transaction(fn ->
                 assert {:error, :relationship_lock_busy} =
                          PullMergeObservation.build(c.sync, pair, c.m)

                 assert %{rows: [[1]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [])
                 :usable
               end)
    after
      send(task.pid, :release)
      Task.await(task, 5_000)
    end
  end

  defp node_queries(acc) do
    receive do
      {:node_query, query} -> node_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "unknown or substituted relationship identities cause no database writes", %{
    sync: sync,
    pair: pair,
    m: m
  } do
    before = {Repo.all(ForgeAccounts.GitHubIdentity), Repo.all(ForgeMirrors.MirrorResourceState)}

    for {kind, raw} <- [
          {"labels", [%{"id" => 999, "node_id" => "L_999", "name" => "new"}]},
          {"labels", [%{"id" => 800, "node_id" => "L_wrong", "name" => "known"}]},
          {"assignees", [%{"id" => 801, "node_id" => "U_wrong", "login" => "known"}]},
          {"assignees", [%{"id" => 999, "node_id" => "U_999", "login" => "new"}]}
        ] do
      assert {:error, :merge_metadata_unconfirmed} =
               PullMergeObservation.build(sync, put_in(pair, [:issue, kind], raw), m)
    end

    assert before ==
             {Repo.all(ForgeAccounts.GitHubIdentity), Repo.all(ForgeMirrors.MirrorResourceState)}
  end

  test "returns normalized unique assignee profiles after validating the complete merge pair",
       c do
    pair =
      put_in(c.pair, [:issue, "assignees"], [
        %{
          "id" => 803,
          "node_id" => "U_803",
          "login" => "second",
          "name" => "Second",
          "avatar_url" => "https://avatars.githubusercontent.com/u/803?v=4",
          "html_url" => "https://github.com/second",
          "ignored" => "transport-only"
        },
        %{"id" => 802, "node_id" => "U_802", "login" => "first"}
      ])

    before = Repo.all(ForgeAccounts.GitHubIdentity)

    assert {:ok, profiles} = PullMergeObservation.assignee_profiles(c.sync, pair, c.m)

    assert profiles == [
             %{
               id: 802,
               node_id: "U_802",
               login: "first",
               name: nil,
               avatar_url: nil,
               html_url: nil
             },
             %{
               id: 803,
               node_id: "U_803",
               login: "second",
               name: "Second",
               avatar_url: "https://avatars.githubusercontent.com/u/803?v=4",
               html_url: "https://github.com/second"
             }
           ]

    assert Repo.all(ForgeAccounts.GitHubIdentity) == before
  end

  test "assignee profiles reject malformed, duplicate and substituted node identities", c do
    collision =
      Repo.insert!(
        ForgeAccounts.GitHubIdentity.observed_changeset(%ForgeAccounts.GitHubIdentity{}, %{
          github_user_id: 804,
          github_node_id: "U_804",
          login: "collision"
        })
      )

    for assignees <- [
          [%{"id" => 802, "node_id" => nil, "login" => "missing-node"}],
          [%{"id" => 802, "node_id" => "U_802", "login" => ""}],
          [%{"id" => 802, "node_id" => "U_802", "login" => "ghp_secret-token"}],
          [
            %{"id" => 802, "node_id" => "U_802", "login" => "one"},
            %{"id" => 802, "node_id" => "U_other", "login" => "two"}
          ],
          [
            %{"id" => 802, "node_id" => "U_same", "login" => "one"},
            %{"id" => 803, "node_id" => "U_same", "login" => "two"}
          ],
          [%{"id" => 801, "node_id" => "U_wrong", "login" => "known"}],
          [%{"id" => 805, "node_id" => collision.github_node_id, "login" => "substituted"}]
        ] do
      assert {:error, :merge_metadata_unconfirmed} =
               PullMergeObservation.assignee_profiles(
                 c.sync,
                 put_in(c.pair, [:issue, "assignees"], assignees),
                 c.m
               )
    end
  end

  test "assignee profiles authenticate the exact merged envelope before returning transport data",
       c do
    pair =
      put_in(c.pair, [:issue, "assignees"], [
        %{"id" => 802, "node_id" => "U_802", "login" => "unknown"}
      ])

    for {path, value} <- [
          {[:pull, "id"], 999},
          {[:pull, "base", "sha"], String.duplicate("e", 40)},
          {[:issue, "node_id"], "I_substituted"},
          {[:issue, "updated_at"], "invalid"},
          {[:issue, "labels", Access.at(0), "node_id"], "L_substituted"}
        ] do
      assert {:error, _} =
               PullMergeObservation.assignee_profiles(c.sync, put_in(pair, path, value), c.m)
    end

    assert {:error, :invalid_merge_observation} =
             PullMergeObservation.assignee_profiles(
               c.sync,
               pair,
               c.sync.intent.expected_base_oid
             )
  end

  test "label candidate returns the ready normalized observation without writes", c do
    pair = put_in(c.pair, [:issue, "labels"], [full_label(800, "L_800", "known")])
    before = catalog_state()

    assert {:ok, %{status: :ready, observation: observation}} =
             PullMergeObservation.label_candidate(c.sync, pair, c.m)

    assert observation.remote_base_oid == c.m
    assert observation.issue.confirmed_snapshot["label_github_ids"] == [800]
    assert catalog_state() == before
  end

  test "label candidate returns only the first sorted missing label after validating every label",
       c do
    pair =
      put_in(c.pair, [:issue, "labels"], [
        full_label(803, "L_803", "third", "AABBCC", "later"),
        full_label(800, "L_800", "known"),
        full_label(802, "L_802", "first", "ABCDEF", "")
      ])
      |> put_in([:issue, "assignees"], [
        %{"id" => 899, "node_id" => "U_899", "login" => "unknown-is-allowed"}
      ])

    before = catalog_state()

    assert {:ok,
            %{
              status: :missing,
              candidate: candidate,
              observation: observation
            }} = PullMergeObservation.label_candidate(c.sync, pair, c.m)

    assert candidate == %{
             github_object_id: 802,
             node_id: "L_802",
             name: "first",
             color: "abcdef",
             description: nil
           }

    assert observation.issue.confirmed_snapshot["label_github_ids"] == [800, 802, 803]
    assert observation.issue.confirmed_snapshot["assignee_github_ids"] == [899]
    assert catalog_state() == before
  end

  test "label candidate rejects malformed later labels and exact merge contradictions", c do
    valid = full_label(802, "L_802", "first")

    invalid_labels = [
      [valid, full_label(803, "L_803", "later", "bad", nil)],
      [valid, full_label(803, "L_802", "duplicate-node")],
      [valid, full_label(802, "L_other", "duplicate-id")],
      [
        valid,
        Map.put(full_label(803, "L_803", "later"), "description", String.duplicate("x", 101))
      ]
    ]

    for labels <- invalid_labels do
      assert {:error, :merge_metadata_unconfirmed} =
               PullMergeObservation.label_candidate(
                 c.sync,
                 put_in(c.pair, [:issue, "labels"], labels),
                 c.m
               )
    end

    pair = put_in(c.pair, [:issue, "labels"], [valid])

    assert {:error, :invalid_merge_observation} =
             PullMergeObservation.label_candidate(
               c.sync,
               put_in(pair, [:pull, "merge_commit_sha"], String.duplicate("f", 40)),
               c.m
             )
  end

  test "label candidate rejects dangling, wrong-type and wrong-repository known mappings", c do
    pair = put_in(c.pair, [:issue, "labels"], [full_label(800, "L_800", "known")])

    mapping =
      Repo.get_by!(ForgeMirrors.MirrorResourceState,
        repository_mirror_id: c.sync.repository_mirror_id,
        resource_kind: :label,
        github_object_id: 800
      )

    assert {:error, :done} =
             Repo.transaction(fn ->
               mapping
               |> Ecto.Changeset.change(
                 local_resource_id: System.unique_integer([:positive]) + 9_000_000_000
               )
               |> Repo.update!()

               assert_label_candidate_rejected(c, pair)
               Repo.rollback(:done)
             end)

    assert {:error, :done} =
             Repo.transaction(fn ->
               mapping
               |> Ecto.Changeset.change(local_resource_type: "ForgeIssues.Issue")
               |> Repo.update!()

               assert_label_candidate_rejected(c, pair)
               Repo.rollback(:done)
             end)

    organization =
      c.sync.repository_mirror_id
      |> then(&Repo.get!(ForgeMirrors.RepositoryMirror, &1))
      |> then(&Repo.get!(ForgeMirrors.OrganizationMirror, &1.organization_mirror_id))

    other = repository_mirror_fixture(organization)

    foreign_label =
      Repo.insert!(
        ForgeIssues.Label.changeset(%ForgeIssues.Label{repository_id: other.repository_id}, %{
          name: "foreign",
          normalized_name: "foreign",
          color: "112233"
        })
      )

    assert {:error, :done} =
             Repo.transaction(fn ->
               mapping
               |> Ecto.Changeset.change(local_resource_id: foreign_label.id)
               |> Repo.update!()

               assert_label_candidate_rejected(c, pair)
               Repo.rollback(:done)
             end)
  end

  test "label candidate rejects known node substitution and organization node collision", c do
    substituted =
      put_in(c.pair, [:issue, "labels"], [full_label(800, "L_wrong", "known")])

    assert {:error, :merge_metadata_unconfirmed} =
             PullMergeObservation.label_candidate(c.sync, substituted, c.m)

    repository_id = c.sync.repository_id

    label =
      Repo.insert!(
        ForgeIssues.Label.changeset(%ForgeIssues.Label{repository_id: repository_id}, %{
          name: "collision",
          normalized_name: "collision",
          color: "112233"
        })
      )

    Repo.insert!(
      ForgeMirrors.MirrorResourceState.persistence_changeset(
        %ForgeMirrors.MirrorResourceState{},
        %{
          repository_mirror_id: c.sync.repository_mirror_id,
          resource_kind: :label,
          local_resource_type: "ForgeIssues.Label",
          local_resource_id: label.id,
          github_object_id: 804,
          github_node_id: "L_collision",
          confirmed_snapshot: %{},
          state: :confirmed
        }
      )
    )

    collision =
      put_in(c.pair, [:issue, "labels"], [full_label(805, "L_collision", "unknown")])

    assert {:error, :merge_metadata_unconfirmed} =
             PullMergeObservation.label_candidate(c.sync, collision, c.m)
  end

  test "label candidate returns lock busy without writes when an assignee identity is contended",
       c do
    owner = self()
    github_id = System.unique_integer([:positive]) + 8_100_000_000

    task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          identity =
            Repo.insert!(
              ForgeAccounts.GitHubIdentity.observed_changeset(%ForgeAccounts.GitHubIdentity{}, %{
                github_user_id: github_id,
                github_node_id: "U_BUSY_#{github_id}",
                login: "busy-#{github_id}"
              })
            )

          try do
            Repo.transaction(fn ->
              Ecto.Adapters.SQL.query!(
                Repo,
                "SELECT id FROM github_identities WHERE id = $1 FOR UPDATE",
                [identity.id]
              )

              send(owner, {:candidate_identity_locked, github_id})

              receive do
                :release -> :ok
              after
                10_000 -> raise "identity lock was not released"
              end
            end)
          after
            Repo.delete!(identity)
          end
        end)
      end)

    try do
      assert_receive {:candidate_identity_locked, ^github_id}, 5_000

      pair =
        c.pair
        |> put_in([:issue, "labels"], [])
        |> put_in([:issue, "assignees"], [
          %{"id" => github_id, "node_id" => "U_BUSY_#{github_id}", "login" => "busy-#{github_id}"}
        ])

      before = catalog_state()

      assert {:error, :relationship_lock_busy} =
               PullMergeObservation.label_candidate(c.sync, pair, c.m)

      assert catalog_state() == before
    after
      send(task.pid, :release)
      Task.await(task, 5_000)
    end
  end

  defp full_label(id, node, name, color \\ "112233", description \\ nil),
    do: %{
      "id" => id,
      "node_id" => node,
      "name" => name,
      "color" => color,
      "description" => description
    }

  defp assert_label_candidate_rejected(c, pair) do
    before = catalog_state()

    assert {:error, :merge_metadata_unconfirmed} =
             PullMergeObservation.label_candidate(c.sync, pair, c.m)

    assert catalog_state() == before
  end

  defp catalog_state do
    {Repo.all(ForgeAccounts.GitHubIdentity), Repo.all(ForgeMirrors.MirrorResourceState),
     Repo.all(ForgeIssues.Label)}
  end
end
