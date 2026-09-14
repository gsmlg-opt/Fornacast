defmodule ForgeGitHub.ReleaseSyncWorkerTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.{Error, InstallationToken, ReleaseSyncWorker}
  alias ForgeMirrors.MirrorOperation

  @now ~U[2026-09-14 08:00:00Z]
  @oid String.duplicate("a", 40)
  @base %{
    "tag_name" => "v1.0.0",
    "name" => "Version 1",
    "body" => "notes",
    "draft" => false,
    "prerelease" => false,
    "target_commitish" => "main",
    "published_at" => ~U[2026-09-14 07:00:00Z]
  }

  test "records the canonical immutable release before scheduling tag proof" do
    parent = self()
    operation = operation(:processing)

    options =
      options(operation,
        get_release: fn "ephemeral", "acme", "widgets", 41, request_options ->
          assert request_options[:gate_key] == {:github_installation, 44}
          {:ok, github_release(@base, asset_count: 2)}
        end,
        asset_warning: fn warning ->
          assert warning == %{github_object_id: 41, tag_name: "v1.0.0", asset_count: 2}
          send(parent, :asset_warning)
          :ok
        end,
        record_canonical: fn ^operation, observation, @now ->
          assert observation == %{
                   github_object_id: 41,
                   tag_name: "v1.0.0",
                   remote_updated_at: ~U[2026-09-14 07:30:00Z]
                 }

          send(parent, :canonical_recorded)
          {:ok, %{operation | state: :pending}}
        end,
        prepare_tag_proof: fn _, _, _ -> flunk("tag proof preceded canonical observation") end,
        confirm: fn _, _, _, _, _ -> flunk("release mutated before tag proof") end
      )

    assert {:ok, %MirrorOperation{state: :pending}} =
             ReleaseSyncWorker.process_operation(operation, @now, options)

    assert collect_events(2) == [:asset_warning, :canonical_recorded]
  end

  test "canonical observation schedules exact tag proof before any metadata effect" do
    operation = operation(:processing, checkpoint: canonical_checkpoint())

    options =
      options(operation,
        get_release: fn _, _, _, _, _ ->
          flunk("canonical release was fetched twice before proof")
        end,
        prepare_tag_proof: fn ^operation, "v1.0.0", @now ->
          {:ok, %{operation: %{operation | state: :completed}, continuation: :continuation}}
        end,
        mark_effect: fn _, _, _ -> flunk("provider write preceded tag proof") end,
        confirm: fn _, _, _, _, _ -> flunk("local write preceded tag proof") end
      )

    assert {:ok, %{continuation: :continuation}} =
             ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "re-fetches immutable release after tag proof and applies inbound update atomically" do
    parent = self()
    proof = tag_proof()
    operation = operation(:processing, checkpoint: canonical_checkpoint())
    remote_fields = Map.put(@base, "body", "remote notes")

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(proof, baseline: @base, local_version: 3)}
        end,
        local_observe: fn _ -> {:ok, local_release(@base, 3)} end,
        get_release: fn _, _, _, 41, _ ->
          send(parent, :canonical_refetched)
          {:ok, github_release(remote_fields)}
        end,
        author_observe: fn %{"id" => 501}, @now -> {:ok, %{id: 901}} end,
        confirm: fn ^operation, @now, expected, confirmation, request ->
          assert_received :canonical_refetched
          assert expected.tag_proof == proof
          assert expected.github_node_id == "RE_41"
          assert confirmation.tag_proof == proof
          assert confirmation.confirmed_snapshot == remote_fields
          assert confirmation.confirmed_local_version == 4
          assert request.action == :update
          assert request.expected_local_version == 3
          assert request.fields == remote_fields
          assert request.tag_proof == proof
          assert request.provenance.origin == :github
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "persists an outbound update marker before GitHub and uses minimum local observation" do
    parent = self()
    proof = tag_proof()
    operation = operation(:processing, checkpoint: canonical_checkpoint())
    local_fields = Map.put(@base, "body", "local notes")

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(proof, baseline: @base, local_version: 4)}
        end,
        local_observe: fn _ -> {:ok, local_release(local_fields, 4)} end,
        get_release: fn _, _, _, 41, _ -> {:ok, github_release(@base)} end,
        mark_effect: fn ^operation, @now, marker ->
          assert marker["action"] == "update_remote_release"
          assert marker["github_object_id"] == 41
          assert marker["expected_local_version"] == 4
          assert marker["tag_proof"] == proof
          send(parent, :effect_marked)
          {:ok, %{operation | state: :effect_pending, external_effect_marker: marker}}
        end,
        update_release: fn _, _, _, 41, attrs, _ ->
          assert_received :effect_marked
          assert attrs == Map.drop(local_fields, ["published_at"])
          send(parent, :remote_updated)
          {:ok, github_release(local_fields, updated_at: "2026-09-14T08:00:01Z")}
        end,
        confirm: fn marked, @now, _expected, confirmation, request ->
          assert_received :remote_updated
          assert marked.state == :effect_pending
          assert confirmation.confirmed_snapshot == local_fields
          assert confirmation.tag_proof == proof
          assert request.action == :observe
          assert request.minimum_local_version == 4
          assert request.expected_fields == local_fields
          {:ok, :confirmed}
        end
      )

    assert {:ok, :confirmed} = ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "post-marker revocation defers release recovery without a fresh token or replay" do
    parent = self()
    local_fields = Map.put(@base, "body", "local notes")

    marker =
      effect_marker("update_remote_release", local_fields, 41)
      |> Map.put("expected_remote_fingerprint", fingerprint(@base))
      |> Map.put("expected_remote_updated_at", "2026-09-14T07:30:00Z")

    operation = operation(:effect_pending, marker: marker)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(tag_proof(), effect_marker: marker, local_version: 1)}
        end,
        local_observe: fn _ -> {:ok, local_release(local_fields, 1)} end,
        token_fetch: fn 44, _ ->
          send(parent, :token_fetch)

          %InstallationToken{
            token: "ephemeral",
            expires_at: DateTime.add(@now, 3_600),
            permissions: %{"contents" => "write", "metadata" => "read"}
          }
        end,
        get_release: fn _, _, _, 41, _ -> {:ok, github_release(@base)} end,
        authorize_effect: fn ^operation, ^marker -> {:error, :revoked} end,
        update_release: fn _, _, _, _, _, _ -> flunk("revoked effect replayed GitHub") end,
        defer_effect: fn ^operation, @now, retry_at, "network", "credential_unavailable" ->
          assert DateTime.after?(retry_at, @now)
          {:ok, :deferred}
        end
      )

    assert {:ok, :deferred} = ReleaseSyncWorker.process_operation(operation, @now, options)
    refute_received :token_fetch
  end

  test "recovers an ambiguous create only through the exact unique tag" do
    marker = effect_marker("create_remote_release", @base, nil)
    operation = operation(:effect_pending, marker: marker, github_object_id: nil)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok,
           context(tag_proof(),
             github_object_id: nil,
             github_node_id: nil,
             baseline: :missing,
             effect_marker: marker
           )}
        end,
        local_observe: fn _ -> {:ok, local_release(@base, 1)} end,
        get_release: fn _, _, _, _, _ -> flunk("unmapped create used immutable-ID fetch") end,
        get_release_by_tag: fn _, "acme", "widgets", "v1.0.0", _ ->
          {:ok, github_release(@base)}
        end,
        create_release: fn _, _, _, _, _ -> flunk("possibly successful create was repeated") end,
        confirm: fn ^operation, @now, _expected, confirmation, request ->
          assert confirmation.github_object_id == 41
          assert confirmation.tag_proof == tag_proof()
          assert request.action == :observe
          assert request.minimum_local_version == 1
          {:ok, :recovered}
        end
      )

    assert {:ok, :recovered} = ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "acknowledges an applied effect while preserving a newer local intent" do
    marker = effect_marker("update_remote_release", @base, 41)
    operation = operation(:effect_pending, marker: marker)
    newer_fields = Map.put(@base, "body", "newer local intent")

    options =
      options(operation,
        context: fn ^operation ->
          {:ok,
           context(tag_proof(),
             local_version: 2,
             effect_marker: marker
           )}
        end,
        local_observe: fn _ -> {:ok, local_release(newer_fields, 2)} end,
        get_release: fn _, _, _, 41, _ -> {:ok, github_release(@base)} end,
        update_release: fn _, _, _, _, _, _ -> flunk("applied effect was replayed") end,
        confirm: fn ^operation, @now, expected, confirmation, request ->
          assert expected.local_version == 2
          assert expected.github_node_id == "RE_41"
          assert confirmation.confirmed_local_version == 1
          assert confirmation.confirmed_snapshot == @base
          assert request.action == :observe
          assert request.minimum_local_version == 1
          assert request.expected_fields == @base
          {:ok, :acknowledged}
        end
      )

    assert {:ok, :acknowledged} =
             ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "replaces a not-applied marker before writing a newer local intent" do
    old_intent = Map.put(@base, "body", "old local intent")
    newer_intent = Map.put(@base, "body", "newer local intent")

    marker =
      effect_marker("update_remote_release", old_intent, 41)
      |> Map.put("expected_remote_fingerprint", fingerprint(@base))
      |> Map.put("expected_remote_updated_at", "2026-09-14T07:30:00Z")

    operation = operation(:effect_pending, marker: marker)
    parent = self()

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(tag_proof(), local_version: 2, effect_marker: marker)}
        end,
        local_observe: fn _ -> {:ok, local_release(newer_intent, 2)} end,
        get_release: fn _, _, _, 41, _ -> {:ok, github_release(@base)} end,
        replace_effect: fn ^operation, @now, ^marker, replacement ->
          assert replacement["expected_local_version"] == 2
          assert replacement["expected_local_fingerprint"] == fingerprint(newer_intent)
          assert replacement["proposed_fingerprint"] == fingerprint(newer_intent)
          send(parent, {:effect_replaced, replacement})
          {:ok, %{operation | external_effect_marker: replacement}}
        end,
        update_release: fn _, _, _, 41, attrs, _ ->
          assert_received {:effect_replaced, _replacement}
          assert attrs == Map.drop(newer_intent, ["published_at"])
          {:ok, github_release(newer_intent, updated_at: "2026-09-14T08:00:01Z")}
        end,
        confirm: fn marked, @now, expected, confirmation, request ->
          assert expected.effect_marker == marked.external_effect_marker
          assert confirmation.confirmed_local_version == 2
          assert confirmation.confirmed_snapshot == newer_intent
          assert request.minimum_local_version == 2
          {:ok, :confirmed_newer}
        end,
        mark_effect: fn _, _, _ -> flunk("effect_pending operation created a second marker") end
      )

    assert {:ok, :confirmed_newer} =
             ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "marks and creates an unmapped local release without a tag lookup" do
    parent = self()
    proof = tag_proof()
    operation = operation(:processing, github_object_id: nil)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok,
           context(proof,
             trigger: :local,
             github_object_id: nil,
             github_node_id: nil,
             local_version: 1,
             baseline: :missing
           )}
        end,
        local_observe: fn _ -> {:ok, local_release(@base, 1)} end,
        get_release: fn _, _, _, _, _ -> flunk("unmapped create used immutable-ID fetch") end,
        get_release_by_tag: fn _, _, _, _, _ -> flunk("new create used recovery tag lookup") end,
        mark_effect: fn ^operation, @now, marker ->
          assert marker["action"] == "create_remote_release"
          assert marker["github_object_id"] == nil
          assert marker["tag_proof"] == proof
          send(parent, :effect_marked)
          {:ok, %{operation | state: :effect_pending, external_effect_marker: marker}}
        end,
        create_release: fn _, "acme", "widgets", attrs, _ ->
          assert_received :effect_marked
          assert attrs == Map.drop(@base, ["published_at"])
          {:ok, github_release(@base)}
        end,
        confirm: fn marked, @now, _expected, confirmation, request ->
          assert marked.state == :effect_pending
          assert confirmation.github_object_id == 41
          assert confirmation.tag_proof == proof
          assert request.action == :observe
          assert request.minimum_local_version == 1
          {:ok, :created}
        end
      )

    assert {:ok, :created} = ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "marks and deletes GitHub after an unchanged local tombstone" do
    parent = self()
    operation = operation(:processing)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(:not_required, local_deleted: true, baseline: @base)}
        end,
        mark_effect: fn ^operation, @now, marker ->
          assert marker["action"] == "delete_remote_release"
          assert marker["github_object_id"] == 41
          send(parent, :effect_marked)
          {:ok, %{operation | state: :effect_pending, external_effect_marker: marker}}
        end,
        delete_release: fn _, "acme", "widgets", 41, _ ->
          assert_received :effect_marked
          :ok
        end,
        confirm: fn marked, @now, _expected, confirmation, request ->
          assert marked.state == :effect_pending
          assert confirmation.state == :deleted
          assert request.action == :observe
          assert request.expected_deleted == true
          assert request.minimum_local_version == 3
          {:ok, :deleted_remote}
        end
      )

    assert {:ok, :deleted_remote} =
             ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "canonical immutable-id deletion never falls back to tag identity" do
    operation = operation(:processing, release_action: "deleted")

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(:not_required, baseline: @base, local_version: 3)}
        end,
        local_observe: fn _ -> {:ok, local_release(@base, 3)} end,
        get_release: fn _, _, _, 41, _ -> {:error, Error.new(:not_found)} end,
        get_release_by_tag: fn _, _, _, _, _ -> flunk("deletion used a mutable tag cursor") end,
        confirm: fn ^operation, @now, expected, confirmation, request ->
          assert expected.github_object_id == 41
          assert confirmation.state == :deleted
          assert confirmation.tag_proof == :not_required
          assert request.action == :delete
          assert request.expected_local_version == 3
          {:ok, :deleted}
        end
      )

    assert {:ok, :deleted} = ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "canonical deletion compares a persisted ISO publication baseline to local time" do
    operation = operation(:processing, release_action: "deleted")
    persisted_baseline = Map.update!(@base, "published_at", &DateTime.to_iso8601/1)

    options =
      options(operation,
        context: fn ^operation ->
          {:ok, context(:not_required, baseline: persisted_baseline, local_version: 3)}
        end,
        local_observe: fn _ -> {:ok, local_release(@base, 3)} end,
        get_release: fn _, _, _, 41, _ -> {:error, Error.new(:not_found)} end,
        confirm: fn ^operation, @now, _expected, confirmation, request ->
          assert confirmation.state == :deleted
          assert request.action == :delete
          {:ok, :deleted}
        end,
        conflict: fn _, _, _, _, _, _ -> flunk("equivalent release timestamps conflicted") end
      )

    assert {:ok, :deleted} = ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "fetches exactly one bounded remote or mapped reconciliation page" do
    remote_operation = reconciliation_operation(:remote)
    mapped_operation = reconciliation_operation(:mapped)
    mapping_cursor = mapped_operation.checkpoint["mapping_cursor"]
    observations = [release_observation()]

    assert {:ok, :remote_recorded} =
             ReleaseSyncWorker.process_operation(
               remote_operation,
               @now,
               options(remote_operation,
                 context: fn ^remote_operation ->
                   {:ok, reconciliation_context(:remote, page: 2)}
                 end,
                 list_releases: fn _, _, _, 2, _ ->
                   {:ok, %{releases: [github_release(@base)], next_cursor: 3}}
                 end,
                 record_page: fn ^remote_operation, :release, ^observations, 3, @now ->
                   {:ok, :remote_recorded}
                 end
               )
             )

    assert {:ok, :mapped_recorded} =
             ReleaseSyncWorker.process_operation(
               mapped_operation,
               @now,
               options(mapped_operation,
                 context: fn ^mapped_operation ->
                   {:ok, reconciliation_context(:mapped, mapping_cursor: mapping_cursor)}
                 end,
                 list_releases: fn _, _, _, _, _ -> flunk("mapped phase called GitHub list") end,
                 resource_inventory: fn 3, :release, ^mapping_cursor, 100 ->
                   {:ok, %{observations: observations, next_cursor: nil}}
                 end,
                 record_page: fn ^mapped_operation, :release, ^observations, nil, @now ->
                   {:ok, :mapped_recorded}
                 end
               )
             )
  end

  test "tag proof failures become durable release conflicts without provider effects" do
    for {reason, kind} <- [
          release_tag_missing: "release_tag_missing",
          tag_retarget: "tag_retarget"
        ] do
      operation = operation(:processing, checkpoint: canonical_checkpoint())

      opts =
        options(operation,
          prepare_tag_proof: fn ^operation, "v1.0.0", @now -> {:error, reason} end,
          conflict: fn ^operation, @now, ^kind, %{}, %{}, %{} -> {:ok, kind} end,
          create_release: fn _, _, _, _, _ -> flunk("tag conflict wrote GitHub") end,
          update_release: fn _, _, _, _, _, _ -> flunk("tag conflict wrote GitHub") end
        )

      assert {:ok, ^kind} = ReleaseSyncWorker.process_operation(operation, @now, opts)
    end
  end

  test "permission and revocation failures preserve an unresolved external effect" do
    for reason <- [%Error{kind: :forbidden}, :revoked] do
      marker = effect_marker("update_remote_release", @base, 41)
      operation = operation(:effect_pending, marker: marker)

      opts =
        options(operation,
          token_fetch: fn _, _ -> {:error, reason} end,
          defer_effect: fn ^operation, @now, retry_at, "network", "credential_unavailable" ->
            assert DateTime.after?(retry_at, @now)
            {:ok, :preserved}
          end,
          fail: fn _, _, _, _ -> flunk("effect marker was discarded") end
        )

      assert {:ok, :preserved} = ReleaseSyncWorker.process_operation(operation, @now, opts)
    end
  end

  test "unexpected GitHub validation responses fail terminally instead of retrying" do
    operation = operation(:processing, checkpoint: canonical_checkpoint())

    options =
      options(operation,
        context: fn ^operation -> {:ok, context(tag_proof())} end,
        get_release: fn _, _, _, _, _ -> {:error, Error.new(:unexpected_status)} end,
        fail: fn ^operation, @now, "provider_validation", detail ->
          assert detail == "GitHub returned an invalid release resource"
          {:ok, :failed}
        end,
        retry: fn _, _, _, _, _ -> flunk("provider validation was retried as a network error") end
      )

    assert {:ok, :failed} = ReleaseSyncWorker.process_operation(operation, @now, options)
  end

  test "GitHub validation failure after marking an effect becomes a durable conflict" do
    for kind <- [:invalid_request, :unexpected_status] do
      proof = tag_proof()
      operation = operation(:processing, checkpoint: canonical_checkpoint())
      local_fields = Map.put(@base, "body", "local notes")

      options =
        options(operation,
          context: fn ^operation ->
            {:ok, context(proof, baseline: @base, local_version: 4)}
          end,
          local_observe: fn _ -> {:ok, local_release(local_fields, 4)} end,
          get_release: fn _, _, _, 41, _ -> {:ok, github_release(@base)} end,
          mark_effect: fn ^operation, @now, marker ->
            {:ok, %{operation | state: :effect_pending, external_effect_marker: marker}}
          end,
          update_release: fn _, _, _, _, _, _ -> {:error, Error.new(kind)} end,
          conflict: fn marked, @now, "provider_validation", %{}, %{}, %{} ->
            assert marked.state == :effect_pending
            {:ok, :conflicted}
          end,
          defer_effect: fn _, _, _, _, _ -> flunk("provider validation effect was deferred") end
        )

      assert {:ok, :conflicted} =
               ReleaseSyncWorker.process_operation(operation, @now, options)
    end
  end

  test "stale and invalid local confirmation errors become durable conflicts" do
    for reason <- [
          :stale_baseline,
          :stale_local_version,
          :namespace_collision,
          :invalid_sync_request
        ] do
      operation = operation(:processing, checkpoint: canonical_checkpoint())

      options =
        options(operation,
          context: fn ^operation -> {:ok, context(tag_proof())} end,
          confirm: fn _, _, _, _, _ -> {:error, reason} end,
          conflict: fn ^operation, @now, kind, %{}, %{}, %{} ->
            assert kind == Atom.to_string(reason)
            {:ok, :conflicted}
          end,
          retry: fn _, _, _, _, _ -> flunk("local confirmation error was retried") end,
          fail: fn _, _, _, _ -> flunk("local confirmation error bypassed conflict recording") end
        )

      assert {:ok, :conflicted} =
               ReleaseSyncWorker.process_operation(operation, @now, options)
    end
  end

  defp options(operation, overrides) do
    defaults = [
      context: fn ^operation -> {:ok, context(:required)} end,
      token_fetch: fn 44, %{permissions: %{"contents" => "write", "metadata" => "read"}} ->
        %InstallationToken{
          token: "ephemeral",
          expires_at: DateTime.add(@now, 3_600),
          permissions: %{"contents" => "write", "metadata" => "read"}
        }
      end,
      local_observe: fn _ -> {:ok, local_release(@base, 3)} end,
      get_release: fn _, _, _, 41, _ -> {:ok, github_release(@base)} end,
      get_release_by_tag: fn _, _, _, _, _ -> {:error, Error.new(:not_found)} end,
      list_releases: fn _, _, _, _, _ -> {:ok, %{releases: [], next_cursor: nil}} end,
      resource_inventory: fn _, _, _, _ -> flunk("unexpected resource inventory page") end,
      author_observe: fn _, _ -> {:ok, %{id: 901}} end,
      asset_warning: fn _ -> :ok end,
      record_canonical: fn _, _, _ -> flunk("unexpected canonical checkpoint") end,
      prepare_tag_proof: fn _, _, _ -> flunk("unexpected tag proof split") end,
      mark_effect: fn _, _, _ -> flunk("unexpected external effect") end,
      replace_effect: fn _, _, _, _ -> flunk("unexpected replacement effect") end,
      authorize_effect: fn marked, marker ->
        assert marked.external_effect_marker == marker
        {:ok, marked}
      end,
      create_release: fn _, _, _, _, _ -> flunk("unexpected create") end,
      update_release: fn _, _, _, _, _, _ -> flunk("unexpected update") end,
      delete_release: fn _, _, _, _, _ -> flunk("unexpected delete") end,
      confirm: fn _, _, _, _, _ -> flunk("unexpected confirmation") end,
      conflict: fn _, _, _, _, _, _ -> flunk("unexpected conflict") end,
      record_page: fn _, _, _, _, _ -> flunk("unexpected reconciliation page") end,
      retry: fn _, _, _, _, _ -> flunk("unexpected retry") end,
      fail: fn _, _, _, _ -> flunk("unexpected failure") end,
      defer_effect: fn _, _, _, _, _ -> flunk("unexpected effect deferral") end,
      fingerprint: &ForgeMirrors.resource_fingerprint/1
    ]

    Keyword.merge(defaults, overrides)
  end

  defp operation(state, attrs \\ []) do
    %MirrorOperation{
      id: 71,
      organization_mirror_id: 1,
      repository_mirror_id: 3,
      kind: "sync.release",
      state: state,
      lease_owner: "release-worker",
      lease_expires_at: DateTime.add(@now, 60),
      cursor: %{
        "trigger" => "remote",
        "resource_kind" => "release",
        "github_object_id" => Keyword.get(attrs, :github_object_id, 41),
        "tag_name" => "v1.0.0",
        "release_action" => Keyword.get(attrs, :release_action, "edited"),
        "delivery_guid" => "delivery-1"
      },
      checkpoint: Keyword.get(attrs, :checkpoint, %{}),
      external_effect_marker: Keyword.get(attrs, :marker)
    }
  end

  defp reconciliation_operation(phase) do
    checkpoint =
      if phase == :mapped do
        %{
          "phase" => "mapped",
          "mapping_cursor" => %{
            "repository_mirror_id" => 3,
            "resource_kind" => "release",
            "after_id" => 0,
            "through_id" => 90
          }
        }
      else
        %{"page" => 2}
      end

    %{
      operation(:processing)
      | kind: "reconcile.repository.releases",
        cursor: %{
          "trigger" => "reconcile",
          "resource_kind" => "release",
          "since" => "1970-01-01T00:00:00Z",
          "page" => 1,
          "sweep_id" => "d8b4cc35-367e-4ef2-9824-e20110ce0ca2"
        },
        checkpoint: checkpoint
    }
  end

  defp context(proof, overrides \\ []) do
    Map.merge(
      %{
        resource_kind: :release,
        repository_id: 8,
        repository_mirror_id: 3,
        github_repository_id: 900,
        github_installation_id: 44,
        metadata_permissions: %{"contents" => "write", "metadata" => "read"},
        remote_owner: "acme",
        remote_repository: "widgets",
        trigger: :remote,
        local_resource_id: 11,
        github_object_id: 41,
        github_node_id: "RE_41",
        local_version: 3,
        local_deleted: false,
        tag_name: "v1.0.0",
        fields: @base,
        baseline: @base,
        confirmed_local_version: 3,
        confirmed_remote_updated_at: ~U[2026-09-14 07:30:00Z],
        resource_state_lock_version: 2,
        effect_marker: nil,
        tag_proof: proof,
        phase: nil,
        page: nil,
        mapping_cursor: nil,
        provenance: %{
          delivery_guid: "delivery-1",
          outbox_event_id: nil,
          causation_id: nil,
          correlation_id: nil
        }
      },
      Map.new(overrides)
    )
  end

  defp reconciliation_context(phase, overrides) do
    context(
      :not_required,
      [
        trigger: :reconcile,
        local_resource_id: nil,
        github_object_id: nil,
        github_node_id: nil,
        local_version: nil,
        tag_name: nil,
        fields: nil,
        baseline: :missing,
        confirmed_local_version: nil,
        confirmed_remote_updated_at: nil,
        resource_state_lock_version: :missing,
        phase: phase,
        page: nil,
        mapping_cursor: nil
      ] ++ overrides
    )
  end

  defp local_release(fields, version) do
    %{
      presence: :present,
      resource_kind: :release,
      local_resource_id: 11,
      local_resource_type: "ForgeReleases.Release",
      local_version: version,
      snapshot: fields
    }
  end

  defp github_release(fields, overrides \\ []) do
    %{
      "id" => 41,
      "node_id" => "RE_41",
      "tag_name" => fields["tag_name"],
      "name" => fields["name"],
      "body" => fields["body"],
      "draft" => fields["draft"],
      "prerelease" => fields["prerelease"],
      "target_commitish" => fields["target_commitish"],
      "published_at" => fields["published_at"],
      "created_at" => "2026-09-14T06:00:00Z",
      "updated_at" => Keyword.get(overrides, :updated_at, "2026-09-14T07:30:00Z"),
      "author" => %{"id" => 501, "node_id" => "U_501", "login" => "octocat"},
      "asset_count" => Keyword.get(overrides, :asset_count, 0)
    }
  end

  defp release_observation do
    %{github_object_id: 41, tag_name: "v1.0.0", remote_updated_at: ~U[2026-09-14 07:30:00Z]}
  end

  defp canonical_checkpoint do
    %{
      "canonical_release" => %{
        "github_object_id" => 41,
        "tag_name" => "v1.0.0",
        "remote_updated_at" => "2026-09-14T07:30:00Z"
      }
    }
  end

  defp tag_proof do
    %{
      tag_name: "v1.0.0",
      ref_name: "refs/tags/v1.0.0",
      confirmed_oid: @oid,
      local_oid: @oid,
      remote_oid: @oid,
      confirmed_at: @now,
      ref_state_lock_version: 4,
      repository_id: 8
    }
  end

  defp effect_marker(action, fields, github_object_id) do
    fingerprint = fingerprint(fields)

    %{
      "v" => 1,
      "action" => action,
      "resource_kind" => "release",
      "local_resource_id" => 11,
      "expected_local_version" => 1,
      "expected_local_fingerprint" => fingerprint,
      "expected_remote_updated_at" => nil,
      "expected_remote_fingerprint" => nil,
      "proposed_fingerprint" => fingerprint,
      "github_object_id" => github_object_id,
      "tag_proof" => tag_proof()
    }
  end

  defp fingerprint(fields) do
    canonical =
      Map.update(fields, "published_at", nil, fn
        %DateTime{} = value -> DateTime.to_iso8601(value)
        value -> value
      end)

    {:ok, fingerprint} = ForgeMirrors.resource_fingerprint(canonical)
    fingerprint
  end

  defp collect_events(count), do: Enum.map(1..count, fn _ -> receive do: (event -> event) end)
end
