defmodule ForgeMirrors.ReviewGapsTest do
  use ExUnit.Case, async: false

  import ForgeMirrors.TestSupport.MirrorFixtures

  alias Fornacast.Repo
  alias ForgeMirrors.{MirrorOperation, OrganizationMirror, RepositoryMirror}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "organization mirrors reject personal user IDs" do
    actor = organization_fixture() |> organization_owner_fixture()

    assert {:error, :not_found} =
             ForgeMirrors.create_organization_mirror(actor, %{
               organization_id: user_fixture(),
               provider: "github"
             })
  end

  test "repository binding validates ownership and revalidates a filled local identity" do
    organization_mirror = active_organization_mirror_fixture()
    actor = organization_owner_fixture(organization_mirror)
    other_organization_id = organization_fixture()
    wrong_owner_repository_id = repository_fixture(other_organization_id)

    assert {:error, :not_found} =
             ForgeMirrors.bind_repository(actor, %{
               organization_mirror_id: organization_mirror.id,
               repository_id: wrong_owner_repository_id,
               github_repository_id: 501_001
             })

    assert {:ok, remote_only} =
             ForgeMirrors.bind_repository(actor, %{
               organization_mirror_id: organization_mirror.id,
               github_repository_id: 501_002
             })

    assert {:error, :not_found} =
             ForgeMirrors.update_repository_mirror(
               organization_owner_fixture(remote_only),
               remote_only,
               %{
                 repository_id: wrong_owner_repository_id
               }
             )

    owned_repository_id = repository_fixture(organization_mirror.organization_id)

    assert {:ok, bound} =
             ForgeMirrors.update_repository_mirror(
               organization_owner_fixture(remote_only),
               remote_only,
               %{
                 repository_id: owned_repository_id
               }
             )

    assert bound.repository_id == owned_repository_id
  end

  test "conflicts reject a repository mirror from a different organization mirror" do
    first_organization = active_organization_mirror_fixture()
    second_organization = active_organization_mirror_fixture()
    second_repository = repository_mirror_fixture(second_organization)

    attrs = %{
      organization_mirror_id: first_organization.id,
      repository_mirror_id: second_repository.id,
      resource_kind: "repository",
      resource_identity: "repo:#{second_repository.id}",
      conflict_kind: "namespace_collision",
      baseline_snapshot: %{},
      local_snapshot: %{},
      remote_snapshot: %{}
    }

    assert {:error, :not_found} = ForgeMirrors.record_conflict(attrs)

    first_repository = repository_mirror_fixture(first_organization)

    assert {:ok, valid_conflict} =
             attrs
             |> Map.merge(%{
               repository_mirror_id: first_repository.id,
               resource_identity: "repo:#{first_repository.id}"
             })
             |> ForgeMirrors.record_conflict()

    assert valid_conflict.organization_mirror_id == first_organization.id
    assert valid_conflict.repository_mirror_id == first_repository.id

    assert_raise Postgrex.Error, ~r/mirror_conflicts_repository_scope_fkey/, fn ->
      now = DateTime.utc_now(:second)

      Ecto.Adapters.SQL.query!(
        Repo,
        "insert into mirror_conflicts (organization_mirror_id, repository_mirror_id, resource_kind, resource_identity, conflict_kind, baseline_snapshot, local_snapshot, remote_snapshot, state, lock_version, inserted_at, updated_at) values ($1, $2, 'repository', 'direct-scope-check', 'namespace_collision', '{}', '{}', '{}', 'open', 1, $3, $3)",
        [first_organization.id, second_repository.id, now]
      )
    end
  end

  test "failure disposition is exhaustive and retry admits only retryable classes" do
    expected = %{
      "credential_revoked" => :terminal,
      "permission_missing" => :degraded,
      "primary_rate_limit" => :retry,
      "secondary_rate_limit" => :retry,
      "network" => :retry,
      "provider_validation" => :terminal,
      "local_validation" => :terminal,
      "stale_baseline" => :conflict,
      "git_divergence" => :conflict,
      "lfs_missing" => :degraded,
      "lfs_integrity" => :degraded,
      "namespace_collision" => :conflict,
      "unsupported_resource" => :terminal
    }

    assert Map.keys(expected) |> Enum.sort() == MirrorOperation.failure_classes() |> Enum.sort()

    Enum.each(expected, fn {failure_class, disposition} ->
      assert {:ok, ^disposition} = ForgeMirrors.failure_disposition(failure_class)
    end)

    organization_mirror = active_organization_mirror_fixture()
    now = DateTime.utc_now(:second)

    Enum.each(expected, fn {failure_class, disposition} ->
      operation =
        operation_fixture(organization_mirror, %{
          dedupe_key: "failure-disposition-#{failure_class}",
          next_attempt_at: now
        })

      assert {:ok, [claimed]} =
               ForgeMirrors.claim_operations("worker-#{failure_class}", now, 30, 1)

      if disposition == :retry do
        assert {:ok, retried} =
                 ForgeMirrors.retry_operation(
                   claimed,
                   now,
                   DateTime.add(now, 60),
                   failure_class
                 )

        assert retried.failure_disposition == :retry

        Ecto.Adapters.SQL.query!(Repo, "delete from mirror_operations where id = $1", [
          operation.id
        ])
      else
        assert {:error, :invalid_argument} =
                 ForgeMirrors.retry_operation(
                   claimed,
                   now,
                   DateTime.add(now, 60),
                   failure_class
                 )

        assert {:ok, failed} = ForgeMirrors.fail_operation(claimed, now, failure_class)
        assert failed.failure_disposition == disposition
      end
    end)

    assert {:error, :invalid_argument} = ForgeMirrors.failure_disposition("unknown")
  end

  test "all bound identities reject nil clearing" do
    %OrganizationMirror{} = organization_mirror = active_organization_mirror_fixture()
    %RepositoryMirror{} = repository_mirror = repository_mirror_fixture(organization_mirror)

    organization_mirror =
      %OrganizationMirror{
        organization_mirror
        | bootstrap_import_run_id: 123_456
      }

    repository_mirror =
      %RepositoryMirror{
        repository_mirror
        | bootstrap_repository_item_id: 654_321
      }

    organization_changeset =
      OrganizationMirror.update_changeset(organization_mirror, %{
        github_installation_id: nil,
        github_account_id: nil,
        bootstrap_import_run_id: nil
      })

    refute organization_changeset.valid?
    assert "is immutable once bound" in errors_on(organization_changeset).github_installation_id
    assert "is immutable once bound" in errors_on(organization_changeset).github_account_id
    assert "is immutable once bound" in errors_on(organization_changeset).bootstrap_import_run_id

    repository_changeset =
      ForgeMirrors.RepositoryMirror.update_changeset(repository_mirror, %{
        repository_id: nil,
        github_repository_id: nil,
        github_node_id: nil,
        bootstrap_repository_item_id: nil
      })

    refute repository_changeset.valid?
    assert "is immutable once bound" in errors_on(repository_changeset).repository_id
    assert "is immutable once bound" in errors_on(repository_changeset).github_repository_id
    assert "is immutable once bound" in errors_on(repository_changeset).github_node_id

    assert "is immutable once bound" in errors_on(repository_changeset).bootstrap_repository_item_id
  end

  test "every organization lifecycle edge executes and every non-edge is rejected" do
    transitions = OrganizationMirror.transitions()

    for source <- OrganizationMirror.states() -- [:paused],
        target <- OrganizationMirror.states() do
      mirror = organization_mirror_in_state(source)

      result =
        if target == :paused,
          do: ForgeMirrors.pause(organization_owner_fixture(mirror), mirror),
          else:
            ForgeMirrors.transition_organization_mirror(
              organization_owner_fixture(mirror),
              mirror,
              target
            )

      if target in Map.fetch!(transitions, source) do
        assert {:ok, transitioned} = result
        assert transitioned.state == target

        if target == :paused do
          assert transitioned.resume_state == source
        else
          assert transitioned.resume_state == nil
        end
      else
        assert {:error, :invalid_transition} = result
      end
    end
  end

  test "every pausable organization lifecycle resumes only to its exact prior state" do
    for resume_state <- [
          :ready_to_bootstrap,
          :bootstrapping,
          :catching_up,
          :active,
          :degraded,
          :conflicted
        ] do
      mirror = organization_mirror_in_state(resume_state)
      assert {:ok, paused} = ForgeMirrors.pause(organization_owner_fixture(mirror), mirror)
      assert paused.resume_state == resume_state

      for target <- OrganizationMirror.states() -- [:paused, :revoked] do
        assert {:error, :invalid_transition} =
                 ForgeMirrors.transition_organization_mirror(
                   organization_owner_fixture(paused),
                   paused,
                   target
                 )
      end

      assert {:ok, resumed} = ForgeMirrors.resume(organization_owner_fixture(paused), paused)
      assert resumed.state == resume_state
      assert resumed.resume_state == nil
    end
  end

  test "paused mirror may revoke atomically while all other direct paused transitions fail" do
    mirror = active_organization_mirror_fixture()
    assert {:ok, paused} = ForgeMirrors.pause(organization_owner_fixture(mirror), mirror)

    for target <- OrganizationMirror.states() -- [:paused, :revoked] do
      assert {:error, :invalid_transition} =
               ForgeMirrors.transition_organization_mirror(
                 organization_owner_fixture(paused),
                 paused,
                 target
               )
    end

    assert {:ok, revoked} =
             ForgeMirrors.transition_organization_mirror(
               organization_owner_fixture(paused),
               paused,
               :revoked
             )

    assert revoked.state == :revoked
    assert revoked.resume_state == nil
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp organization_mirror_in_state(:pending_installation), do: organization_mirror_fixture()

  defp organization_mirror_in_state(:ready_to_bootstrap),
    do: ready_organization_mirror_fixture()

  defp organization_mirror_in_state(:bootstrapping) do
    mirror = ready_organization_mirror_fixture()

    {:ok, mirror} =
      ForgeMirrors.transition_organization_mirror(
        organization_owner_fixture(mirror),
        mirror,
        :bootstrapping
      )

    mirror
  end

  defp organization_mirror_in_state(:catching_up) do
    mirror = organization_mirror_in_state(:bootstrapping)

    {:ok, mirror} =
      ForgeMirrors.transition_organization_mirror(
        organization_owner_fixture(mirror),
        mirror,
        :catching_up
      )

    mirror
  end

  defp organization_mirror_in_state(:active), do: active_organization_mirror_fixture()

  defp organization_mirror_in_state(:degraded) do
    mirror = organization_mirror_in_state(:bootstrapping)

    {:ok, mirror} =
      ForgeMirrors.transition_organization_mirror(
        organization_owner_fixture(mirror),
        mirror,
        :degraded
      )

    mirror
  end

  defp organization_mirror_in_state(:conflicted) do
    mirror = organization_mirror_in_state(:bootstrapping)

    {:ok, mirror} =
      ForgeMirrors.transition_organization_mirror(
        organization_owner_fixture(mirror),
        mirror,
        :conflicted
      )

    mirror
  end

  defp organization_mirror_in_state(:revoked) do
    mirror = organization_mirror_fixture()

    {:ok, mirror} =
      ForgeMirrors.transition_organization_mirror(
        organization_owner_fixture(mirror),
        mirror,
        :revoked
      )

    mirror
  end
end
