defmodule ForgeMirrors.PullCreationBoundaryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Ecto.Multi
  alias ForgeMirrors.{MirrorOperation, MirrorRefState, MirrorResourceState, PullEligibility}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    organization =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(organization)
    head = repository_mirror_fixture(organization)
    now = DateTime.utc_now(:second)

    author =
      %ForgeAccounts.GitHubIdentity{}
      |> ForgeAccounts.GitHubIdentity.observed_changeset(%{
        github_user_id: System.unique_integer([:positive]),
        login: "pull-create-author"
      })
      |> Repo.insert!()

    fields = %{
      "title" => "Remote",
      "body" => nil,
      "state" => "open",
      "state_reason" => nil,
      "draft" => true,
      "base_ref" => "refs/heads/main",
      "head_ref" => "refs/heads/feature",
      "base_sha" => String.duplicate("a", 40),
      "head_sha" => String.duplicate("b", 40)
    }

    for {binding, ref, oid} <- [
          {base, fields["base_ref"], fields["base_sha"]},
          {head, fields["head_ref"], fields["head_sha"]}
        ] do
      baseline(binding, ref, oid, now)
    end

    identity = %{
      "github_issue_object_id" => 700,
      "github_issue_node_id" => "I_700",
      "github_number" => 7,
      "base_repository" => %{"id" => base.github_repository_id, "node_id" => base.github_node_id},
      "head_repository" => %{"id" => head.github_repository_id, "node_id" => head.github_node_id}
    }

    observation = %{
      pull: %{
        github_object_id: 1700,
        github_node_id: "PR_1700",
        github_number: 7,
        remote_updated_at: now,
        confirmed_snapshot: fields,
        confirmed_merge_state: %{"merged_at" => nil, "merge_commit_sha" => nil},
        provider_identity: identity
      },
      issue: %{
        github_object_id: 700,
        github_node_id: "I_700",
        github_number: 7,
        remote_updated_at: now,
        confirmed_snapshot:
          Map.merge(Map.take(fields, ~w(title body state state_reason)), %{
            "label_github_ids" => [],
            "assignee_github_ids" => []
          })
      }
    }

    operation =
      operation_fixture(organization, %{
        repository_mirror_id: base.id,
        kind: "sync.pull",
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "pull",
          "github_object_id" => 1700,
          "github_number" => 7
        },
        next_attempt_at: now
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("pull-create-boundary", now, 120, 100, ["sync.pull"])

    operation = Enum.find(claimed, &(&1.id == operation.id))

    refs = %{
      base_ref: fields["base_ref"],
      head_ref: fields["head_ref"],
      base_sha: fields["base_sha"],
      head_sha: fields["head_sha"]
    }

    {:ok, proof} = PullEligibility.check(base.id, head.repository_id, refs)

    request = %{
      repository_id: base.repository_id,
      resource_kind: :pull,
      head_repository_id: head.repository_id,
      author_github_identity_id: author.id,
      fields: fields,
      merge_state: %{merged_at: nil, merge_commit_sha: nil},
      inserted_at: now,
      updated_at: now,
      local_label_ids: [],
      assignee_refs: [],
      provenance: %{origin: :github}
    }

    %{
      organization: organization,
      base: base,
      head: head,
      now: now,
      operation: operation,
      observation: observation,
      request: request,
      expected: %{head_repository_id: head.repository_id, pull_eligibility_proof: json(proof)}
    }
  end

  test "commits canonical issue and pull mappings with provider number independent of local number",
       c do
    assert {:ok, result} = confirm(c)
    assert result.operation.state == :completed
    assert result.resource.issue_number == 1
    assert result.issue_state.github_number == 7
    assert result.pull_state.github_number == 7
    assert result.issue_state.github_object_id == 700
    assert result.pull_state.github_object_id == 1700
    assert result.issue_state.local_resource_id == result.resource.issue_id
    assert result.pull_state.local_resource_id == result.resource.local_resource_id
    assert result.pull_state.provider_identity == c.observation.pull.provider_identity
    assert result.pull_state.confirmed_local_version == 1
    assert {:error, :lost_lease} = confirm(c)

    assert Repo.aggregate(
             from(i in "issues", where: i.repository_id == ^c.base.repository_id),
             :count
           ) == 1
  end

  test "equal numeric provider IDs are valid separate namespaces", c do
    observation = put_in(c.observation, [:issue, :github_object_id], 1700)
    observation = put_in(observation.pull.provider_identity["github_issue_object_id"], 1700)
    assert {:ok, result} = confirm(%{c | observation: observation})
    assert result.issue_state.github_object_id == result.pull_state.github_object_id
  end

  test "same-repository creation uses both exact ref baselines", c do
    fields = c.request.fields
    baseline(c.base, fields["head_ref"], fields["head_sha"], c.now)

    {:ok, proof} =
      PullEligibility.check(c.base.id, c.base.repository_id, %{
        base_ref: fields["base_ref"],
        head_ref: fields["head_ref"],
        base_sha: fields["base_sha"],
        head_sha: fields["head_sha"]
      })

    observation =
      put_in(c.observation, [:pull, :provider_identity, "head_repository"], %{
        "id" => c.base.github_repository_id,
        "node_id" => c.base.github_node_id
      })

    assert {:ok, result} =
             confirm(%{
               c
               | observation: observation,
                 expected: %{
                   head_repository_id: c.base.repository_id,
                   pull_eligibility_proof: json(proof)
                 },
                 request: %{c.request | head_repository_id: c.base.repository_id}
             })

    assert result.resource.head_repository_id == c.base.repository_id
    assert result.pull_state.state == :confirmed
  end

  test "elapsed database-clock lease expiry rolls back even when caller time is unchanged", c do
    expires = DateTime.add(DateTime.utc_now(:second), 2)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [lease_expires_at: expires]
    )

    c = %{c | operation: %{c.operation | lease_expires_at: expires}}

    callback = fn multi ->
      multi
      |> ForgePulls.append_sync_create(:resource, c.request)
      |> Multi.run(:elapsed, fn repo, _ ->
        Ecto.Adapters.SQL.query!(repo, "SELECT pg_sleep(2.1)", [])
        {:ok, :elapsed}
      end)
    end

    assert {:error, :lost_lease} = confirm(c, callback)
    refute Repo.get(ForgeIssues.NumberSequence, c.base.repository_id)
    refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.base.repository_id)
    assert Repo.get!(MirrorOperation, c.operation.id).state == :processing
  end

  test "post-callback binding changes cannot publish mappings based on old proof", c do
    callback = fn multi ->
      multi
      |> ForgePulls.append_sync_create(:resource, c.request)
      |> Multi.run(:rebind, fn repo, _ ->
        repo.update_all(from(b in ForgeMirrors.RepositoryMirror, where: b.id == ^c.head.id),
          set: [github_node_id: "R_substituted"]
        )

        {:ok, :changed}
      end)
    end

    assert {:error, :ineligible_pull} = confirm(c, callback)
    refute Repo.get(ForgeIssues.NumberSequence, c.base.repository_id)

    assert Repo.get!(ForgeMirrors.RepositoryMirror, c.head.id).github_node_id ==
             c.head.github_node_id

    assert {:ok, _} = confirm(c)
  end

  test "rejects contradictory paired identities and cursor substitution without creating domain rows",
       c do
    for observation <- [
          put_in(c.observation, [:issue, :github_number], 8),
          put_in(c.observation, [:issue, :github_node_id], "wrong"),
          put_in(c.observation, [:pull, :github_object_id], 1701),
          put_in(c.observation, [:issue, :confirmed_snapshot, "title"], "different")
        ] do
      assert {:error, _} = confirm(%{c | observation: observation})
      refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.base.repository_id)
    end
  end

  test "partial existing identity blocks creation rather than adopting by remote number", c do
    Repo.insert!(%MirrorResourceState{
      repository_mirror_id: c.base.id,
      resource_kind: :issue,
      github_object_id: 700,
      github_node_id: "I_700",
      github_number: 7,
      state: :pending
    })

    assert {:error, :identity_conflict} = confirm(c)
    refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.base.repository_id)
  end

  test "domain callback cannot manufacture a projection or reuse an existing aggregate", c do
    assert {:error, :invalid_projection} =
             confirm(c, fn multi ->
               Multi.put(multi, :resource, %{
                 repository_id: c.base.repository_id,
                 resource_kind: :pull,
                 local_resource_id: 999,
                 issue_id: 998,
                 issue_number: 1,
                 local_version: 1,
                 fields: c.request.fields
               })
             end)

    assert {:ok, %{resource: existing}} =
             Multi.new()
             |> ForgePulls.append_sync_create(:resource, c.request)
             |> Repo.transaction()

    assert {:error, :invalid_projection} =
             confirm(c, fn multi -> Multi.put(multi, :resource, existing) end)
  end

  test "post-callback mapping collision rolls back domain, number and outbox", c do
    callback = fn multi ->
      multi
      |> ForgePulls.append_sync_create(:resource, c.request)
      |> Multi.run(:collision, fn repo, _ ->
        repo.insert(%MirrorResourceState{
          repository_mirror_id: c.base.id,
          resource_kind: :pull,
          github_object_id: 1700,
          github_number: 7,
          state: :pending
        })
      end)
    end

    assert {:error, :identity_conflict} = confirm(c, callback)
    refute Repo.get(ForgeIssues.NumberSequence, c.base.repository_id)
    refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.base.repository_id)

    refute Repo.exists?(
             from m in MirrorResourceState, where: m.repository_mirror_id == ^c.base.id
           )

    assert {:ok, %{resource: %{issue_number: 1}}} = confirm(c)
  end

  test "callback cannot commit a second valid but unmapped aggregate", c do
    callback = fn multi ->
      multi
      |> ForgePulls.append_sync_create(:resource, c.request)
      |> ForgePulls.append_sync_create(:orphan, c.request)
    end

    assert {:error, :invalid_projection} = confirm(c, callback)
    refute Repo.get(ForgeIssues.NumberSequence, c.base.repository_id)
    refute Repo.exists?(from i in "issues", where: i.repository_id == ^c.base.repository_id)

    refute Repo.exists?(
             from p in "pull_requests", where: p.repository_id == ^c.base.repository_id
           )

    refute Repo.exists?(
             from m in MirrorResourceState, where: m.repository_mirror_id == ^c.base.id
           )

    assert {:ok, %{resource: %{issue_number: 1}}} = confirm(c)
  end

  test "live lease is rechecked after callback and effects cannot be completed by creation", c do
    callback = fn multi ->
      multi
      |> ForgePulls.append_sync_create(:resource, c.request)
      |> Multi.run(:expire, fn repo, _ ->
        repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
          set: [lease_expires_at: DateTime.add(c.now, -1)]
        )

        {:ok, :expired}
      end)
    end

    assert {:error, :lost_lease} = confirm(c, callback)
    refute Repo.get(ForgeIssues.NumberSequence, c.base.repository_id)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [
        state: :effect_pending,
        external_effect_marker: %{"action" => "create_remote_pull"},
        effect_marked_at: c.now
      ]
    )

    assert {:error, _} = confirm(c)
    assert Repo.get!(MirrorOperation, c.operation.id).external_effect_marker != nil
  end

  test "represented head must retain exact active identity and ref proof", c do
    Repo.update_all(from(h in ForgeMirrors.RepositoryMirror, where: h.id == ^c.head.id),
      set: [state: :discovered]
    )

    assert {:error, :ineligible_pull} = confirm(c)
    refute Repo.get(ForgeIssues.NumberSequence, c.base.repository_id)
  end

  test "only genuinely unrepresented immutable head permits nil read-only mapping", c do
    nil_expected = %{head_repository_id: nil, pull_eligibility_proof: nil}
    nil_request = %{c.request | head_repository_id: nil}

    assert {:error, :ineligible_pull} =
             confirm(%{c | expected: nil_expected, request: nil_request})

    observation =
      put_in(c.observation, [:pull, :provider_identity, "head_repository"], %{
        "id" => 999_999_999,
        "node_id" => "R_external"
      })

    assert {:ok, result} =
             confirm(%{
               c
               | expected: nil_expected,
                 request: nil_request,
                 observation: observation
             })

    assert result.pull_state.state == :unsupported
    assert result.issue_state.state == :confirmed
    assert result.resource.head_repository_id == nil
  end

  defp confirm(c, callback \\ nil),
    do:
      ForgeMirrors.confirm_remote_pull_creation(
        c.operation,
        c.now,
        c.expected,
        c.observation,
        callback || fn multi -> ForgePulls.append_sync_create(multi, :resource, c.request) end
      )

  defp baseline(binding, ref, oid, now),
    do:
      Repo.insert!(%MirrorRefState{
        repository_mirror_id: binding.id,
        ref_name: ref,
        ref_kind: :branch,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        state: :confirmed,
        last_confirmed_at: now
      })

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
