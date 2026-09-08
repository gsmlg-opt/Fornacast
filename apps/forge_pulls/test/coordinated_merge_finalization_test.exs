defmodule ForgePulls.CoordinatedMergeFinalizationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.Issue
  alias ForgePulls.{MergeOperation, PullRequest}
  alias Fornacast.Repo

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    id = System.unique_integer([:positive])

    {:ok, actor} =
      ForgeAccounts.create_user(%{
        username: "final-#{id}",
        email: "final-#{id}@example.test",
        password: "correct horse battery staple"
      })

    {:ok, repository} =
      ForgeRepos.create_repository(actor, %{name: "final", slug: "final", visibility: :private})

    path = ForgeRepos.absolute_storage_path(repository)
    tree = git!(path, ["hash-object", "-t", "tree", "-w", "/dev/null"])
    base = git!(path, ["commit-tree", tree, "-m", "base"])
    head = git!(path, ["commit-tree", tree, "-p", base, "-m", "head"])
    git!(path, ["update-ref", "refs/heads/main", base])
    git!(path, ["update-ref", "refs/heads/feature", head])

    {:ok, pull} =
      ForgePulls.create_pull_request(
        repository,
        actor,
        %{title: "Merge", head: "feature", base: "main"},
        %{request_id: "create-#{id}"}
      )

    head_repository =
      if tags[:cross_repository] do
        {:ok, other} =
          ForgeRepos.create_repository(actor, %{
            name: "other",
            slug: "other",
            visibility: :private
          })

        git!(ForgeRepos.absolute_storage_path(other), [
          "fetch",
          "--quiet",
          path,
          "+refs/heads/feature:refs/heads/feature"
        ])

        other
      else
        repository
      end

    pull = pull |> Changeset.change(head_repository_id: head_repository.id) |> Repo.update!()
    {:ok, projection} = ForgePulls.sync_projection(repository.id, :pull, pull.id)

    signature = %{
      "name" => "Fixed",
      "email" => "fixed@example.test",
      "seconds" => 1_750_000_000,
      "offset_minutes" => 0
    }

    request = %{
      repository_id: repository.id,
      resource_kind: :pull,
      local_resource_id: pull.id,
      expected_local_version: projection.local_version,
      expected_fields: projection.fields,
      expected_merge_state: projection.merge_state,
      expected_head_repository_id: head_repository.id,
      coordinator_operation_id: id,
      actor_user_id: actor.id,
      request_id: "final-#{id}",
      commit_intent: %{
        "message" => "Exact merge",
        "author" => signature,
        "committer" => signature
      }
    }

    {:ok, %{intent: intent}} =
      Multi.new()
      |> ForgePulls.append_prepare_coordinated_merge(:intent, request)
      |> Repo.transaction()

    {:ok, intent} = ForgePulls.write_coordinated_merge(intent.id, id, authorize: fn _ -> :ok end)

    %{
      actor: actor,
      repository: repository,
      head_repository: head_repository,
      path: path,
      pull: pull,
      intent: intent,
      base: base,
      head: head,
      merged_at: ~U[2026-09-08 01:02:03Z]
    }
  end

  test "advances the exact merge and completes once, confirming the actual projection", c do
    before = counts(c)
    original_version = Repo.get!(Issue, c.pull.issue_id).sync_version
    cache_key = {c.path, :finalization_cache_probe}
    assert {:ok, :before} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :before} end)
    assert {:ok, %{resource: result}} = finish(c)
    assert result.merge_state == %{merged_at: c.merged_at, merge_commit_sha: c.intent.merge_oid}
    assert result.fields["base_sha"] == c.intent.merge_oid
    assert result.fields["state"] == "closed"
    assert Repo.get!(MergeOperation, c.intent.id).state == :completed
    assert {:ok, oid} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert oid == c.intent.merge_oid
    assert {:ok, :after} = GitCore.Cache.fetch(cache_key, fn -> {:ok, :after} end)
    version = Repo.get!(Issue, c.pull.issue_id).sync_version
    assert version == original_version + 1
    assert counts(c) == {elem(before, 0) + 1, elem(before, 1) + 1}
    completed_counts = counts(c)
    write_version = Repo.get!(ForgeRepos.Repository, c.repository.id).write_version
    assert {:ok, %{resource: ^result}} = finish(c)
    assert Repo.get!(Issue, c.pull.issue_id).sync_version == version
    assert Repo.get!(ForgeRepos.Repository, c.repository.id).write_version == write_version
    assert counts(c) == completed_counts
  end

  test "confirmation failure rolls back SQL and retries the already advanced ref", c do
    before = counts(c)
    version = Repo.get!(Issue, c.pull.issue_id).sync_version

    assert {:error, :confirmation_failed} =
             finish(c, confirm: fn _, _ -> {:error, :confirmation_failed} end)

    assert Repo.get!(MergeOperation, c.intent.id).state == :merge_written
    assert Repo.get!(PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(Issue, c.pull.issue_id).state == :open
    assert Repo.get!(Issue, c.pull.issue_id).sync_version == version
    assert counts(c) == before
    assert {:ok, oid} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert oid == c.intent.merge_oid

    assert {:ok, refreshed} =
             ForgePulls.SnapshotRefresh.persist(
               c.pull,
               Map.put(
                 Map.take(c.pull, [:base_ref, :head_ref, :base_sha, :head_sha]),
                 :base_sha,
                 oid
               )
             )

    refreshed |> Changeset.change(draft: true) |> Repo.update!()
    issue = Repo.get!(Issue, c.pull.issue_id)

    issue
    |> Issue.update_changeset(%{title: "Edited after effect", body: "Keep body"})
    |> Repo.update!()

    label =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: c.repository.id,
        name: "Retain",
        normalized_name: "retain",
        color: "abcdef"
      })

    membership =
      Repo.insert!(%ForgeIssues.IssueLabel{issue_id: c.pull.issue_id, label_id: label.id})

    assignee =
      Repo.insert!(%ForgeIssues.IssueAssignee{issue_id: c.pull.issue_id, user_id: c.actor.id})

    assert {:ok, %{resource: result}} = finish(c)
    assert result.fields["title"] == "Edited after effect"
    assert result.fields["body"] == "Keep body"
    assert result.fields["draft"] == true
    assert result.label_ids == [label.id]
    assert Repo.get!(ForgeIssues.IssueLabel, membership.id) == membership
    assert Repo.get!(ForgeIssues.IssueAssignee, assignee.id) == assignee
  end

  test "requires both trusted callbacks and committed intent", c do
    assert {:error, :invalid_coordinator_capability} =
             ForgePulls.finalize_coordinated_merge(
               c.intent.id,
               c.intent.coordinator_operation_id,
               c.merged_at,
               []
             )

    assert {:error, :invalid_coordinator_capability} =
             ForgePulls.finalize_coordinated_merge(
               c.intent.id,
               c.intent.coordinator_operation_id,
               c.merged_at,
               authorize: fn _ -> :ok end
             )

    assert {:error, :revoked} = finish(c, authorize: fn _ -> {:error, :revoked} end)
    assert {:ok, {:error, :uncommitted_merge_intent}} = Repo.transaction(fn -> finish(c) end)
  end

  test "rejects malformed time and mismatched identities", c do
    assert {:error, :invalid_merged_at} = finish(%{c | merged_at: "2026-09-08"})

    assert {:error, :invalid_merged_at} =
             finish(%{c | merged_at: %{c.merged_at | microsecond: {1, 6}}})

    assert {:error, :invalid_merged_at} = finish(%{c | merged_at: %{c.merged_at | month: 13}})

    assert {:error, :stale_merge_identity} =
             finish(%{c | intent: %{c.intent | coordinator_operation_id: 0}})

    assert {:error, :stale_merge_identity} =
             finish(%{
               c
               | intent: %{
                   c.intent
                   | coordinator_operation_id: c.intent.coordinator_operation_id + 1
                 }
             })

    c.repository |> Changeset.change(generation: c.repository.generation + 1) |> Repo.update!()
    assert {:error, _} = finish(c)
  end

  test "rejects ref drift and conflicting private result pin", c do
    git!(c.path, ["update-ref", "refs/heads/feature", c.base])
    assert {:error, _} = finish(c)
    git!(c.path, ["update-ref", "refs/heads/feature", c.head])
    git!(c.path, ["update-ref", "refs/heads/main", c.head])
    assert {:error, _} = finish(c)
    git!(c.path, ["update-ref", "refs/heads/main", c.base])
    {:ok, pin} = GitCore.tracking_ref_name("merge-#{c.intent.id}", "refs/heads/result")
    git!(c.path, ["update-ref", pin, c.base])
    assert {:error, _} = finish(c)
  end

  test "completed replay rejects contradictory merge facts and time", c do
    assert {:ok, _} = finish(c)
    assert {:error, _} = finish(%{c | merged_at: DateTime.add(c.merged_at, 1)})

    Repo.get!(PullRequest, c.pull.id)
    |> Changeset.change(merge_commit_sha: c.base)
    |> Repo.update!()

    assert {:error, _} = finish(c)
  end

  test "callback failures revoke authority before CAS and roll back SQL after CAS", c do
    for stage <- [2, 3] do
      Process.put(:final_authorize_calls, 0)

      assert {:error, :revoked} =
               finish(c,
                 authorize: fn _ ->
                   count = Process.get(:final_authorize_calls) + 1
                   Process.put(:final_authorize_calls, count)
                   if count == stage, do: {:error, :revoked}, else: :ok
                 end
               )

      assert {:ok, actual} = GitCore.exact_ref(c.path, "refs/heads/main")
      assert actual == if(stage == 2, do: c.base, else: c.intent.merge_oid)
      assert Repo.get!(PullRequest, c.pull.id).merged_at == nil
      assert Repo.get!(MergeOperation, c.intent.id).state == :merge_written
    end

    assert {:ok, _} = finish(c)
  end

  test "invalid confirmation return and exceptions cannot commit domain completion", c do
    assert {:error, _} = finish(c, confirm: fn _, _ -> :ok end)

    assert_raise RuntimeError, "confirm crash", fn ->
      finish(c, confirm: fn _, _ -> raise "confirm crash" end)
    end

    assert Repo.get!(PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(MergeOperation, c.intent.id).state == :merge_written
    assert {:ok, _} = finish(c)
  end

  test "caller SQL confirmation commits once and rolls back with a rejected confirmation", c do
    event_id = Ecto.UUID.generate()
    before = counts(c)

    assert {:error, :confirmation_rejected} =
             finish(c,
               confirm: fn actual, intent ->
                 assert {:ok, _} = record_confirmation(event_id, actual, intent)
                 {:error, :confirmation_rejected}
               end
             )

    refute Repo.get_by(Fornacast.DomainOutboxEvent, event_id: event_id)
    assert counts(c) == before
    assert Repo.get!(PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(MergeOperation, c.intent.id).state == :merge_written
    assert {:ok, merge_oid} = GitCore.exact_ref(c.path, c.intent.base_ref)
    assert merge_oid == c.intent.merge_oid

    confirm = fn actual, intent -> record_confirmation(event_id, actual, intent) end
    assert {:ok, %{confirmation: event}} = finish(c, confirm: confirm)
    assert event.event_id == event_id
    assert {:ok, %{confirmation: ^event}} = finish(c, confirm: confirm)

    assert Repo.aggregate(
             from(e in Fornacast.DomainOutboxEvent, where: e.event_id == ^event_id),
             :count
           ) == 1

    assert Repo.get!(MergeOperation, c.intent.id).state == :completed
  end

  test "failure completing intent rolls back caller confirmation SQL after callback succeeds",
       c do
    event_id = Ecto.UUID.generate()
    before = counts(c)
    version = Repo.get!(Issue, c.pull.issue_id).sync_version

    assert_raise Ecto.StaleEntryError, fn ->
      finish(c,
        confirm: fn actual, intent ->
          assert {:ok, event} = record_confirmation(event_id, actual, intent)
          intent |> Changeset.change(lock_version: intent.lock_version + 1) |> Repo.update!()
          {:ok, event}
        end
      )
    end

    refute Repo.get_by(Fornacast.DomainOutboxEvent, event_id: event_id)
    assert counts(c) == before
    assert Repo.get!(Issue, c.pull.issue_id).sync_version == version
    assert Repo.get!(PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(MergeOperation, c.intent.id) == c.intent
    assert {:ok, merge_oid} = GitCore.exact_ref(c.path, c.intent.base_ref)
    assert merge_oid == c.intent.merge_oid

    assert {:ok, _} =
             finish(c,
               confirm: fn actual, intent -> record_confirmation(event_id, actual, intent) end
             )
  end

  # This caller-owned event proves SQL composition, not GitHub confirmation.
  defp record_confirmation(event_id, actual, intent) do
    assert Repo.in_transaction?()
    assert Repo.get!(MergeOperation, intent.id).state == intent.state
    assert actual.merge_state.merge_commit_sha == intent.merge_oid

    case Repo.get_by(Fornacast.DomainOutboxEvent, event_id: event_id) do
      nil ->
        {:ok, %{confirmation: event}} =
          Multi.new()
          |> Fornacast.DomainOutbox.record_multi(:confirmation, %{
            event_id: event_id,
            aggregate_type: "test_confirmation",
            aggregate_id: to_string(intent.id),
            event_type: "test.confirmed",
            origin: :github,
            payload: %{"merge_oid" => actual.merge_state.merge_commit_sha}
          })
          |> Repo.transaction()

        {:ok, event}

      event ->
        {:ok, event}
    end
  end

  @tag cross_repository: true
  test "locks and verifies a represented head in another repository", c do
    head_path = ForgeRepos.absolute_storage_path(c.head_repository)
    git!(head_path, ["update-ref", "refs/heads/feature", c.base])
    assert {:error, _} = finish(c)
    git!(head_path, ["update-ref", "refs/heads/feature", c.head])
    assert {:ok, _} = finish(c)
  end

  @tag cross_repository: true
  test "rejects replacement of a represented head repository", c do
    c.head_repository
    |> Changeset.change(generation: c.head_repository.generation + 1)
    |> Repo.update!()

    assert {:error, :stale_merge_identity} = finish(c)
    assert {:ok, base} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert base == c.base
  end

  test "rejects immutable intent tampering before domain locks", c do
    assert {:error, :stale_merge_identity} =
             finish(c,
               authorize: fn observed ->
                 observed |> Changeset.change(request_id: "replaced") |> Repo.update!()
                 :ok
               end
             )

    assert Repo.get!(MergeOperation, c.intent.id).request_id == c.intent.request_id

    assert {:error, :stale_merge_identity} =
             finish(%{c | intent: %{c.intent | id: 9_223_372_036_854_775_807}})
  end

  test "requires private tree pin and exact merge parents", c do
    {:ok, tree_pin} = GitCore.tracking_ref_name("merge-#{c.intent.id}", "refs/tags/tree")
    git!(c.path, ["update-ref", "-d", tree_pin])
    assert {:error, :merge_intent_conflict} = finish(c)
    git!(c.path, ["update-ref", tree_pin, c.intent.merge_tree_oid])

    wrong =
      git!(c.path, ["commit-tree", c.intent.merge_tree_oid, "-p", c.base, "-m", "wrong parents"])

    {:ok, result_pin} = GitCore.tracking_ref_name("merge-#{c.intent.id}", "refs/heads/result")
    git!(c.path, ["update-ref", result_pin, wrong])
    c.intent |> Changeset.change(merge_oid: wrong) |> Repo.update!()
    assert {:error, :merge_intent_conflict} = finish(c)
  end

  test "applies exact inbound metadata and relationships before closure once", c do
    request = metadata_request(c)

    label =
      Repo.insert!(%ForgeIssues.Label{
        repository_id: c.repository.id,
        name: "Inbound",
        normalized_name: "inbound",
        color: "abcdef"
      })

    request =
      Map.merge(request, %{
        local_label_ids: [label.id],
        assignee_refs: [%{kind: :local_user, id: c.actor.id}]
      })

    before = counts(c)
    assert {:ok, %{resource: result}} = finish(c, metadata_request: request)
    assert result.fields["title"] == "Inbound title"
    assert result.fields["body"] == "Inbound body"
    assert result.fields["state"] == "closed"
    assert result.fields["base_sha"] == c.intent.merge_oid
    assert result.local_version == request.expected_local_version + 2
    assert result.label_ids == [label.id]
    assert %{kind: :local_user, id: c.actor.id} in result.assignee_refs
    assert counts(c) == {elem(before, 0) + 2, elem(before, 1) + 1}
    after_counts = counts(c)
    assert {:ok, %{resource: ^result}} = finish(c, metadata_request: request)
    assert counts(c) == after_counts
  end

  test "rejects stale metadata preimages and forbidden or partial requests", c do
    request = metadata_request(c)

    invalid = [
      %{request | expected_local_version: request.expected_local_version + 1},
      %{request | expected_fields: Map.put(request.expected_fields, "title", "stale")},
      %{request | expected_relationships: %{label_ids: [999], managed_assignee_identity_ids: []}},
      Map.delete(request, :assignee_refs),
      Map.delete(request, :expected_relationships),
      Map.put(request, :minimum_local_version, 1),
      %{request | repository_id: c.repository.id + 1},
      %{request | local_resource_id: c.pull.id + 1},
      %{request | fields: Map.put(request.fields, "state", "closed")},
      %{request | fields: Map.put(request.fields, "state_reason", "reopened")},
      %{request | fields: Map.put(request.fields, "base_sha", c.intent.merge_oid)},
      %{request | fields: Map.put(request.fields, "head_ref", "refs/heads/other")},
      %{request | fields: Map.put(request.fields, "draft", true)}
    ]

    before = counts(c)

    for bad <- invalid do
      assert {:error, _} = finish(c, metadata_request: bad)
      assert Repo.get!(Issue, c.pull.issue_id).title == "Merge"
      assert Repo.get!(Issue, c.pull.issue_id).sync_version == request.expected_local_version
      assert counts(c) == before
    end
  end

  test "confirmation failure rolls back inbound metadata and both events with ref M recoverable",
       c do
    request = metadata_request(c)
    before = counts(c)

    assert {:error, :no_confirmation} =
             finish(c,
               metadata_request: request,
               confirm: fn _, _ -> {:error, :no_confirmation} end
             )

    assert Repo.get!(Issue, c.pull.issue_id).title == "Merge"
    assert Repo.get!(Issue, c.pull.issue_id).sync_version == request.expected_local_version
    assert Repo.get!(MergeOperation, c.intent.id).state == :merge_written
    assert counts(c) == before
    assert {:ok, oid} = GitCore.exact_ref(c.path, "refs/heads/main")
    assert oid == c.intent.merge_oid
    assert {:ok, %{resource: result}} = finish(c, metadata_request: request)
    assert result.local_version == request.expected_local_version + 2
  end

  test "inbound metadata cannot erase an exactly observed newer draft", c do
    c.pull |> Changeset.change(draft: true) |> Repo.update!()
    request = metadata_request(c)
    assert request.expected_fields["draft"] == true
    request = %{request | fields: Map.put(request.fields, "draft", false)}
    before = counts(c)
    assert {:error, :invalid_metadata_request} = finish(c, metadata_request: request)
    assert Repo.get!(PullRequest, c.pull.id).draft
    assert Repo.get!(PullRequest, c.pull.id).merged_at == nil
    assert Repo.get!(Issue, c.pull.issue_id).title == "Merge"
    assert counts(c) == before
  end

  defp metadata_request(c) do
    {:ok, local} = ForgePulls.sync_projection(c.repository.id, :pull, c.pull.id)

    %{
      repository_id: c.repository.id,
      resource_kind: :pull,
      local_resource_id: c.pull.id,
      action: :update,
      expected_local_version: local.local_version,
      expected_fields: local.fields,
      expected_merge_state: local.merge_state,
      expected_relationships: local.relationship_preimage,
      local_label_ids: local.label_ids,
      assignee_refs: local.assignee_refs,
      fields: Map.merge(local.fields, %{"title" => "Inbound title", "body" => "Inbound body"}),
      provenance: %{origin: :github}
    }
  end

  defp counts(c) do
    {Repo.aggregate(
       from(e in Fornacast.DomainOutboxEvent,
         where: e.aggregate_id == ^to_string(c.pull.issue_id)
       ),
       :count
     ),
     Repo.aggregate(
       from(a in Fornacast.AuditEvent,
         where: a.target_id == ^to_string(c.repository.id) and a.action == "pull_request.merged"
       ),
       :count
     )}
  end

  defp finish(c, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          authorize: fn _ -> :ok end,
          confirm: fn actual, intent ->
            assert Repo.in_transaction?()
            assert actual.merge_state.merge_commit_sha == intent.merge_oid
            {:ok, :confirmed}
          end
        ],
        overrides
      )

    ForgePulls.finalize_coordinated_merge(
      c.intent.id,
      c.intent.coordinator_operation_id,
      c.merged_at,
      opts
    )
  end

  defp git!(path, args) do
    {output, 0} =
      System.cmd("git", ["--git-dir=#{path}" | args],
        env: [
          {"GIT_AUTHOR_NAME", "Fixture"},
          {"GIT_AUTHOR_EMAIL", "fixture@example.test"},
          {"GIT_COMMITTER_NAME", "Fixture"},
          {"GIT_COMMITTER_EMAIL", "fixture@example.test"}
        ]
      )

    String.trim(output)
  end
end
