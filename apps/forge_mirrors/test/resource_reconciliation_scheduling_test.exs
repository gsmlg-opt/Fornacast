defmodule ForgeMirrors.ResourceReconciliationSchedulingTest do
  use ExUnit.Case, async: false
  import ForgeMirrors.TestSupport.MirrorFixtures
  alias ForgeMirrors.{MirrorOperation, OrganizationMirror, RepositoryMirror}
  alias Fornacast.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    organization = active_organization_mirror_fixture(%{capabilities: %{"issues" => "enabled"}})
    binding = repository_mirror_fixture(organization)
    %{organization: organization, binding: binding, now: DateTime.utc_now(:second)}
  end

  test "one inventory sweep durably schedules both bounded metadata sweeps idempotently", c do
    assert {:ok, [issues, comments]} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(
               c.binding,
               "inventory:one",
               c.now
             )

    assert [issues.kind, comments.kind] == [
             "reconcile.repository.issues",
             "reconcile.repository.issue_comments"
           ]

    assert issues.cursor["since"] == "1970-01-01T00:00:00Z"
    assert {:ok, _} = Ecto.UUID.cast(issues.cursor["sweep_id"])

    assert {:ok, replay} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(
               c.binding,
               "inventory:one",
               c.now
             )

    assert Enum.map(replay, & &1.id) == [issues.id, comments.id]

    assert {:ok, later} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(
               c.binding,
               "inventory:two",
               c.now
             )

    refute hd(later).id == issues.id
  end

  test "inventory sweep schedules one repository metadata reconciliation idempotently", c do
    assert {:ok, operation} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "inventory:repository-metadata",
               c.now
             )

    assert operation.kind == "reconcile.repository.metadata"

    assert operation.cursor == %{
             "sweep_key" => "inventory:repository-metadata",
             "trigger" => "reconcile"
           }

    assert {:ok, replay} =
             ForgeMirrors.enqueue_repository_metadata_reconciliation(
               c.binding,
               "inventory:repository-metadata",
               c.now
             )

    assert replay.id == operation.id
  end

  test "pulls-only bootstrap requires the shared comment sweep and failed children block activation",
       c do
    c = bootstrap_binding(c)

    c.organization
    |> Ecto.Changeset.change(capabilities: %{"issues" => "disabled", "pulls" => "enabled"})
    |> Repo.update!()

    assert_git_does_not_activate(c)

    assert {:ok, [comments]} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(
               c.binding,
               "bootstrap:item:#{c.item.id}",
               c.now
             )

    assert comments.kind == "reconcile.repository.issue_comments"
    leased = claim(c, comments.kind, comments.id)

    assert {:ok, %{resource_kind: :issue_comment}} =
             ForgeMirrors.resource_operation_context(leased)

    Repo.get!(MirrorOperation, comments.id)
    |> Ecto.Changeset.change(
      state: :completed,
      completed_at: c.now,
      lease_owner: nil,
      lease_expires_at: nil
    )
    |> Repo.update!()

    operation_fixture(c.organization, %{
      repository_mirror_id: c.binding.id,
      kind: "sync.issue_comment",
      cursor: %{"sweep_id" => comments.cursor["sweep_id"], "github_object_id" => 900}
    })
    |> Ecto.Changeset.change(
      state: :failed,
      failure_class: "provider_validation",
      failure_disposition: :terminal
    )
    |> Repo.update!()

    assert_git_does_not_activate(c)
  end

  test "disabled issues and revoked connections cannot schedule metadata effects", c do
    c.organization
    |> Ecto.Changeset.change(capabilities: %{"issues" => "disabled"})
    |> Repo.update!()

    assert {:ok, []} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(
               c.binding,
               "disabled",
               c.now
             )

    Repo.get!(OrganizationMirror, c.organization.id)
    |> Ecto.Changeset.change(capabilities: %{"issues" => "enabled"}, state: :revoked)
    |> Repo.update!()

    assert {:error, :invalid_transition} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(c.binding, "revoked", c.now)
  end

  test "Git completion cannot activate before current bootstrap metadata sweeps", c do
    c = bootstrap_binding(c)

    root =
      completed_operation(c, "reconcile.repository.bootstrap", %{
        "bootstrap_repository_item_id" => c.item.id
      })

    finalizer =
      operation_fixture(c.organization, %{
        repository_mirror_id: c.binding.id,
        kind: "finalize.repository.git",
        cursor: %{"reconciliation_operation_id" => root.id},
        next_attempt_at: c.now
      })

    finalizer = claim(c, finalizer.kind, finalizer.id)

    assert {:ok, %{operation: completed}} =
             ForgeMirrors.finalize_git_ref_reconciliation(finalizer, c.now)

    assert completed.checkpoint["successful_bootstrap_item_id"] == c.item.id
    assert Repo.get!(RepositoryMirror, c.binding.id).state == :discovered
  end

  test "remote and mapped phases complete before the last metadata sweep activates", c do
    c = bootstrap_binding(c)

    root =
      completed_operation(c, "reconcile.repository.bootstrap", %{
        "bootstrap_repository_item_id" => c.item.id
      })

    completed_operation(c, "finalize.repository.git", %{"reconciliation_operation_id" => root.id})

    assert {:ok, operations} =
             ForgeMirrors.enqueue_repository_resource_reconciliations(
               c.binding,
               "bootstrap:item:#{c.item.id}",
               c.now
             )

    for {operation, index} <- Enum.with_index(operations) do
      kind = if index == 0, do: :issue, else: :issue_comment
      leased = claim(c, operation.kind, operation.id)

      assert {:ok, %{operation: mapped}} =
               ForgeMirrors.record_resource_reconciliation_page(leased, kind, [], nil, c.now)

      assert mapped.state == :pending
      assert mapped.checkpoint["phase"] == "mapped"
      assert Repo.get!(RepositoryMirror, c.binding.id).state == :discovered
      leased = claim(c, operation.kind, operation.id)

      assert {:ok, %{phase: :mapped, mapping_cursor: nil}} =
               ForgeMirrors.resource_operation_context(leased)

      assert {:ok, %{operation: completed}} =
               ForgeMirrors.record_resource_reconciliation_page(leased, kind, [], nil, c.now)

      assert completed.state == :completed

      assert Repo.get!(RepositoryMirror, c.binding.id).state ==
               if(index == 0, do: :discovered, else: :active)
    end
  end

  test "failed metadata children prevent Git finalizer activation", c do
    c = bootstrap_binding(c)

    {:ok, sweeps} =
      ForgeMirrors.enqueue_repository_resource_reconciliations(
        c.binding,
        "bootstrap:item:#{c.item.id}",
        c.now
      )

    Enum.each(
      sweeps,
      &(&1 |> Ecto.Changeset.change(state: :completed, completed_at: c.now) |> Repo.update!())
    )

    operation_fixture(c.organization, %{
      repository_mirror_id: c.binding.id,
      kind: "sync.issue",
      cursor: %{"sweep_id" => hd(sweeps).cursor["sweep_id"], "github_object_id" => 55}
    })
    |> Ecto.Changeset.change(
      state: :failed,
      failure_class: "provider_validation",
      failure_disposition: :terminal
    )
    |> Repo.update!()

    assert_git_does_not_activate(c)
  end

  test "unfinished release children prevent Git finalizer activation", c do
    c = bootstrap_binding(c)

    c.organization
    |> Ecto.Changeset.change(capabilities: %{"issues" => "enabled", "releases" => "enabled"})
    |> Repo.update!()

    root =
      completed_operation(c, "reconcile.repository.bootstrap", %{
        "bootstrap_repository_item_id" => c.item.id
      })

    completed_operation(c, "finalize.repository.git", %{"reconciliation_operation_id" => root.id})

    {:ok, sweeps} =
      ForgeMirrors.enqueue_repository_resource_reconciliations(
        c.binding,
        "bootstrap:item:#{c.item.id}",
        c.now
      )

    release_sweep = Enum.find(sweeps, &(&1.kind == "reconcile.repository.releases"))

    sweeps
    |> Enum.reject(&(&1.id == release_sweep.id))
    |> Enum.each(
      &(&1
        |> Ecto.Changeset.change(state: :completed, completed_at: c.now)
        |> Repo.update!())
    )

    release_sweep = claim(c, release_sweep.kind, release_sweep.id)

    assert {:ok, %{operation: yielded, operations: [release_child]}} =
             ForgeMirrors.record_resource_reconciliation_page(
               release_sweep,
               :release,
               [
                 %{
                   github_object_id: 55,
                   tag_name: "v1.0.0",
                   remote_updated_at: c.now
                 }
               ],
               nil,
               c.now
             )

    assert release_child.state == :pending
    release_sweep = claim(c, yielded.kind, yielded.id)

    assert {:ok, %{operation: completed}} =
             ForgeMirrors.record_resource_reconciliation_page(
               release_sweep,
               :release,
               [],
               nil,
               c.now
             )

    assert completed.state == :completed
    assert Repo.get!(RepositoryMirror, c.binding.id).state == :discovered
  end

  test "mapped cursor survives reclaim and rejects scope or high-water replacement", c do
    {:ok, [sweep | _]} =
      ForgeMirrors.enqueue_repository_resource_reconciliations(c.binding, "cursor-proof", c.now)

    leased = claim(c, sweep.kind, sweep.id)

    assert {:ok, _} =
             ForgeMirrors.record_resource_reconciliation_page(leased, :issue, [], nil, c.now)

    leased = claim(c, sweep.kind, sweep.id)

    cursor = %{
      "repository_mirror_id" => c.binding.id,
      "resource_kind" => "issue",
      "after_id" => 10,
      "through_id" => 100
    }

    assert {:ok, _} =
             ForgeMirrors.record_resource_reconciliation_page(leased, :issue, [], cursor, c.now)

    leased = claim(c, sweep.kind, sweep.id)

    assert {:ok, %{phase: :mapped, mapping_cursor: ^cursor}} =
             ForgeMirrors.resource_operation_context(leased)

    for invalid <- [
          cursor,
          %{cursor | "repository_mirror_id" => c.binding.id + 1, "after_id" => 20},
          %{cursor | "through_id" => 101, "after_id" => 20}
        ] do
      assert {:error, :invalid_transition} =
               ForgeMirrors.record_resource_reconciliation_page(
                 leased,
                 :issue,
                 [],
                 invalid,
                 c.now
               )
    end

    assert {:ok, %{operation: completed}} =
             ForgeMirrors.record_resource_reconciliation_page(leased, :issue, [], nil, c.now)

    assert completed.state == :completed
  end

  test "a completed superseded Git finalizer is not successful publication proof", c do
    c = bootstrap_binding(c)

    root =
      completed_operation(c, "reconcile.repository.bootstrap", %{
        "bootstrap_repository_item_id" => c.item.id
      })

    finalizer =
      completed_operation(c, "finalize.repository.git", %{
        "reconciliation_operation_id" => root.id
      })

    finalizer |> Ecto.Changeset.change(checkpoint: %{}) |> Repo.update!()

    {:ok, sweeps} =
      ForgeMirrors.enqueue_repository_resource_reconciliations(
        c.binding,
        "bootstrap:item:#{c.item.id}",
        c.now
      )

    for sweep <- sweeps, _phase <- [:remote, :mapped] do
      leased = claim(c, sweep.kind, sweep.id)
      kind = if sweep.cursor["resource_kind"] == "issue", do: :issue, else: :issue_comment

      assert {:ok, _} =
               ForgeMirrors.record_resource_reconciliation_page(leased, kind, [], nil, c.now)
    end

    assert Repo.get!(RepositoryMirror, c.binding.id).state == :discovered
  end

  test "historical completed metadata sweeps do not satisfy current bootstrap", c do
    c = bootstrap_binding(c)

    {:ok, sweeps} =
      ForgeMirrors.enqueue_repository_resource_reconciliations(
        c.binding,
        "bootstrap:item:previous",
        c.now
      )

    Enum.each(sweeps, fn op ->
      op
      |> Ecto.Changeset.change(
        state: :completed,
        completed_at: c.now,
        cursor: Map.put(op.cursor, "bootstrap_repository_item_id", c.item.id + 1)
      )
      |> Repo.update!()
    end)

    assert_git_does_not_activate(c)
  end

  test "an open metadata conflict blocks activation even with completed sweeps", c do
    c = bootstrap_binding(c)

    {:ok, sweeps} =
      ForgeMirrors.enqueue_repository_resource_reconciliations(
        c.binding,
        "bootstrap:item:#{c.item.id}",
        c.now
      )

    Enum.each(
      sweeps,
      &(&1 |> Ecto.Changeset.change(state: :completed, completed_at: c.now) |> Repo.update!())
    )

    assert {:ok, _} =
             ForgeMirrors.record_conflict(%{
               organization_mirror_id: c.organization.id,
               repository_mirror_id: c.binding.id,
               resource_kind: "issue",
               resource_identity: "55",
               conflict_kind: "both_changed",
               baseline_snapshot: %{},
               local_snapshot: %{},
               remote_snapshot: %{}
             })

    assert_git_does_not_activate(c)
  end

  test "paused and revoked scope cannot complete a leased metadata sweep", c do
    for state <- [:paused, :revoked] do
      organization = active_organization_mirror_fixture(%{capabilities: %{"issues" => "enabled"}})

      c =
        bootstrap_binding(%{
          organization: organization,
          binding: repository_mirror_fixture(organization),
          now: c.now
        })

      {:ok, [sweep | _]} =
        ForgeMirrors.enqueue_repository_resource_reconciliations(
          c.binding,
          "bootstrap:item:#{c.item.id}",
          c.now
        )

      leased = claim(c, sweep.kind, sweep.id)

      Repo.get!(OrganizationMirror, c.organization.id)
      |> Ecto.Changeset.change(state: state)
      |> Repo.update!()

      expected_error = if state == :paused, do: :paused, else: :invalid_transition

      assert {:error, ^expected_error} =
               ForgeMirrors.record_resource_reconciliation_page(leased, :issue, [], nil, c.now)

      assert Repo.get!(RepositoryMirror, c.binding.id).state == :discovered
      assert Repo.get!(MirrorOperation, sweep.id).state == :processing
    end
  end

  test "paused and revoked scope cannot activate through a previously leased Git finalizer", c do
    for state <- [:paused, :revoked] do
      organization = active_organization_mirror_fixture(%{capabilities: %{"issues" => "enabled"}})

      c =
        bootstrap_binding(%{
          organization: organization,
          binding: repository_mirror_fixture(organization),
          now: c.now
        })

      {:ok, sweeps} =
        ForgeMirrors.enqueue_repository_resource_reconciliations(
          c.binding,
          "bootstrap:item:#{c.item.id}",
          c.now
        )

      Enum.each(
        sweeps,
        &(&1 |> Ecto.Changeset.change(state: :completed, completed_at: c.now) |> Repo.update!())
      )

      root =
        completed_operation(c, "reconcile.repository.bootstrap", %{
          "bootstrap_repository_item_id" => c.item.id
        })

      finalizer =
        operation_fixture(c.organization, %{
          repository_mirror_id: c.binding.id,
          kind: "finalize.repository.git",
          cursor: %{"reconciliation_operation_id" => root.id},
          next_attempt_at: c.now
        })

      leased = claim(c, finalizer.kind, finalizer.id)

      Repo.get!(OrganizationMirror, c.organization.id)
      |> Ecto.Changeset.change(state: state)
      |> Repo.update!()

      expected_error = if state == :paused, do: :paused, else: :invalid_transition

      assert {:error, ^expected_error} =
               ForgeMirrors.finalize_git_ref_reconciliation(leased, c.now)

      assert Repo.get!(RepositoryMirror, c.binding.id).state == :discovered
    end
  end

  defp assert_git_does_not_activate(c) do
    root =
      completed_operation(c, "reconcile.repository.bootstrap", %{
        "bootstrap_repository_item_id" => c.item.id
      })

    finalizer =
      operation_fixture(c.organization, %{
        repository_mirror_id: c.binding.id,
        kind: "finalize.repository.git",
        cursor: %{"reconciliation_operation_id" => root.id},
        next_attempt_at: c.now
      })

    finalizer = claim(c, finalizer.kind, finalizer.id)
    assert {:ok, _} = ForgeMirrors.finalize_git_ref_reconciliation(finalizer, c.now)
    assert Repo.get!(RepositoryMirror, c.binding.id).state == :discovered
  end

  defp claim(c, kind, id) do
    {:ok, operations} = ForgeMirrors.claim_operations("metadata-gate", c.now, 60, 100, [kind])
    Enum.find(operations, &(&1.id == id))
  end

  defp completed_operation(c, kind, cursor) do
    operation_fixture(c.organization, %{
      repository_mirror_id: c.binding.id,
      kind: kind,
      cursor: cursor,
      next_attempt_at: c.now
    })
    |> Ecto.Changeset.change(
      state: :completed,
      completed_at: c.now,
      checkpoint:
        if(kind == "finalize.repository.git",
          do: %{"successful_bootstrap_item_id" => c.item.id},
          else: %{}
        )
    )
    |> Repo.update!()
  end

  defp bootstrap_binding(c) do
    owner = organization_owner_fixture(c.organization)
    organization = Repo.get!(ForgeAccounts.User, c.organization.organization_id)

    run =
      %ForgeImports.ImportRun{}
      |> ForgeImports.ImportRun.creation_changeset(owner.id, %{
        source_kind: :organization,
        credential_source: :github_app,
        source_owner_github_id: c.organization.github_account_id,
        source_owner_login: c.organization.github_account_login,
        destination_organization_action: :existing,
        destination_organization_slug: organization.username,
        destination_organization_id: organization.id,
        destination_organization_status: :clean,
        request_metadata: %{}
      })
      |> Repo.insert!()

    item =
      %ForgeImports.RepositoryItem{}
      |> ForgeImports.RepositoryItem.discovery_changeset(%{
        import_run_id: run.id,
        github_repository_id: c.binding.github_repository_id,
        source_full_name: c.binding.github_full_name,
        source_name: "repository",
        source_metadata: %{},
        source_observed_at: c.now
      })
      |> Repo.insert!()

    binding =
      c.binding
      |> Ecto.Changeset.change(state: :discovered, bootstrap_repository_item_id: item.id)
      |> Repo.update!()

    org =
      c.organization
      |> Ecto.Changeset.change(state: :catching_up, bootstrap_import_run_id: run.id)
      |> Repo.update!()

    Map.merge(c, %{binding: binding, organization: org, item: item})
  end
end
