defmodule ForgeMirrors.PullHeadResolutionTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorOperation, MirrorRefState, RepositoryMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    org =
      active_organization_mirror_fixture(%{
        capabilities: %{"git" => "enabled", "pulls" => "enabled"}
      })

    base = repository_mirror_fixture(org)
    head = repository_mirror_fixture(org)
    now = DateTime.utc_now(:second)

    fields = %{
      "title" => "Remote",
      "body" => nil,
      "state" => "open",
      "state_reason" => nil,
      "draft" => false,
      "base_ref" => "refs/heads/main",
      "head_ref" => "refs/heads/feature",
      "base_sha" => String.duplicate("a", 40),
      "head_sha" => String.duplicate("b", 40)
    }

    for {binding, ref, oid} <- [
          {base, fields["base_ref"], fields["base_sha"]},
          {head, fields["head_ref"], fields["head_sha"]}
        ] do
      Repo.insert!(%MirrorRefState{
        repository_mirror_id: binding.id,
        ref_name: ref,
        ref_kind: :branch,
        state: :confirmed,
        confirmed_oid: oid,
        last_local_oid: oid,
        last_remote_oid: oid,
        last_confirmed_at: now
      })
    end

    identity = %{
      github_object_id: 1700,
      github_node_id: "PR_1700",
      github_number: 7,
      provider_identity: %{
        "github_issue_object_id" => 700,
        "github_issue_node_id" => "I_700",
        "github_number" => 7,
        "base_repository" => %{
          "id" => base.github_repository_id,
          "node_id" => base.github_node_id
        },
        "head_repository" => %{
          "id" => head.github_repository_id,
          "node_id" => head.github_node_id
        }
      }
    }

    op =
      operation_fixture(org, %{
        repository_mirror_id: base.id,
        kind: "sync.pull",
        next_attempt_at: now,
        cursor: %{
          "trigger" => "remote",
          "resource_kind" => "pull",
          "github_object_id" => 1700,
          "github_number" => 7
        }
      })

    {:ok, claimed} =
      ForgeMirrors.claim_operations("head-resolution", now, 120, 100, ["sync.pull"])

    %{
      org: org,
      base: base,
      head: head,
      fields: fields,
      identity: identity,
      operation: Enum.find(claimed, &(&1.id == op.id))
    }
  end

  test "resolves exact represented identity with durable and live-read proof", c do
    assert {:ok, result} = resolve(c)
    assert result.status == :represented
    assert result.head_repository_id == c.head.repository_id
    assert result.git_proof.head.repository_id == c.head.repository_id
    assert result.pull_eligibility_proof == JSON.decode!(JSON.encode!(result.git_proof))
  end

  test "equal numeric IDs in separate pull and issue namespaces are valid", c do
    c =
      put_in(c.identity.provider_identity["github_issue_object_id"], c.identity.github_object_id)

    assert {:ok, %{status: :represented}} = resolve(c)
  end

  test "genuine scoped absence is readonly and still proves the base", c do
    c =
      put_in(c.identity.provider_identity["head_repository"], %{
        "id" => 990_001,
        "node_id" => "R_external"
      })

    assert {:ok,
            %{
              status: :unrepresented,
              head_repository_id: nil,
              pull_eligibility_proof: nil,
              git_proof: proof
            }} = resolve(c)

    assert proof.head == nil
    assert proof.base.repository_id == c.base.repository_id
  end

  test "wrong node for known ID is conflict, never absence", c do
    assert {:error, :identity_conflict} =
             resolve(put_in(c.identity.provider_identity["head_repository"]["node_id"], "WRONG"))
  end

  test "known inactive binding remains retryable", c do
    Repo.update_all(from(b in RepositoryMirror, where: b.id == ^c.head.id),
      set: [state: :discovered]
    )

    assert {:error, :head_not_ready} = resolve(c)
  end

  test "known head with stale ref remains retryable", c do
    assert {:error, :head_not_ready} =
             resolve(put_in(c.fields["head_sha"], String.duplicate("c", 40)))
  end

  test "unrepresented head cannot hide unready base", c do
    c =
      put_in(c.identity.provider_identity["head_repository"], %{
        "id" => 990_001,
        "node_id" => "R_external"
      })

    assert {:error, :ineligible_pull} =
             resolve(put_in(c.fields["base_sha"], String.duplicate("c", 40)))
  end

  test "rejects contradictory paired identity and local cursor", c do
    assert {:error, :identity_conflict} =
             resolve(put_in(c.identity.provider_identity["github_number"], 8))

    cursor = Map.put(c.operation.cursor, "issue_id", 123)

    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [cursor: cursor]
    )

    assert {:error, _} = resolve(%{c | operation: %{c.operation | cursor: cursor}})
  end

  test "expired lease never returns a usable proof", c do
    Repo.update_all(from(o in MirrorOperation, where: o.id == ^c.operation.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:error, _} = resolve(c)
  end

  defp resolve(c), do: ForgeMirrors.resolve_remote_pull_head(c.operation, c.identity, c.fields)
end
