defmodule ForgeMirrors.PatGitEnrollmentTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorOperation, MirrorRefState, OrganizationMirror, PatConfiguration}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization_id = organization_fixture()
    owner = organization_owner_fixture(organization_id)

    identity =
      Repo.insert!(%ForgeAccounts.GitHubIdentity{
        kind: :user,
        github_user_id: System.unique_integer([:positive]),
        login: "pat-enroll-#{System.unique_integer([:positive])}",
        local_user_id: owner.id
      })

    credential =
      Repo.insert!(%ForgeAccounts.GitHubCredential{
        local_user_id: owner.id,
        github_identity_id: identity.id,
        ciphertext: "encrypted",
        nonce: <<0::96>>,
        tag: <<0::128>>,
        key_id: "test",
        status: :valid
      })

    config =
      Repo.insert!(%PatConfiguration{
        organization_id: organization_id,
        owner_user_id: owner.id,
        github_identity_id: identity.id,
        github_organization: "duskmoon-dev",
        enabled: true
      })

    repository_id = repository_fixture(organization_id)
    relative_path = "pat-git-enrollment/#{Ecto.UUID.generate()}.git"

    Repo.get!(ForgeRepos.Repository, repository_id)
    |> Ecto.Changeset.change(storage_path: relative_path)
    |> Repo.update!()

    github_id = System.unique_integer([:positive])
    account_id = System.unique_integer([:positive])

    run =
      Repo.insert!(
        struct(ForgeImports.ImportRun, %{
          actor_user_id: owner.id,
          source_kind: :organization,
          credential_source: :saved,
          github_identity_id: identity.id,
          github_credential_id: credential.id,
          source_owner_github_id: account_id,
          source_owner_login: "duskmoon-dev",
          destination_organization_action: :existing,
          destination_organization_id: organization_id,
          destination_organization_slug: Repo.get!(ForgeAccounts.User, organization_id).username,
          destination_organization_status: :clean,
          state: :completed,
          terminal_at: DateTime.utc_now(:second)
        })
      )

    item =
      Repo.insert!(
        struct(ForgeImports.RepositoryItem, %{
          import_run_id: run.id,
          github_repository_id: github_id,
          source_full_name: "duskmoon-dev/pat-enrollment",
          source_name: "pat-enrollment",
          source_observed_at: DateTime.utc_now(:second),
          destination_owner_id: organization_id,
          destination_slug: Repo.get!(ForgeRepos.Repository, repository_id).slug,
          destination_visibility: :private,
          hidden_repository_id: repository_id,
          state: :completed,
          publication_evidence: %{
            "state" => "committed",
            "repository_id" => repository_id,
            "owner_user_id" => organization_id,
            "generation" => 1,
            "run_id" => run.id
          }
        })
      )

    %{
      owner: owner,
      config: config,
      credential: credential,
      repository_id: repository_id,
      organization_id: organization_id,
      item: item,
      github_id: github_id,
      account_id: account_id
    }
  end

  test "explicit completed import enrollment has no invented ref baseline or installation", c do
    assert {:ok, :legacy} = ForgeMirrors.pat_repository_handoff(c.config.id, c.repository_id)

    assert {:ok,
            %{organization_mirror: mirror, repository_mirrors: [binding], operations: [operation]}} =
             ForgeMirrors.enroll_pat_git_repositories(
               c.owner,
               c.organization_id,
               c.config.lock_version,
               [c.repository_id],
               %{}
             )

    assert mirror.credential_source == :pat
    assert mirror.github_installation_id == nil
    assert mirror.pat_configuration_id == c.config.id
    assert mirror.github_account_id == c.account_id
    assert mirror.capabilities == %{"git" => true, "lfs" => true}
    assert binding.github_repository_id == c.github_id
    assert binding.bootstrap_repository_item_id == c.item.id
    assert operation.kind == "reconcile.repository.git"
    refute Repo.exists?(from r in MirrorRefState, where: r.repository_mirror_id == ^binding.id)

    assert {:ok, {:mirror, %{id: binding_id}}} =
             ForgeMirrors.pat_repository_handoff(c.config.id, c.repository_id)

    assert binding_id == binding.id
    assert Repo.get!(PatConfiguration, c.config.id).direction == "github_to_fornacast"
  end

  test "unknown provenance, stale configuration and active legacy jobs prevent handoff", c do
    unknown = repository_fixture(c.organization_id)

    assert {:error, :unverified_import} =
             ForgeMirrors.enroll_pat_git_repositories(
               c.owner,
               c.organization_id,
               c.config.lock_version,
               [unknown],
               %{}
             )

    assert {:error, :stale} =
             ForgeMirrors.enroll_pat_git_repositories(
               c.owner,
               c.organization_id,
               c.config.lock_version + 1,
               [c.repository_id],
               %{}
             )

    Repo.insert_all("organization_pat_sync_runs", [
      %{
        configuration_id: c.config.id,
        organization_id: c.organization_id,
        owner_user_id: c.owner.id,
        github_identity_id: c.config.github_identity_id,
        github_organization: "duskmoon-dev",
        state: "queued",
        inserted_at: DateTime.utc_now(:second),
        updated_at: DateTime.utc_now(:second)
      }
    ])

    assert {:error, :legacy_sync_active} =
             ForgeMirrors.enroll_pat_git_repositories(
               c.owner,
               c.organization_id,
               c.config.lock_version,
               [c.repository_id],
               %{}
             )

    refute Repo.exists?(OrganizationMirror)
  end

  test "fresh PAT authority rejects credential rotation and lost organization ownership", c do
    assert {:ok, %{operations: [operation]}} =
             ForgeMirrors.enroll_pat_git_repositories(
               c.owner,
               c.organization_id,
               c.config.lock_version,
               [c.repository_id],
               %{}
             )

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_operations("pat-test", DateTime.utc_now(:second), 60, 10, [
               "reconcile.repository.git"
             ])

    assert claimed.id == operation.id
    assert {:ok, scope} = ForgeMirrors.git_repository_operation_context(claimed)
    assert :ok = ForgeMirrors.authorize_pat_credential(scope)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(ForgeAccounts.GitHubCredential, c.credential.id),
        verification_version: 2
      )
    )

    assert {:error, :credential_unavailable} = ForgeMirrors.authorize_pat_credential(scope)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(ForgeAccounts.GitHubCredential, c.credential.id),
        verification_version: 1
      )
    )

    Repo.delete_all(
      from m in ForgeAccounts.OrganizationMember,
        where: m.organization_id == ^c.organization_id and m.user_id == ^c.owner.id
    )

    assert {:error, :credential_unavailable} = ForgeMirrors.authorize_pat_credential(scope)
    assert Repo.get!(MirrorOperation, operation.id).state == :processing
  end

  test "first reconciliation retains unknown baseline and status waits for its finalizer", c do
    assert {:ok, %{operations: [parent]}} = enroll(c)
    now = DateTime.utc_now(:second)

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "reconcile.repository.git"
             ])

    assert {:ok,
            %{operation: %{state: :completed}, ref_operations: [child], finalizer: finalizer}} =
             ForgeMirrors.fanout_git_ref_reconciliation(claimed, ["refs/heads/main"], now)

    assert child.cursor["initial_absence"] == false

    assert {:ok, :pending} =
             ForgeMirrors.pat_git_repository_status(
               c.owner,
               c.config.id,
               c.repository_id,
               parent.id
             )

    assert {:ok, [ref]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "sync.git_ref"
             ])

    assert {:ok, %{baseline: :missing}} = ForgeMirrors.git_ref_operation_context(ref)
    oid = String.duplicate("a", 40)

    assert {:conflict, :missing_baseline} =
             ForgeMirrors.GitRefDecision.decide(:branch, :missing, nil, oid, fn _, _ ->
               {:ok, true}
             end)

    assert {:ok, _} = ForgeMirrors.confirm_git_ref(ref, "refs/heads/main", oid, oid, now)

    assert {:ok, :pending} =
             ForgeMirrors.pat_git_repository_status(
               c.owner,
               c.config.id,
               c.repository_id,
               parent.id
             )

    assert {:ok, [finalizer_claim]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "finalize.repository.git"
             ])

    assert finalizer_claim.id == finalizer.id
    assert {:ok, _} = ForgeMirrors.finalize_git_ref_reconciliation(finalizer_claim, now)

    assert {:ok, :complete} =
             ForgeMirrors.pat_git_repository_status(
               c.owner,
               c.config.id,
               c.repository_id,
               parent.id
             )

    assert {:ok, next} =
             ForgeMirrors.schedule_pat_git_repository(
               c.owner,
               c.config.id,
               c.repository_id,
               "after-full-snapshot"
             )

    assert {:ok, [next_claim]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "reconcile.repository.git"
             ])

    assert next_claim.id == next.id

    assert {:ok, %{ref_operations: [new_child]}} =
             ForgeMirrors.fanout_git_ref_reconciliation(
               next_claim,
               ["refs/heads/new"],
               now
             )

    assert new_child.cursor["initial_absence"] == true

    assert {:ok, [new_ref]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "sync.git_ref"
             ])

    assert {:ok, %{baseline: nil}} = ForgeMirrors.git_ref_operation_context(new_ref)

    assert {:apply_local, nil, ^oid} =
             ForgeMirrors.GitRefDecision.decide(:branch, nil, nil, oid, fn _, _ -> {:ok, true} end)
  end

  test "request scheduling stays idempotent after completion and ignores metadata events", c do
    assert {:ok, %{organization_mirror: mirror, operations: [enrollment]}} = enroll(c)
    now = DateTime.utc_now(:second)
    finish_empty(enrollment, now)

    assert {:ok, first} =
             ForgeMirrors.schedule_pat_git_repository(
               c.owner,
               c.config.id,
               c.repository_id,
               "job-123"
             )

    assert {:ok, replay} =
             ForgeMirrors.schedule_pat_git_repository(
               c.owner,
               c.config.id,
               c.repository_id,
               "job-123"
             )

    assert replay.id == first.id
    finish_empty(first, now)

    assert {:ok, terminal_replay} =
             ForgeMirrors.schedule_pat_git_repository(
               c.owner,
               c.config.id,
               c.repository_id,
               "job-123"
             )

    assert terminal_replay.id == first.id
    assert terminal_replay.state == :completed

    assert {:ok, %{candidates: [%{repository_id: id, enrolled: true}]}} =
             ForgeMirrors.pat_git_enrollment_view(c.owner, c.organization_id)

    assert id == c.repository_id

    event = %Fornacast.DomainOutboxEvent{
      event_id: Ecto.UUID.generate(),
      aggregate_type: "repository",
      aggregate_id: Integer.to_string(c.repository_id),
      event_type: "repository.updated",
      origin: :fornacast,
      payload: %{"repository_id" => c.repository_id, "owner_id" => c.organization_id},
      available_at: now
    }

    assert {:ok, {:materialized, []}} = ForgeMirrors.materialize_outbox_event(event)

    refute Repo.exists?(
             from o in MirrorOperation,
               where:
                 o.organization_mirror_id == ^mirror.id and
                   o.kind in ["reconcile.organization_inventory", "reconcile.repository.metadata"]
           )
  end

  test "fresh PAT scope rejects pause, config changes, repository replacement and expired lease",
       c do
    assert {:ok, %{organization_mirror: mirror}} = enroll(c)
    now = DateTime.utc_now(:second)

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "reconcile.repository.git"
             ])

    assert {:ok, scope} = ForgeMirrors.git_repository_operation_context(claimed)
    Repo.update!(Ecto.Changeset.change(Repo.get!(PatConfiguration, c.config.id), paused: true))
    assert {:error, :paused} = ForgeMirrors.authorize_pat_credential(scope)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(PatConfiguration, c.config.id),
        paused: false,
        lock_version: 2
      )
    )

    assert {:error, :credential_unavailable} = ForgeMirrors.authorize_pat_credential(scope)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(PatConfiguration, c.config.id),
        paused: false,
        lock_version: 1
      )
    )

    repository = Repo.get!(ForgeRepos.Repository, c.repository_id)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(ForgeRepos.Repository, repository.id), generation: 2)
    )

    assert {:error, :credential_unavailable} = ForgeMirrors.authorize_pat_credential(scope)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(ForgeRepos.Repository, repository.id), generation: 1)
    )

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(OrganizationMirror, mirror.id),
        capabilities: %{"git" => false, "lfs" => true}
      )
    )

    assert {:error, :permission_missing} = ForgeMirrors.authorize_pat_credential(scope)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(OrganizationMirror, mirror.id),
        capabilities: %{"git" => true, "lfs" => true}
      )
    )

    Repo.update!(Ecto.Changeset.change(claimed, lease_expires_at: DateTime.add(now, -1)))
    assert {:error, :lost_lease} = ForgeMirrors.authorize_pat_credential(scope)
  end

  test "explicit same-authority reauthorization refreshes pins and preserves confirmed baselines",
       c do
    assert {:ok,
            %{organization_mirror: original, repository_mirrors: [binding], operations: [parent]}} =
             enroll(c)

    now = DateTime.utc_now(:second)

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "reconcile.repository.git"
             ])

    assert claimed.id == parent.id

    assert {:ok, %{ref_operations: [_]}} =
             ForgeMirrors.fanout_git_ref_reconciliation(claimed, ["refs/heads/main"], now)

    assert {:ok, [ref]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "sync.git_ref"
             ])

    oid = String.duplicate("a", 40)

    assert {:ok, %{ref_state: baseline}} =
             ForgeMirrors.confirm_git_ref(ref, "refs/heads/main", oid, oid, now)

    assert {:ok, [finalizer]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "finalize.repository.git"
             ])

    assert {:ok, _} = ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    config =
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(PatConfiguration, c.config.id), lock_version: 2)
      )

    credential =
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(ForgeAccounts.GitHubCredential, c.credential.id),
          verification_version: 2
        )
      )

    assert {:error, :credential_unavailable} =
             ForgeMirrors.authorize_pat_credential(
               ForgeMirrors.PatGitMirror.scope(original, binding)
             )

    assert {:ok,
            %{
              organization_mirror: refreshed,
              repository_mirrors: [same_binding],
              operations: [operation]
            }} =
             ForgeMirrors.enroll_pat_git_repositories(
               c.owner,
               c.organization_id,
               config.lock_version,
               [c.repository_id],
               %{}
             )

    assert refreshed.id == original.id
    assert refreshed.pat_configuration_version == 2
    assert refreshed.github_credential_id == credential.id
    assert refreshed.github_credential_version == 2
    assert same_binding.id == binding.id
    assert operation.id != parent.id
    assert Repo.get!(MirrorRefState, baseline.id).confirmed_oid == oid

    assert :ok =
             ForgeMirrors.authorize_pat_credential(
               ForgeMirrors.PatGitMirror.scope(refreshed, same_binding)
             )
  end

  test "persisted PAT deletion markers cannot authorize credentials or effects", c do
    assert {:ok,
            %{organization_mirror: mirror, repository_mirrors: [binding], operations: [parent]}} =
             enroll(c)

    now = DateTime.utc_now(:second)
    finish_empty(parent, now)

    assert {:ok, _} =
             ForgeMirrors.enqueue_operation(%{
               organization_mirror_id: mirror.id,
               repository_mirror_id: binding.id,
               kind: "sync.git_ref",
               dedupe_key: "pat-delete-test",
               cursor: %{"ref_name" => "refs/heads/main"},
               next_attempt_at: now
             })

    assert {:ok, [ref]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "sync.git_ref"
             ])

    assert {:ok, scope} = ForgeMirrors.git_ref_operation_context(ref)

    marker = %{
      "action" => "delete_remote",
      "ref" => "refs/heads/main",
      "expected_oid" => String.duplicate("a", 40),
      "proposed_oid" => nil
    }

    assert {:ok, marked} = ForgeMirrors.mark_external_effect(ref, now, marker)
    assert {:error, :ref_deletion_disabled} = ForgeMirrors.authorize_pat_credential(scope)

    assert {:error, :ref_deletion_disabled} =
             ForgeMirrors.authorize_external_effect(marked, marker)

    assert Repo.get!(MirrorOperation, marked.id).external_effect_marker == marker
  end

  test "superseded finalizers report pending until their replacement snapshot succeeds", c do
    assert {:ok, %{operations: [parent]}} = enroll(c)
    now = DateTime.utc_now(:second)

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "reconcile.repository.git"
             ])

    assert {:ok, %{finalizer: original_finalizer}} =
             ForgeMirrors.fanout_git_ref_reconciliation(claimed, [], now)

    assert {:ok, replacement} =
             ForgeMirrors.schedule_pat_git_repository(
               c.owner,
               c.config.id,
               c.repository_id,
               "superseding-request"
             )

    assert {:ok, [finalizer]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "finalize.repository.git"
             ])

    assert finalizer.id == original_finalizer.id

    assert {:ok, %{replacement: %{id: replacement_id}}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)

    assert replacement_id == replacement.id

    assert {:ok, :pending} =
             ForgeMirrors.pat_git_repository_status(
               c.owner,
               c.config.id,
               c.repository_id,
               parent.id
             )

    finish_empty(replacement, now)

    assert {:ok, :complete} =
             ForgeMirrors.pat_git_repository_status(
               c.owner,
               c.config.id,
               c.repository_id,
               parent.id
             )
  end

  defp enroll(c),
    do:
      ForgeMirrors.enroll_pat_git_repositories(
        c.owner,
        c.organization_id,
        c.config.lock_version,
        [c.repository_id],
        %{}
      )

  defp finish_empty(parent, _now) do
    now = DateTime.utc_now(:second)

    assert {:ok, [claimed]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "reconcile.repository.git"
             ])

    assert claimed.id == parent.id
    assert {:ok, _} = ForgeMirrors.fanout_git_ref_reconciliation(claimed, [], now)

    assert {:ok, [finalizer]} =
             ForgeMirrors.claim_pat_git_operations("pat", DateTime.utc_now(:second), 60, 10, [
               "finalize.repository.git"
             ])

    assert {:ok, _} = ForgeMirrors.finalize_git_ref_reconciliation(finalizer, now)
  end
end
